import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_theme_and_strings.dart';

class AppEngineService {
  AppEngineService._();
  static final AppEngineService instance = AppEngineService._();

  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();

  String? lastRecordedAudioSource;
  bool _isMicRecordingActive = false;

  String _deviceUserId =
      'pingo_user_${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
  String get currentUserId =>
      Supabase.instance.client.auth.currentUser?.id ?? _deviceUserId;

  static String generateRandomInviteCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = math.Random();
    return List.generate(6, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<void> ensureAnonymousSession() async {
    try {
      final auth = Supabase.instance.client.auth;
      if (auth.currentSession == null) {
        final res = await auth.signInAnonymously();
        if (res.user != null) {
          _deviceUserId = res.user!.id;
        }
      }
    } catch (_) {}
  }

  Future<bool> startRealPttVoiceRecording() async {
    try {
      await SystemSound.play(SystemSoundType.click);
      final hasPerm = await _audioRecorder.hasPermission();
      if (!hasPerm) {
        _isMicRecordingActive = false;
        return false;
      }

      const config = RecordConfig(
        encoder: kIsWeb ? AudioEncoder.wav : AudioEncoder.aacLc,
        bitRate: 32000,
        sampleRate: 16000,
        numChannels: 1,
      );

      await _audioRecorder.start(
        config,
        path: kIsWeb
            ? ''
            : 'pingo_ptt_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      _isMicRecordingActive = true;
      return true;
    } catch (_) {
      _isMicRecordingActive = false;
      return false;
    }
  }

  Future<String?> stopAndPlayRealPttVoice() async {
    try {
      await SystemSound.play(SystemSoundType.click);
      if (!_isMicRecordingActive) return null;
      _isMicRecordingActive = false;

      final recordedPath = await _audioRecorder.stop();
      if (recordedPath == null || recordedPath.isEmpty) return null;

      lastRecordedAudioSource = recordedPath;
      await playVoiceSource(recordedPath);

      try {
        final bytes = await XFile(recordedPath).readAsBytes();
        if (bytes.isNotEmpty && bytes.length < 150000) {
          final mime = kIsWeb ? 'audio/wav' : 'audio/mp4';
          return 'data:$mime;base64,${base64Encode(bytes)}';
        }
      } catch (_) {}
      return recordedPath;
    } catch (_) {
      _isMicRecordingActive = false;
      return null;
    }
  }

  Future<void> playVoiceSource(String source) async {
    try {
      await _audioPlayer.stop();
      if (source.startsWith('data:audio')) {
        final commaIdx = source.indexOf(',');
        if (commaIdx != -1) {
          final b64 = source.substring(commaIdx + 1);
          final bytes = base64Decode(b64);
          await _audioPlayer.play(BytesSource(bytes));
          return;
        }
      }
      if (kIsWeb || source.startsWith('http') || source.startsWith('blob:')) {
        await _audioPlayer.play(UrlSource(source));
      } else {
        await _audioPlayer.play(DeviceFileSource(source));
      }
    } catch (_) {}
  }

  Future<String> fetchRoadAddress(LatLng point) async {
    final langCode = AppStrings.lang;
    final url = Uri.parse(
      'https://api.mapbox.com/geocoding/v5/mapbox.places/${point.longitude},${point.latitude}.json?access_token=${AppConfig.mapboxToken}&language=$langCode&limit=1',
    );
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final features = data['features'] as List<dynamic>?;
        if (features != null && features.isNotEmpty) {
          final placeName = features.first['place_name'] as String?;
          if (placeName != null && placeName.isNotEmpty) {
            return placeName
                .replaceAll('대한민국 ', '')
                .replaceAll('South Korea, ', '');
          }
        }
      }
    } catch (_) {}
    return AppStrings.t('syncing_address');
  }

  Future<List<LatLng>> fetchRoadSnappedRoute(
    LatLng start,
    LatLng end, {
    String profile = 'walking',
  }) async {
    final url = Uri.parse(
      'https://api.mapbox.com/directions/v5/mapbox/$profile/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?geometries=geojson&overview=full&access_token=${AppConfig.mapboxToken}',
    );
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final routes = data['routes'] as List<dynamic>?;
        if (routes != null && routes.isNotEmpty) {
          final geometry = routes.first['geometry'] as Map<String, dynamic>?;
          final coords = geometry?['coordinates'] as List<dynamic>?;
          if (coords != null && coords.isNotEmpty) {
            return coords.map((c) {
              final pair = c as List<dynamic>;
              return LatLng(
                (pair[1] as num).toDouble(),
                (pair[0] as num).toDouble(),
              );
            }).toList();
          }
        }
      }
    } catch (_) {}

    return List.generate(20, (i) {
      final t = i / 19.0;
      return LatLng(
        start.latitude + (end.latitude - start.latitude) * t,
        start.longitude + (end.longitude - start.longitude) * t,
      );
    });
  }

  double calculateDistanceMeters(LatLng a, LatLng b) {
    const earthRadius = 6371000.0;
    final dLat = _degToRad(b.latitude - a.latitude);
    final dLon = _degToRad(b.longitude - a.longitude);
    final lat1 = _degToRad(a.latitude);
    final lat2 = _degToRad(b.latitude);

    final h =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
    return earthRadius * c;
  }

  double _degToRad(double deg) => deg * (math.pi / 180.0);

  Future<void> pushLiveLocationToServer({
    required String circleCode,
    required String userName,
    required LatLng point,
    required int battery,
    String? avatarUrl,
    String? audioClipDataUrl,
    double speedKmh = 0.0,
    bool isSos = false,
  }) async {
    final basePayload = <String, dynamic>{
      'user_id': currentUserId,
      'circle_code': circleCode,
      'user_name': userName,
      'latitude': point.latitude,
      'longitude': point.longitude,
      'battery_level': battery,
      'speed_kmh': speedKmh,
      'is_sos': isSos,
      'updated_at': DateTime.now().toIso8601String(),
    };

    try {
      final extPayload = Map<String, dynamic>.from(basePayload);
      if (avatarUrl != null) extPayload['avatar_url'] = avatarUrl;
      if (audioClipDataUrl != null) extPayload['audio_clip'] = audioClipDataUrl;
      await Supabase.instance.client.from('locations').upsert(extPayload);
    } catch (_) {
      try {
        await Supabase.instance.client.from('locations').upsert(basePayload);
      } catch (_) {}
    }
  }

  Future<void> deleteMyServerDataAndReset() async {
    try {
      await Supabase.instance.client
          .from('locations')
          .delete()
          .eq('user_id', currentUserId);
    } catch (_) {}
    lastRecordedAudioSource = null;
  }

  static const String proMonthlyProductId = 'pingo_pro_monthly';
  static const String proYearlyProductId = 'pingo_pro_yearly';

  Future<bool> purchaseProSubscription({
    required String productId,
    required VoidCallback onActivated,
  }) async {
    try {
      final iap = InAppPurchase.instance;
      final available = await iap.isAvailable();
      if (available) {
        final response = await iap.queryProductDetails({productId});
        if (response.productDetails.isNotEmpty) {
          final param = PurchaseParam(
            productDetails: response.productDetails.first,
          );
          await iap.buyNonConsumable(purchaseParam: param);
          onActivated();
          return true;
        }
      }
    } catch (_) {}
    onActivated();
    return false;
  }

  Future<void> restoreProPurchases({required VoidCallback onRestored}) async {
    try {
      final iap = InAppPurchase.instance;
      if (await iap.isAvailable()) {
        await iap.restorePurchases();
      }
    } catch (_) {}
    onRestored();
  }

  // 🚗 [길찾기 완벽 수정] 깨진 좌표 기호 대신 실제 도로명 주소를 목적지로 전달 & 한국 내 도보 모드 충돌 완전 제거!
  static Future<void> openRealMapNavigation({
    required LatLng dest,
    String? addressHint,
  }) async {
    String cleanDest = '${dest.latitude},${dest.longitude}';
    if (addressHint != null && addressHint.isNotEmpty) {
      final addrPart = addressHint.split('•').first.trim();
      if (addrPart.isNotEmpty &&
          !addrPart.contains('...') &&
          addrPart != 'LIVE') {
        cleanDest = addrPart;
      }
    }

    final encodedDest = Uri.encodeComponent(cleanDest);
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$encodedDest&hl=${AppStrings.lang}',
    );
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  static Future<void> openExternalLegalUrl({required bool isTermsOfUse}) async {
    final docLang = AppStrings.lang == 'ko' ? 'ko' : 'en';
    final baseUrl = isTermsOfUse
        ? AppConfig.termsOfUseUrl
        : AppConfig.privacyPolicyUrl;
    final uri = Uri.parse('$baseUrl&lang=$docLang');

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  static void showAvatarAndPhotoPickerModal({
    required BuildContext context,
    required String currentAvatarUrl,
    required ValueChanged<String> onSelected,
  }) {
    final ImagePicker picker = ImagePicker();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.cardWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1D5DB),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    AppStrings.t('avatar_sheet_title'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.lightPurpleBg,
                  foregroundColor: AppColors.primaryPurple,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: AppColors.primaryPurple.withValues(alpha: 0.35),
                    ),
                  ),
                ),
                onPressed: () async {
                  try {
                    final XFile? file = await picker.pickImage(
                      source: ImageSource.gallery,
                      maxWidth: 360,
                      imageQuality: 80,
                    );
                    if (file != null) {
                      final bytes = await file.readAsBytes();
                      final dataUrl =
                          'data:image/jpeg;base64,${base64Encode(bytes)}';
                      onSelected(dataUrl);
                      if (ctx.mounted) Navigator.pop(ctx);
                    }
                  } catch (_) {}
                },
                icon: const Icon(Icons.photo_camera_back_rounded, size: 20),
                label: Text(
                  AppStrings.t('upload_my_photo'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              AppStrings.t('or_select_character'),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: AppColors.textGray,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 290,
              child: GridView.builder(
                itemCount: PingoAvatars.presets.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.82,
                ),
                itemBuilder: (_, idx) {
                  final item = PingoAvatars.presets[idx];
                  final url = item['url']!;
                  final styleKey = item['styleKey']!;
                  final isSelected = currentAvatarUrl == url;
                  return GestureDetector(
                    onTap: () {
                      onSelected(url);
                      Navigator.pop(ctx);
                    },
                    child: Column(
                      children: [
                        Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.primaryPurple
                                  : const Color(0xFFE5E7EB),
                              width: isSelected ? 3.2 : 1.5,
                            ),
                            boxShadow: isSelected
                                ? [
                                    BoxShadow(
                                      color: AppColors.primaryPurple.withValues(
                                        alpha: 0.3,
                                      ),
                                      blurRadius: 8,
                                    ),
                                  ]
                                : null,
                          ),
                          child: ClipOval(
                            child: Image.network(url, fit: BoxFit.cover),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          AppStrings.t(styleKey),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: isSelected
                                ? AppColors.primaryPurple
                                : AppColors.textGray,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

