import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/app_theme_and_strings.dart';
import '../models/app_models.dart';

class AppEngineService {
  AppEngineService._();
  static final AppEngineService instance = AppEngineService._();

  bool isSupabaseReady = false;
  bool isProUser = false;
  bool isSharingLocation = true;
  bool isBubblePrivacyActive = false;
  bool isAlertMuted = false;
  bool showDemoWhenAlone = true;
  int mapStyleIndex = 0;

  String currentUserId = '';
  String myCustomAvatarDataUrl = '';
  String myPhoneNumber = '';
  String activeSignalEnvelope = '';
  DateTime? activeSignalExpiresAt;

  static const String proMonthlyProductId = 'pingo_pro_monthly';
  static const String proYearlyProductId = 'pingo_pro_yearly';
  static const String kProMonthlyId = 'pingo_pro_monthly';
  static const String kProYearlyId = 'pingo_pro_yearly';

  final Map<String, String> _roadAddressCache = {};
  final Map<String, LatLng> _lastGeocodedCoordByKey = {};
  final Map<String, DateTime> _lastGeocodedTimeByKey = {};
  final Map<String, String> memberPhones = {};
  final Map<String, bool> circleHiddenMap = {};
  final Set<String> blockedUserIds = {};

  Map<String, String> get memberPhoneBook => memberPhones;

  DateTime? _lastServerPushTime;
  LatLng? _lastServerPushLatLng;
  StreamSubscription<List<PurchaseDetails>>? _iapSubscription;

  static const List<String> presetEmojiAvatars = [
    'avatar:😊',
    'avatar:😎',
    'avatar:🦊',
    'avatar:🐱',
    'avatar:🐶',
    'avatar:🐼',
    'avatar:🐰',
    'avatar:🦁',
    'avatar:🐸',
    'avatar:🦄',
    'avatar:👑',
    'avatar:🚀',
  ];

  String get currentMapboxStyleId {
    if (mapStyleIndex == 1) return 'mapbox/streets-v12';
    if (mapStyleIndex == 2) return 'mapbox/dark-v11';
    return AppConfig.mapboxStyleId;
  }

  String buildCircleScopedUserId(String circleCode) {
    final base = currentUserId.isEmpty ? '00000000-0000-4000-8000-000000000000' : currentUserId;
    final cleanCode = circleCode.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toLowerCase().padRight(6, '0');
    final hexSuffix = cleanCode.codeUnits.take(6).map((c) => (c % 16).toRadixString(16)).join();
    if (base.length >= 36 && base.contains('-')) {
      return '${base.substring(0, 30)}$hexSuffix';
    }
    return base;
  }

  Future<void> initializeServices() async {
    await ensureAnonymousSession();
  }

  Future<void> ensureAnonymousSession() async {
    await _loadOrGeneratePersistentDeviceId();
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        anonKey: AppConfig.supabaseAnonKey,
      );
      isSupabaseReady = true;
    } catch (_) {
      isSupabaseReady = true;
    }
    _initInAppPurchaseListener();
  }

  Future<void> setPersistentDeviceUserId(String customSeed) async {
    await _loadOrGeneratePersistentDeviceId();
  }

  Future<void> _loadOrGeneratePersistentDeviceId() async {
    try {
      final file = File('${Directory.systemTemp.path}/pingo_device_identity_v2.txt');
      if (await file.exists()) {
        final saved = (await file.readAsString()).trim();
        if (saved.length >= 32) {
          currentUserId = saved;
          return;
        }
      }
      final rnd = math.Random.secure();
      String hex(int len) => List.generate(len, (_) => rnd.nextInt(16).toRadixString(16)).join();
      currentUserId = '${hex(8)}-${hex(4)}-4${hex(3)}-8${hex(3)}-${hex(12)}';
      await file.writeAsString(currentUserId, flush: true);
    } catch (_) {
      final rnd = math.Random();
      String hex(int len) => List.generate(len, (_) => rnd.nextInt(16).toRadixString(16)).join();
      currentUserId = '${hex(8)}-${hex(4)}-4${hex(3)}-8${hex(3)}-${hex(12)}';
    }
  }

  static String generateRandomInviteCode() {
    final rnd = math.Random();
    return (100000 + rnd.nextInt(900000)).toString();
  }

  Future<String> generateUniqueCircleCode() async {
    return generateRandomInviteCode();
  }

  double calculateDistanceMeters(LatLng a, LatLng b) {
    return const Distance().as(LengthUnit.Meter, a, b);
  }

  Future<bool> savePhoneForMember(String memberId, String phone) async {
    final cleaned = phone.trim();
    if (cleaned.isEmpty) return false;
    memberPhones[memberId] = cleaned;
    return true;
  }

  static Future<bool> launchNativePhoneCall(String rawPhone) async {
    final clean = rawPhone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return false;
    final uri = Uri(scheme: 'tel', path: clean);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> launchNativeSms({
    String? phone,
    String? rawPhone,
    String? bodyText,
    String? body,
  }) async {
    final targetPhone = (phone ?? rawPhone ?? '').replaceAll(RegExp(r'[^0-9+]'), '');
    final msg = bodyText ?? body ?? '';
    final Uri uri = msg.isNotEmpty
        ? Uri(
            scheme: 'sms',
            path: targetPhone,
            queryParameters: <String, String>{'body': msg},
          )
        : Uri(scheme: 'sms', path: targetPhone);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static Future<void> openExternalLegalUrl({
    bool isTermsOfUse = true,
    String? rawUrl,
  }) async {
    final target = rawUrl ??
        (isTermsOfUse
            ? 'https://jeong-giseong.github.io/pingo-terms.html'
            : 'https://jeong-giseong.github.io/pingo-privacy.html');
    try {
      final uri = Uri.parse(target);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  static Future<void> openRealMapNavigation({
    required LatLng dest,
    String? addressHint,
  }) async {
    final url = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${dest.latitude},${dest.longitude}',
    );
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  static Future<String?> showAvatarAndPhotoPickerModal({
    required BuildContext context,
    String? currentAvatarUrl,
    String? currentAvatar,
    ValueChanged<String>? onSelected,
  }) async {
    final picker = ImagePicker();
    final activeAvatar = currentAvatarUrl ?? currentAvatar;
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.t('avatar_picker_title'),
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          try {
                            final xfile = await picker.pickImage(
                              source: ImageSource.gallery,
                              maxWidth: 180,
                              maxHeight: 180,
                              imageQuality: 40,
                            );
                            if (xfile != null) {
                              final bytes = await xfile.readAsBytes();
                              final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
                              instance.myCustomAvatarDataUrl = dataUrl;
                              if (onSelected != null) onSelected(dataUrl);
                              if (ctx.mounted) Navigator.pop(ctx, dataUrl);
                            }
                          } catch (_) {}
                        },
                        icon: const Icon(Icons.photo_library_rounded, size: 18),
                        label: Text(AppStrings.t('pick_photo_gallery')),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6C47FF),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          try {
                            final xfile = await picker.pickImage(
                              source: ImageSource.camera,
                              maxWidth: 180,
                              maxHeight: 180,
                              imageQuality: 40,
                            );
                            if (xfile != null) {
                              final bytes = await xfile.readAsBytes();
                              final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
                              instance.myCustomAvatarDataUrl = dataUrl;
                              if (onSelected != null) onSelected(dataUrl);
                              if (ctx.mounted) Navigator.pop(ctx, dataUrl);
                            }
                          } catch (_) {}
                        },
                        icon: const Icon(Icons.camera_alt_rounded, size: 18),
                        label: Text(AppStrings.t('pick_photo_camera')),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: presetEmojiAvatars.map((item) {
                    final emoji = item.replaceFirst('avatar:', '');
                    return GestureDetector(
                      onTap: () {
                        instance.myCustomAvatarDataUrl = item;
                        if (onSelected != null) onSelected(item);
                        Navigator.pop(ctx, item);
                      },
                      child: Container(
                        width: 48,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F0FF),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: activeAvatar == item
                                ? const Color(0xFF6C47FF)
                                : const Color(0xFFE4E7EC),
                            width: 2,
                          ),
                        ),
                        child: Text(emoji, style: const TextStyle(fontSize: 22)),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> cleanupDuplicateGhostRows({
    required String circleCode,
    required String myUserName,
    String? userName,
  }) async {
    if (!isSupabaseReady || currentUserId.isEmpty) return;
    final targetName = myUserName.isNotEmpty ? myUserName : (userName ?? '');
    if (targetName.isEmpty) return;
    try {
      final scopedId = buildCircleScopedUserId(circleCode);
      await Supabase.instance.client
          .from('locations')
          .delete()
          .eq('circle_code', circleCode)
          .eq('user_name', targetName)
          .neq('user_id', scopedId)
          .neq('user_id', currentUserId);
    } catch (_) {}
  }

  void _initInAppPurchaseListener() {
    if (kIsWeb) return;
    try {
      final purchaseUpdated = InAppPurchase.instance.purchaseStream;
      _iapSubscription = purchaseUpdated.listen((purchaseDetailsList) {
        for (final purchaseDetails in purchaseDetailsList) {
          if (purchaseDetails.status == PurchaseStatus.purchased ||
              purchaseDetails.status == PurchaseStatus.restored) {
            isProUser = true;
            if (purchaseDetails.pendingCompletePurchase) {
              InAppPurchase.instance.completePurchase(purchaseDetails);
            }
          }
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  Future<bool> purchaseProSubscription({
    String productId = proYearlyProductId,
    VoidCallback? onProUnlocked,
  }) async {
    final isYearly = productId.contains('year');
    final ok = await buyProSubscription(isYearly: isYearly);
    if (ok && onProUnlocked != null) onProUnlocked();
    return ok;
  }

  Future<bool> buyProSubscription({bool isYearly = true}) async {
    if (kIsWeb) {
      isProUser = true;
      return true;
    }
    try {
      final available = await InAppPurchase.instance.isAvailable();
      if (!available) return false;
      final targetId = isYearly ? kProYearlyId : kProMonthlyId;
      final response = await InAppPurchase.instance.queryProductDetails({targetId});
      if (response.productDetails.isNotEmpty) {
        final param = PurchaseParam(productDetails: response.productDetails.first);
        await InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> restoreProPurchases({VoidCallback? onProUnlocked}) async {
    if (kIsWeb) {
      if (isProUser && onProUnlocked != null) onProUnlocked();
      return isProUser;
    }
    try {
      final available = await InAppPurchase.instance.isAvailable();
      if (!available) return isProUser;
      await InAppPurchase.instance.restorePurchases();
      if (isProUser && onProUnlocked != null) onProUnlocked();
      return isProUser;
    } catch (_) {
      return false;
    }
  }

  Future<String> fetchRoadAddress(
    LatLng point, {
    double speedKmh = 0.0,
    List<SafePlaceData>? safePlaces,
    bool forceLookup = false,
  }) async {
    if (!forceLookup && speedKmh >= 4.5) {
      return '🚗 ${AppStrings.t('Filter_Moving')} (${speedKmh.toStringAsFixed(0)} km/h)';
    }

    const lang = 'ko';
    final key = '${point.latitude.toStringAsFixed(3)}_${point.longitude.toStringAsFixed(3)}';
    if (_roadAddressCache.containsKey(key)) {
      return _roadAddressCache[key]!;
    }

    final lastCoord = _lastGeocodedCoordByKey[lang];
    final lastTime = _lastGeocodedTimeByKey[lang];
    if (!forceLookup && lastCoord != null && lastTime != null) {
      final movedMeters = calculateDistanceMeters(lastCoord, point);
      final elapsedSec = DateTime.now().difference(lastTime).inSeconds;
      if (movedMeters < 250.0 && elapsedSec < 180 && _roadAddressCache.isNotEmpty) {
        return _roadAddressCache.values.last;
      }
    }

    const token = 'pk.eyJ1IjoiamVvbmdnaXNlb25nIiwiYSI6ImNtdnFhNHhpMDA2OHoyeXIwZThuMnkwanYifQ._Zouj-a9d2NaLWCVyRKwiQ';
    final url = Uri.parse(
      'https://api.mapbox.com/geocoding/v5/mapbox.places/${point.longitude},${point.latitude}.json'
      '?types=address,poi,neighborhood,locality,place&limit=1&access_token=$token',
    );
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final features = data['features'] as List?;
        if (features != null && features.isNotEmpty) {
          final f = features.first;
          final placeText = (f['text'] ?? '').toString();
          String contextStr = '';
          final ctxList = f['context'] as List?;
          if (ctxList != null && ctxList.isNotEmpty) {
            contextStr = (ctxList.first['text'] ?? '').toString();
          }
          final fullAddr = contextStr.isNotEmpty && contextStr != placeText
              ? '$contextStr $placeText'
              : (f['place_name'] ?? placeText).toString().split(',').take(2).join(' ');
          if (fullAddr.trim().isNotEmpty) {
            _roadAddressCache[key] = fullAddr.trim();
            _lastGeocodedCoordByKey[lang] = point;
            _lastGeocodedTimeByKey[lang] = DateTime.now();
            return fullAddr.trim();
          }
        }
      }
    } catch (_) {}
    return '${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}';
  }

  Future<List<LatLng>> fetchRoadSnappedRoute(
    dynamic firstPointOrList, [
    LatLng? secondPoint,
    String? profileOpt,
  ]) async {
    return _computeSmoothedRoute(firstPointOrList, secondPoint);
  }

  List<LatLng> _computeSmoothedRoute(dynamic firstPointOrList, [LatLng? secondPoint]) {
    List<LatLng> waypoints = [];
    if (firstPointOrList is List<LatLng>) {
      waypoints = firstPointOrList;
    } else if (firstPointOrList is LatLng && secondPoint != null) {
      waypoints = [firstPointOrList, secondPoint];
    }
    if (waypoints.length < 2) return waypoints;

    final List<LatLng> smoothed = [];
    for (int i = 0; i < waypoints.length - 1; i++) {
      final p0 = waypoints[i];
      final p1 = waypoints[i + 1];
      smoothed.add(p0);
      smoothed.add(LatLng(
        p0.latitude * 0.67 + p1.latitude * 0.33,
        p0.longitude * 0.67 + p1.longitude * 0.33,
      ));
      smoothed.add(LatLng(
        p0.latitude * 0.33 + p1.latitude * 0.67,
        p0.longitude * 0.33 + p1.longitude * 0.67,
      ));
    }
    smoothed.add(waypoints.last);
    return smoothed;
  }

  Future<void> pushLiveLocationToServer({
    required String circleCode,
    required String userName,
    LatLng? point,
    LatLng? position,
    double speedKmh = 0.0,
    int? battery,
    int? batteryLevel,
    bool isSos = false,
    String? avatarUrl,
    String? audioClipDataUrl,
    String? signalClip,
    List<CircleInfo>? allJoinedCircles,
    bool forceImmediate = false,
  }) async {
    if (!isSupabaseReady) return;
    final targetPos = point ?? position ?? const LatLng(37.5665, 126.9780);
    final targetBat = battery ?? batteryLevel ?? 90;
    final rawClip = audioClipDataUrl ?? signalClip ?? '';

    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      myCustomAvatarDataUrl = avatarUrl;
    }

    final hasUrgentSignal = isSos ||
        forceImmediate ||
        (rawClip.isNotEmpty && !rawClip.startsWith('BUBBLE::'));

    final now = DateTime.now();
    if (!hasUrgentSignal && _lastServerPushTime != null && _lastServerPushLatLng != null) {
      final elapsedSec = now.difference(_lastServerPushTime!).inSeconds;
      final movedMeters = calculateDistanceMeters(_lastServerPushLatLng!, targetPos);
      if (elapsedSec < 15 && movedMeters < 20.0) {
        return;
      }
    }

    _lastServerPushTime = now;
    _lastServerPushLatLng = targetPos;

    if (rawClip.isNotEmpty) {
      activeSignalEnvelope = rawClip;
      activeSignalExpiresAt = now.add(const Duration(seconds: 30));
    } else if (activeSignalExpiresAt != null && now.isAfter(activeSignalExpiresAt!)) {
      activeSignalEnvelope = '';
      activeSignalExpiresAt = null;
    }

    final effectiveClip = rawClip.isNotEmpty
        ? rawClip
        : (activeSignalEnvelope.isNotEmpty
            ? activeSignalEnvelope
            : (isBubblePrivacyActive
                ? 'BUBBLE::ON::${myPhoneNumber.trim()}'
                : (myPhoneNumber.trim().isNotEmpty ? 'META::PHONE::${myPhoneNumber.trim()}' : '')));

    double sendLat = targetPos.latitude;
    double sendLng = targetPos.longitude;
    if (isBubblePrivacyActive && !isSos) {
      sendLat = double.parse(targetPos.latitude.toStringAsFixed(2));
      sendLng = double.parse(targetPos.longitude.toStringAsFixed(2));
    }

    final payload = <String, dynamic>{
      'user_id': currentUserId,
      'circle_code': circleCode,
      'user_name': userName,
      'lat': sendLat,
      'lng': sendLng,
      'speed_kmh': speedKmh,
      'battery_level': targetBat,
      'is_sos': isSos,
      'audio_clip': effectiveClip,
      'updated_at': now.toIso8601String(),
    };
    if (myCustomAvatarDataUrl.isNotEmpty) {
      payload['avatar_url'] = myCustomAvatarDataUrl;
    }

    try {
      await Supabase.instance.client.from('locations').upsert(payload);
    } catch (_) {}
  }

  Future<void> deleteMyServerDataAndReset() async {
    await deleteUserAccountAndData();
  }

  Future<void> deleteUserAccountAndData([List<CircleInfo>? joinedCircles]) async {
    if (!isSupabaseReady) return;
    try {
      if (currentUserId.isNotEmpty) {
        await Supabase.instance.client.from('locations').delete().eq('user_id', currentUserId);
      }
      final sessionFile = File('${Directory.systemTemp.path}/pingo_saved_session_v1.json');
      if (await sessionFile.exists()) await sessionFile.delete();
    } catch (_) {}
  }

  File get _localSessionFile => File('${Directory.systemTemp.path}/pingo_saved_session_v1.json');

  Future<void> saveLocalCirclesState({
    required List<CircleInfo> circles,
    required int activeIndex,
    required String userName,
    List<SafePlaceData>? safePlaces,
    List<LatLng>? myRecentRoute,
  }) async {
    try {
      final data = {
        'userName': userName,
        'myPhoneNumber': myPhoneNumber,
        'activeIndex': activeIndex,
        'avatarDataUrl': myCustomAvatarDataUrl,
        'isBubblePrivacyActive': isBubblePrivacyActive,
        'isProUser': isProUser,
        'isAlertMuted': isAlertMuted,
        'showDemoWhenAlone': showDemoWhenAlone,
        'mapStyleIndex': mapStyleIndex,
        'memberPhones': memberPhones,
        'blockedUserIds': blockedUserIds.toList(),
        'circleHiddenMap': circleHiddenMap,
        'circles': circles
            .map((c) => {
                  'name': c.name,
                  'code': c.code,
                  'myRole': c.myRole,
                })
            .toList(),
      };
      await _localSessionFile.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> loadLocalCirclesState() async {
    try {
      if (!await _localSessionFile.exists()) return null;
      final raw = await _localSessionFile.readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['avatarDataUrl'] != null) {
        myCustomAvatarDataUrl = decoded['avatarDataUrl'].toString();
      }
      if (decoded['myPhoneNumber'] != null) {
        myPhoneNumber = decoded['myPhoneNumber'].toString();
      }
      if (decoded['isBubblePrivacyActive'] is bool) {
        isBubblePrivacyActive = decoded['isBubblePrivacyActive'] as bool;
      }
      if (decoded['isProUser'] is bool) {
        isProUser = decoded['isProUser'] as bool;
      }
      if (decoded['memberPhones'] is Map) {
        final mp = decoded['memberPhones'] as Map;
        mp.forEach((k, v) {
          if (v != null) memberPhones[k.toString()] = v.toString();
        });
      }
      return decoded;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _iapSubscription?.cancel();
  }
}