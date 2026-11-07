import 'dart:core';
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
  final Map<String, String> memberPhones = {};
  final Map<String, bool> circleHiddenMap = {};
  final Set<String> blockedUserIds = {};

  final Map<String, List<LatLng>> myDailyRoutes = {};
  final Map<String, double> myDailyMaxSpeed = {};
  final Map<String, Map<String, List<LatLng>>> memberDailyRoutes = {};
  final Map<String, double> memberMaxSpeedMap = {};

  Map<String, String> get memberPhoneBook => memberPhones;

  DateTime? _lastServerPushTime;
  LatLng? _lastServerPushLatLng;
  StreamSubscription<List<PurchaseDetails>>? _iapSubscription;

  static const List<String> presetEmojiAvatars = [
    'avatar:🐶',
    'avatar:🐱',
    'avatar:🐰',
    'avatar:🦊',
    'avatar:🐻',
    'avatar:🐼',
    'avatar:🦁',
    'avatar:🐯',
    'avatar:🐨',
    'avatar:🐹',
    'avatar:🦄',
    'avatar:🐧',
  ];

  String get currentMapboxStyleId {
    if (mapStyleIndex == 1) return 'mapbox/streets-v12';
    if (mapStyleIndex == 2) return 'mapbox/dark-v11';
    return AppConfig.mapboxStyleId;
  }

  static String dateKeyOf(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String get todayKey => dateKeyOf(DateTime.now());
  static String get yesterdayKey =>
      dateKeyOf(DateTime.now().subtract(const Duration(days: 1)));

  Directory _resolvePersistentDirectory() {
    try {
      final tempDir = Directory.systemTemp;
      final parentDir = tempDir.parent;
      if (Platform.isIOS) {
        final docs = Directory('${parentDir.path}/Documents');
        if (docs.existsSync()) return docs;
      } else if (Platform.isAndroid) {
        final filesDir = Directory('${parentDir.path}/files');
        if (filesDir.existsSync()) return filesDir;
        try {
          filesDir.createSync(recursive: true);
          return filesDir;
        } catch (_) {}
      }
      return tempDir;
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  File _storageFile(String name) {
    final dir = _resolvePersistentDirectory();
    return File('${dir.path}/$name');
  }

  File _fallbackTempFile(String name) {
    return File('${Directory.systemTemp.path}/$name');
  }

  Future<String> _readPersistentText(String fileName) async {
    try {
      final f1 = _storageFile(fileName);
      if (await f1.exists()) return await f1.readAsString();
      final f2 = _fallbackTempFile(fileName);
      if (await f2.exists()) return await f2.readAsString();
    } catch (_) {}
    return '';
  }

  Future<void> _writePersistentText(String fileName, String content) async {
    try {
      await _storageFile(fileName).writeAsString(content, flush: true);
    } catch (_) {}
    try {
      await _fallbackTempFile(fileName).writeAsString(content, flush: true);
    } catch (_) {}
  }

  String buildCircleScopedUserId(String circleCode) {
    final base = currentUserId.isEmpty
        ? '00000000-0000-4000-8000-000000000000'
        : currentUserId;
    final cleanCode = circleCode
        .replaceAll(RegExp(r'[^0-9A-Za-z]'), '')
        .toLowerCase()
        .padRight(6, '0');
    final hexSuffix = cleanCode.codeUnits
        .take(6)
        .map((c) => (c % 16).toRadixString(16))
        .join();
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
    await _loadPersistentTimelineHistory();
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

  String _generateRandomUuidV4() {
    final rnd = math.Random();
    String hex(int len) =>
        List.generate(len, (_) => rnd.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-8${hex(3)}-${hex(12)}';
  }

  Future<void> _loadOrGeneratePersistentDeviceId() async {
    try {
      final raw = await _readPersistentText('pingo_device_identity_v3.txt');
      if (raw.trim().length >= 32) {
        currentUserId = raw.trim();
        return;
      }
      final oldRaw = await _readPersistentText('pingo_device_identity_v2.txt');
      if (oldRaw.trim().length >= 32) {
        currentUserId = oldRaw.trim();
        await _writePersistentText(
          'pingo_device_identity_v3.txt',
          currentUserId,
        );
        return;
      }
      currentUserId = _generateRandomUuidV4();
      await _writePersistentText('pingo_device_identity_v3.txt', currentUserId);
    } catch (_) {
      if (currentUserId.isEmpty) {
        currentUserId = _generateRandomUuidV4();
      }
    }
  }

  Future<void> _loadPersistentTimelineHistory() async {
    try {
      final rawJson = await _readPersistentText(
        'pingo_timeline_history_v4.json',
      );
      if (rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        final cutoff = DateTime.now().subtract(const Duration(days: 31));
        decoded.forEach((dKey, listVal) {
          final parsedDate = DateTime.tryParse(dKey);
          if (parsedDate != null &&
              parsedDate.isAfter(cutoff) &&
              listVal is List) {
            final pts = <LatLng>[];
            for (final item in listVal) {
              if (item is List && item.length >= 2) {
                pts.add(
                  LatLng(
                    (item[0] as num).toDouble(),
                    (item[1] as num).toDouble(),
                  ),
                );
              }
            }
            if (pts.isNotEmpty) {
              myDailyRoutes[dKey] = pts;
            }
          }
        });
      }
      final rawSpd = await _readPersistentText(
        'pingo_timeline_maxspeed_v3.json',
      );
      if (rawSpd.isNotEmpty) {
        final decodedSpd = jsonDecode(rawSpd) as Map<String, dynamic>;
        decodedSpd.forEach((k, v) {
          if (v is num) myDailyMaxSpeed[k] = v.toDouble();
        });
      }
      final rawRemote = await _readPersistentText(
        'pingo_remote_timelines_v3.json',
      );
      if (rawRemote.isNotEmpty) {
        final decodedRem = jsonDecode(rawRemote) as Map<String, dynamic>;
        decodedRem.forEach((uid, dayMap) {
          if (dayMap is Map) {
            memberDailyRoutes[uid] = {};
            dayMap.forEach((dKey, listVal) {
              if (listVal is List) {
                final pts = <LatLng>[];
                for (final item in listVal) {
                  if (item is List && item.length >= 2) {
                    pts.add(
                      LatLng(
                        (item[0] as num).toDouble(),
                        (item[1] as num).toDouble(),
                      ),
                    );
                  }
                }
                if (pts.isNotEmpty) {
                  memberDailyRoutes[uid]![dKey.toString()] = pts;
                }
              }
            });
          }
        });
      }
    } catch (_) {}
  }

  bool isDummyOrInvalidPoint(LatLng p) {
    if (p.latitude == 0.0 && p.longitude == 0.0) return true;
    return (p.latitude - 37.7599).abs() < 0.0005 &&
        (p.longitude - 126.7802).abs() < 0.0005;
  }

  List<LatLng> simplifyRouteRDP(
    List<LatLng> points, {
    double epsilonDegrees = 0.00015,
    int maxPoints = 85,
  }) {
    final clean = points.where((p) => !isDummyOrInvalidPoint(p)).toList();
    if (clean.length <= 3) return List<LatLng>.from(clean);

    List<LatLng> rdpRecursive(List<LatLng> pts, double eps) {
      if (pts.length < 3) return pts;
      double dmax = 0.0;
      int index = 0;
      final LatLng start = pts.first;
      final LatLng end = pts.last;

      for (int i = 1; i < pts.length - 1; i++) {
        final double d = _perpendicularDistance(pts[i], start, end);
        if (d > dmax) {
          index = i;
          dmax = d;
        }
      }

      if (dmax > eps) {
        final rec1 = rdpRecursive(pts.sublist(0, index + 1), eps);
        final rec2 = rdpRecursive(pts.sublist(index), eps);
        return <LatLng>[...rec1.sublist(0, rec1.length - 1), ...rec2];
      } else {
        return <LatLng>[start, end];
      }
    }

    var result = rdpRecursive(clean, epsilonDegrees);
    double currentEps = epsilonDegrees;
    while (result.length > maxPoints && result.length > 6) {
      currentEps *= 1.45;
      result = rdpRecursive(result, currentEps);
    }
    return result;
  }

  double _perpendicularDistance(LatLng pt, LatLng lineStart, LatLng lineEnd) {
    final double dx = lineEnd.longitude - lineStart.longitude;
    final double dy = lineEnd.latitude - lineStart.latitude;
    final double mag = math.sqrt(dx * dx + dy * dy);
    if (mag < 1e-9) {
      final double px = pt.longitude - lineStart.longitude;
      final double py = pt.latitude - lineStart.latitude;
      return math.sqrt(px * px + py * py);
    }
    final double u =
        (((pt.longitude - lineStart.longitude) * dx) +
            ((pt.latitude - lineStart.latitude) * dy)) /
        (mag * mag);
    final double ix = lineStart.longitude + u * dx;
    final double iy = lineStart.latitude + u * dy;
    final double distX = pt.longitude - ix;
    final double distY = pt.latitude - iy;
    return math.sqrt(distX * distX + distY * distY);
  }

  DateTime? _lastBreadcrumbRecordedAt;

  Future<List<LatLng>> recordMyLocationBreadcrumb(
    LatLng point, {
    double speedKmh = 0.0,
  }) async {
    final tKey = todayKey;
    myDailyRoutes.forEach((k, pts) {
      pts.removeWhere(isDummyOrInvalidPoint);
    });

    if (isDummyOrInvalidPoint(point)) {
      return List<LatLng>.from(myDailyRoutes[tKey] ?? <LatLng>[]);
    }

    final list = myDailyRoutes.putIfAbsent(tKey, () => <LatLng>[]);
    final now = DateTime.now();

    if (list.isEmpty) {
      list.add(point);
      _lastBreadcrumbRecordedAt = now;
    } else {
      final dist = calculateDistanceMeters(list.last, point);
      final elapsedMins = _lastBreadcrumbRecordedAt == null
          ? 999
          : now.difference(_lastBreadcrumbRecordedAt!).inMinutes;

      if (dist >= 25.0 && dist <= 5000.0) {
        // 1) 정상 이동 (25m 이상 이동 시 궤적 추가)
        list.add(point);
        _lastBreadcrumbRecordedAt = now;
      } else if (dist < 25.0 && speedKmh < 2.5 && elapsedMins >= 5) {
        // 2) 커피숍·술집·식당 등 실내 장기 체류 감지:
        // 움직이지 않고 한자리에 가만히 앉아 있어도 5분마다 체류 샘플을 누적하여
        // 길거리 잠깐 대기(5분 미만)와 확실하게 체류 점수 차이를 벌림!
        list.add(list.last);
        _lastBreadcrumbRecordedAt = now;
      } else if (dist > 5000.0 && list.length <= 2) {
        list
          ..clear()
          ..add(point);
        _lastBreadcrumbRecordedAt = now;
      }
    }

    final prevMax = myDailyMaxSpeed[tKey] ?? 0.0;
    if (speedKmh > prevMax) {
      myDailyMaxSpeed[tKey] = speedKmh;
    }

    try {
      final serialized = <String, dynamic>{};
      myDailyRoutes.forEach((k, v) {
        final validPts = v.where((p) => !isDummyOrInvalidPoint(p)).toList();
        if (validPts.isNotEmpty) {
          serialized[k] = validPts
              .map(
                (p) => [
                  double.parse(p.latitude.toStringAsFixed(5)),
                  double.parse(p.longitude.toStringAsFixed(5)),
                ],
              )
              .toList();
        }
      });
      await _writePersistentText(
        'pingo_timeline_history_v4.json',
        jsonEncode(serialized),
      );
      await _writePersistentText(
        'pingo_timeline_maxspeed_v4.json',
        jsonEncode(myDailyMaxSpeed),
      );
    } catch (_) {}
    return List<LatLng>.from(list);
  }

  final Set<String> _pendingGeocodeKeys = {};
  void Function()? onTimelineMetaUpdated;

  List<LatLng> getRouteForMemberTab(
    String memberId,
    int tabIndex,
    LatLng fallbackLoc, {
    String? customDateKey,
  }) {
    final isMe = memberId == 'm1' || memberId == currentUserId;
    final sourceMap = isMe ? myDailyRoutes : memberDailyRoutes[memberId];

    List<LatLng> rawWaypoints = <LatLng>[];

    // 나(m1)는 절대 데모 경로를 타지 않고 실제 GPS 기록만 사용! 데모는 m2, m3 전용
    if (!isMe &&
        (memberId == 'm2' || memberId == 'm3') &&
        (sourceMap == null || sourceMap.isEmpty)) {
      final base = isDummyOrInvalidPoint(fallbackLoc)
          ? const LatLng(37.2636, 127.0286)
          : fallbackLoc;
      if (memberId == 'm2') {
        if (tabIndex == 0) {
          // 출발 ➔ 카페(장기 체류) ➔ 마트/식당(장기 체류) ➔ 현재 위치 시뮬레이션
          rawWaypoints = <LatLng>[
            LatLng(base.latitude - 0.0045, base.longitude - 0.0032),
            LatLng(base.latitude - 0.0045, base.longitude - 0.0032),
            LatLng(base.latitude - 0.0045, base.longitude - 0.0032),
            LatLng(base.latitude - 0.0018, base.longitude - 0.0015),
            LatLng(base.latitude - 0.0018, base.longitude - 0.0015),
            LatLng(base.latitude - 0.0018, base.longitude - 0.0015),
            LatLng(base.latitude - 0.0018, base.longitude - 0.0015),
            base,
          ];
        } else {
          rawWaypoints = <LatLng>[
            LatLng(base.latitude + 0.0048, base.longitude - 0.0035),
            LatLng(base.latitude + 0.0048, base.longitude - 0.0035),
            LatLng(base.latitude + 0.0021, base.longitude + 0.0014),
            LatLng(base.latitude + 0.0021, base.longitude + 0.0014),
            LatLng(base.latitude + 0.0021, base.longitude + 0.0014),
            base,
          ];
        }
      } else {
        // m3 데모 친구도 오늘/어제 뚜렷한 거점 핀과 상호명이 나오도록 구성
        if (tabIndex == 0) {
          rawWaypoints = <LatLng>[
            LatLng(base.latitude + 0.0032, base.longitude + 0.0028),
            LatLng(base.latitude + 0.0032, base.longitude + 0.0028),
            LatLng(base.latitude + 0.0032, base.longitude + 0.0028),
            base,
          ];
        } else {
          rawWaypoints = <LatLng>[
            LatLng(base.latitude - 0.0038, base.longitude + 0.0022),
            LatLng(base.latitude - 0.0038, base.longitude + 0.0022),
            LatLng(base.latitude - 0.0015, base.longitude - 0.0012),
            LatLng(base.latitude - 0.0015, base.longitude - 0.0012),
            LatLng(base.latitude - 0.0015, base.longitude - 0.0012),
            base,
          ];
        }
      }
    } else if (sourceMap == null) {
      rawWaypoints = isDummyOrInvalidPoint(fallbackLoc)
          ? <LatLng>[]
          : <LatLng>[fallbackLoc];
    } else if (customDateKey != null && customDateKey.isNotEmpty) {
      final r = sourceMap[customDateKey];
      rawWaypoints = r == null
          ? <LatLng>[]
          : r.where((p) => !isDummyOrInvalidPoint(p)).toList();
    } else if (tabIndex == 0) {
      final r = sourceMap[todayKey];
      final valid = r == null
          ? <LatLng>[]
          : r.where((p) => !isDummyOrInvalidPoint(p)).toList();
      rawWaypoints = valid.isNotEmpty
          ? valid
          : (isDummyOrInvalidPoint(fallbackLoc)
                ? <LatLng>[]
                : <LatLng>[fallbackLoc]);
    } else if (tabIndex == 1) {
      final r = sourceMap[yesterdayKey];
      rawWaypoints = r == null
          ? <LatLng>[]
          : r.where((p) => !isDummyOrInvalidPoint(p)).toList();
    } else {
      final sortedKeys = sourceMap.keys.toList()..sort();
      for (int i = sortedKeys.length - 1; i >= 0; i--) {
        final raw = sourceMap[sortedKeys[i]];
        if (raw == null) continue;
        final pts = raw.where((p) => !isDummyOrInvalidPoint(p)).toList();
        if (pts.isNotEmpty) {
          rawWaypoints = pts;
          break;
        }
      }
      if (rawWaypoints.isEmpty && !isDummyOrInvalidPoint(fallbackLoc)) {
        rawWaypoints = <LatLng>[fallbackLoc];
      }
    }

    return rawWaypoints;
  }

  // 주소 문자열이 단순 도로명/행정동인지, 아니면 실제 상호명(POI: 카페/술집/매장)인지 판별
  bool _isLikelyPoiName(String name) {
    final t = name.trim();
    if (t.isEmpty || t == AppStrings.t('loading_address')) return false;
    if (RegExp(r'^\d+\.\d+').hasMatch(t)) return false;
    // 도로명 주소 패턴 (~로 123, ~길 45, ~대로) 또는 단순 동/구/시 패턴이면 일반 주소로 판정
    final isRoadPattern = RegExp(r'(대로|번길|로|길)\s*\d*|([가-힣]+(동|구|읍|면|리))$')
        .hasMatch(t);
    return !isRoadPattern;
  }

  String resolvePlaceOrPoiName(
    LatLng point, {
    List<SafePlaceData>? safePlaces,
  }) {
    if (safePlaces != null) {
      for (final sp in safePlaces) {
        final d = calculateDistanceMeters(point, sp.point);
        if (d <= math.max(sp.radiusMeters, 90.0)) {
          return sp.name;
        }
      }
    }
    final key =
        '${point.latitude.toStringAsFixed(4)}_${point.longitude.toStringAsFixed(4)}';
    final cached = _roadAddressCache[key];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    if (!_pendingGeocodeKeys.contains(key)) {
      _pendingGeocodeKeys.add(key);
      _fetchPoiOrRoadNameInBackground(point, key);
    }
    return AppStrings.t('loading_address');
  }

  Future<void> _fetchPoiOrRoadNameInBackground(
    LatLng point,
    String cacheKey,
  ) async {
    final label = await _lookupHybridPoiAndRoad(point);
    if (label.isNotEmpty) {
      _roadAddressCache[cacheKey] = label;
      onTimelineMetaUpdated?.call();
    } else {
      _pendingGeocodeKeys.remove(cacheKey);
    }
  }

  Future<String> _lookupHybridPoiAndRoad(LatLng point) async {
    final langCode = AppStrings.lang;
    const token =
        'pk.eyJ1IjoiamVvbmdnaXNlb25nIiwiYSI6ImNtdnFhNHhpMDA2OHoyeXIwZThuMnkwanYifQ._Zouj-a9d2NaLWCVyRKwiQ';

    String mbPoi = '';
    String mbAddr = '';
    String mbDong = '';

    // 1차(초고속·무차단): Mapbox 역지오코딩 (limit 파라미터 제거로 422 에러 원천 차단!)
    try {
      final mbUrl = Uri.parse(
        'https://api.mapbox.com/geocoding/v5/mapbox.places/${point.longitude},${point.latitude}.json'
        '?types=poi,address,neighborhood,locality&language=$langCode&access_token=$token',
      );
      final res = await http.get(mbUrl).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final features = data['features'] as List?;
        if (features != null && features.isNotEmpty) {
          for (final dynamic item in features) {
            final types = (item['place_type'] as List?)?.cast<String>() ?? [];
            final txt = (item['text'] ?? '').toString().trim();
            final addrNum = (item['address'] ?? '').toString().trim();
            if (types.contains('poi') && mbPoi.isEmpty && txt.isNotEmpty) {
              mbPoi = txt;
            } else if (types.contains('address') &&
                mbAddr.isEmpty &&
                txt.isNotEmpty) {
              mbAddr = addrNum.isNotEmpty ? '$txt $addrNum' : txt;
            } else if ((types.contains('neighborhood') ||
                    types.contains('locality')) &&
                mbDong.isEmpty &&
                txt.isNotEmpty) {
              mbDong = txt;
            }
          }
          // 등록된 상호(POI)가 있으면 군더더기 주소 없이 깔끔하게 상호명만 즉시 반환!
          if (mbPoi.isNotEmpty) return mbPoi;
        }
      }
    } catch (_) {}

    // 2차(상세 한국 상가/건물명 보강): OpenStreetMap Nominatim (zoom=18)
    try {
      final osmUrl = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${point.latitude}&lon=${point.longitude}&zoom=18&addressdetails=1&accept-language=$langCode',
      );
      final osmRes = await http
          .get(osmUrl, headers: {'User-Agent': 'PingoSafetyApp/1.0'})
          .timeout(const Duration(seconds: 3));
      if (osmRes.statusCode == 200) {
        final data = jsonDecode(osmRes.body);
        final String poiName = (data['name'] ?? '').toString().trim();
        final addr = data['address'] as Map<String, dynamic>?;
        String dong = '';
        String road = '';
        String houseNum = '';
        String building = '';
        if (addr != null) {
          dong =
              (addr['quarter'] ??
                      addr['neighbourhood'] ??
                      addr['suburb'] ??
                      addr['village'] ??
                      addr['town'] ??
                      '')
                  .toString()
                  .trim();
          road = (addr['road'] ?? addr['pedestrian'] ?? '').toString().trim();
          houseNum = (addr['house_number'] ?? '').toString().trim();
          building =
              (addr['amenity'] ??
                      addr['shop'] ??
                      addr['building'] ??
                      addr['tourism'] ??
                      addr['office'] ??
                      '')
                  .toString()
                  .trim();
        }
        final String bestPoi = poiName.isNotEmpty ? poiName : building;
        if (bestPoi.isNotEmpty && bestPoi != road && bestPoi != dong) {
          return bestPoi;
        }
        if (road.isNotEmpty) {
          return houseNum.isNotEmpty ? '$road $houseNum' : road;
        }
        if (dong.isNotEmpty) return dong;
      }
    } catch (_) {}

    if (mbAddr.isNotEmpty) return mbAddr;
    if (mbDong.isNotEmpty) return mbDong;
    return '';
  }

  List getThirtyDaysDailyBreakdown(
    String memberId,
    LatLng fallbackLoc, {
    List<SafePlaceData>? safePlaces,
  }) {
    final isMe = memberId == 'm1' || memberId == currentUserId;
    final sourceMap = isMe ? myDailyRoutes : memberDailyRoutes[memberId];
    final result = [];

    if (sourceMap != null) {
      final keys = sourceMap.keys.toList()..sort((a, b) => b.compareTo(a));
      for (final k in keys) {
        final rawPts = sourceMap[k];
        if (rawPts == null) continue;
        final pts = rawPts.where((p) => !isDummyOrInvalidPoint(p)).toList();
        if (pts.isEmpty) continue;
        final distKm = computeRouteDistanceKm(pts);
        final steps = buildDetailedTimelineSteps(pts, safePlaces: safePlaces);
        final placesCnt = steps.length;
        final mins = pts.length < 2
            ? 0
            : (distKm * 6.5 + placesCnt * 12).round();
        result.add({
          'dateKey': k,
          'points': pts,
          'distanceKm': distKm,
          'placesCount': placesCnt,
          'minutes': mins,
        });
      }
    }

    if (result.isEmpty && !isMe && (memberId == 'm2' || memberId == 'm3')) {
      final now = DateTime.now();
      for (int d = 0; d < 5; d++) {
        final dt = now.subtract(Duration(days: d));
        final dk =
            '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
        final demoPts = getRouteForMemberTab(
          memberId,
          d == 0 ? 0 : 1,
          fallbackLoc,
        );
        final distKm = computeRouteDistanceKm(demoPts);
        final steps = buildDetailedTimelineSteps(
          demoPts,
          safePlaces: safePlaces,
        );
        result.add({
          'dateKey': dk,
          'points': demoPts,
          'distanceKm': distKm,
          'placesCount': steps.length,
          'minutes': (distKm * 8 + steps.length * 15).round().clamp(15, 240),
        });
      }
    }
    return result;
  }

  List buildDetailedTimelineSteps(
    List<LatLng> validRoute, {
    List<SafePlaceData>? safePlaces,
  }) {
    final cleanPts = validRoute
        .where((p) => !isDummyOrInvalidPoint(p))
        .toList();
    if (cleanPts.isEmpty) return [];
    if (cleanPts.length == 1) {
      final placeName = resolvePlaceOrPoiName(
        cleanPts.first,
        safePlaces: safePlaces,
      );
      return [
        {
          'type': 'end',
          'stopNumber': 1,
          'point': cleanPts.first,
          'placeName': placeName,
          'stayMinutes': 15,
          'stayLabel': AppStrings.t('status_staying'),
          'tripMode': 'stay',
          'tripLabel': '',
          'segmentKm': 0.0,
          'tripMinutes': 0,
          'progressRatio': 1.0,
        },
      ];
    }

    // 1단계: 근접 정차 병합 (반경 75m 이내 점들을 하나의 클러스터로 묶어 술집 앞 대리/택시 대기 등을 하나로 흡수)
    final List<LatLng> clusterCenters = [cleanPts.first];
    final List<int> clusterCounts = [1];

    for (int i = 1; i < cleanPts.length; i++) {
      final dist = calculateDistanceMeters(clusterCenters.last, cleanPts[i]);
      if (dist <= 75.0) {
        clusterCounts[clusterCounts.length - 1]++;
      } else {
        clusterCenters.add(cleanPts[i]);
        clusterCounts.add(1);
      }
    }

    // 2단계: 길거리 대기(10번) vs 실제 방문지(카페/술집 2~3번) 가중치 평가 (Significance Scoring)
    // 출발지(index 0)와 최종 도착지(last index)는 무조건 유지하고, 중간 후보지들만 점수를 매겨 상위 거점(최대 5곳) 선발
    final List<int> selectedIndices = [0];
    if (clusterCenters.length > 2) {
      final List midCandidates = [];
      for (int i = 1; i < clusterCenters.length - 1; i++) {
        final pt = clusterCenters[i];
        final cnt = clusterCounts[i];
        final distFromStart = calculateDistanceMeters(clusterCenters.first, pt);
        final distToEnd = calculateDistanceMeters(pt, clusterCenters.last);
        if (distFromStart < 85.0 || distToEnd < 85.0) continue;

        final resolvedName = resolvePlaceOrPoiName(pt, safePlaces: safePlaces);
        final bool isPoi = _isLikelyPoiName(resolvedName);
        final int estStayMins = cnt * 7;

        // 중요도 점수 계산: 상호명(POI)이 있으면 2.5배 가중치, 단순 도로명이면 0.4배 페널티
        final double score = estStayMins * (isPoi ? 2.5 : 0.4);

        // 길거리 단순 정차 탈락 기준:
        // - 상호(POI)가 있는 카페/술집은 10분 이상(cnt >= 2) 머물면 통과
        // - 상호가 없는 단순 도로/길가는 최소 28분 이상(cnt >= 4) 머물러야만 통과 (잠깐 차/친구 기다린 곳 100% 탈락!)
        final bool passesCutoff = isPoi ? (cnt >= 2) : (cnt >= 4);
        if (passesCutoff || clusterCenters.length <= 4) {
          midCandidates.add({'index': i, 'score': score});
        }
      }

      // 점수가 가장 높은 상위 5개 핵심 방문지(카페·술집 등)만 추린 뒤, 다시 시간순(index 오름차순) 정렬
      midCandidates.sort(
        (a, b) => (b['score'] as double).compareTo(a['score'] as double),
      );
      final topMids = midCandidates.take(5).toList()
        ..sort((a, b) => (a['index'] as int).compareTo(b['index'] as int));

      for (final item in topMids) {
        selectedIndices.add(item['index'] as int);
      }
    }
    if (clusterCenters.length > 1) {
      final lastIdx = clusterCenters.length - 1;
      if (calculateDistanceMeters(
                clusterCenters[selectedIndices.last],
                clusterCenters[lastIdx],
              ) >=
              50.0 ||
          selectedIndices.length == 1) {
        selectedIndices.add(lastIdx);
      }
    }

    // 3단계: 선발된 핵심 거점들의 상호명 매핑 & 연속 동일 상호 병합 + 탈락한 길거리 대기 구간은 이동(Trip) 거리·시간에 합산
    final List mergedSteps = [];
    for (int k = 0; k < selectedIndices.length; k++) {
      final int currClusterIdx = selectedIndices[k];
      final LatLng pt = clusterCenters[currClusterIdx];
      final String placeName = resolvePlaceOrPoiName(
        pt,
        safePlaces: safePlaces,
      );

      // 이전 선발 거점부터 현재 선발 거점 사이의 실제 누적 이동 거리 계산 (중간에 탈락한 길거리 대기 구간 거리 포함)
      double segKm = 0.0;
      int transitWaitMins = 0;
      if (k > 0) {
        final int prevClusterIdx = selectedIndices[k - 1];
        for (int m = prevClusterIdx + 1; m <= currClusterIdx; m++) {
          segKm +=
              calculateDistanceMeters(
                clusterCenters[m - 1],
                clusterCenters[m],
              ) /
              1000.0;
          if (m < currClusterIdx) {
            transitWaitMins += clusterCounts[m] * 3;
          }
        }
      }

      final int stayMins = (clusterCounts[currClusterIdx] * 12).clamp(10, 240);

      if (mergedSteps.isNotEmpty &&
          placeName != AppStrings.t('loading_address') &&
          mergedSteps.last['placeName'] == placeName) {
        mergedSteps.last['segmentKm'] =
            (mergedSteps.last['segmentKm'] as double) + segKm;
        mergedSteps.last['point'] = pt;
        mergedSteps.last['stayMinutes'] =
            (mergedSteps.last['stayMinutes'] as int) + stayMins;
        final int updatedStay = mergedSteps.last['stayMinutes'] as int;
        mergedSteps.last['stayLabel'] =
            '$updatedStay${AppStrings.t('stat_mins_unit')} ${AppStrings.t('status_staying')}';
      } else {
        final bool isDriving = segKm >= 0.85;
        final int baseMoveMins = segKm <= 0.01
            ? 0
            : (isDriving
                  ? (segKm * 2.4).round().clamp(2, 180)
                  : (segKm * 12.0).round().clamp(2, 120));
        final int tripMins = baseMoveMins + transitWaitMins;
        final String distStr = segKm >= 1.0
            ? '${segKm.toStringAsFixed(1)}km'
            : '${(segKm * 1000).round()}m';
        final String tripMode = segKm <= 0.01
            ? 'stay'
            : (isDriving ? 'drive' : 'walk');
        final String tripLabel = segKm <= 0.01
            ? ''
            : (isDriving
                  ? '🚗 ${AppStrings.t('status_driving')} $distStr · $tripMins${AppStrings.t('stat_mins_unit')}'
                  : '🚶 ${AppStrings.t('status_walking')} $distStr · $tripMins${AppStrings.t('stat_mins_unit')}');

        mergedSteps.add({
          'type': 'waypoint',
          'stopNumber': mergedSteps.length + 1,
          'point': pt,
          'placeName': placeName,
          'stayMinutes': stayMins,
          'stayLabel':
              '$stayMins${AppStrings.t('stat_mins_unit')} ${AppStrings.t('status_staying')}',
          'tripMode': tripMode,
          'tripLabel': tripLabel,
          'segmentKm': segKm,
          'tripMinutes': tripMins,
          'progressRatio': 0.0,
        });
      }
    }

    final int total = mergedSteps.length;
    for (int i = 0; i < total; i++) {
      mergedSteps[i]['stopNumber'] = i + 1;
      mergedSteps[i]['type'] = i == 0
          ? 'start'
          : (i == total - 1 ? 'end' : 'waypoint');
      mergedSteps[i]['progressRatio'] = total <= 1 ? 1.0 : i / (total - 1);
    }

    return mergedSteps;
  }

  double computeRouteDistanceKm(List<LatLng> pts) {
    if (pts.length < 2) return 0.0;
    double sumM = 0.0;
    for (int i = 1; i < pts.length; i++) {
      sumM += calculateDistanceMeters(pts[i - 1], pts[i]);
    }
    return sumM / 1000.0;
  }

  double getMaxSpeedForMemberTab(
    String memberId,
    int tabIndex,
    double currentSpd,
  ) {
    final isMe = memberId == 'm1' || memberId == currentUserId;
    if (isMe) {
      if (tabIndex == 0) {
        return math.max(myDailyMaxSpeed[todayKey] ?? 0.0, currentSpd);
      } else if (tabIndex == 1) {
        return myDailyMaxSpeed[yesterdayKey] ?? 0.0;
      } else {
        double m = currentSpd;
        for (final v in myDailyMaxSpeed.values) {
          if (v > m) m = v;
        }
        return m;
      }
    } else {
      return math.max(memberMaxSpeedMap[memberId] ?? 0.0, currentSpd);
    }
  }

  String _encodeMyCompactRouteMeta() {
    List<List<double>> compress(List<LatLng>? src, int maxPts) {
      if (src == null || src.isEmpty) return [];
      // 등간격 삭제(직선화 원인) 대신 RDP 도로 굴곡(코너 꼭짓점) 보존 압축 적용!
      final simplified = simplifyRouteRDP(
        src,
        epsilonDegrees: 0.00015,
        maxPoints: maxPts,
      );
      return simplified
          .map(
            (p) => [
              double.parse(p.latitude.toStringAsFixed(5)),
              double.parse(p.longitude.toStringAsFixed(5)),
            ],
          )
          .toList();
    }

    final histMap = <String, dynamic>{};
    final sortedKeys = myDailyRoutes.keys.toList()..sort();
    for (final k in sortedKeys.reversed.take(14)) {
      if (k == todayKey || k == yesterdayKey) continue;
      final cPts = compress(myDailyRoutes[k], 24);
      if (cPts.isNotEmpty) histMap[k] = cPts;
    }

    final map = <String, dynamic>{
      't': compress(myDailyRoutes[todayKey], 65),
      'y': compress(myDailyRoutes[yesterdayKey], 45),
      'h': histMap,
      'p': sharedPlacesPayload,
      'ms': double.parse((myDailyMaxSpeed[todayKey] ?? 0.0).toStringAsFixed(1)),
    };
    return base64Encode(utf8.encode(jsonEncode(map)));
  }

  List<dynamic> sharedPlacesPayload = [];
  void Function(List<dynamic>)? onRemotePlacesSynced;

  Future<void> decodeAndStoreRemoteMemberRoute(
    String uid,
    String encodedB64,
    LatLng currentPt,
    double currentSpd,
  ) async {
    final mMap = memberDailyRoutes.putIfAbsent(
      uid,
      () => <String, List<LatLng>>{},
    );
    if (currentSpd > (memberMaxSpeedMap[uid] ?? 0.0)) {
      memberMaxSpeedMap[uid] = currentSpd;
    }
    if (encodedB64.isNotEmpty) {
      try {
        final jsonStr = utf8.decode(base64Decode(encodedB64));
        final data = jsonDecode(jsonStr) as Map<String, dynamic>;
        if (data['t'] is List) {
          final tPts = <LatLng>[];
          for (final item in (data['t'] as List)) {
            if (item is List && item.length >= 2) {
              tPts.add(
                LatLng(
                  (item[0] as num).toDouble(),
                  (item[1] as num).toDouble(),
                ),
              );
            }
          }
          if (tPts.isNotEmpty) mMap[todayKey] = tPts;
        }
        if (data['y'] is List) {
          final yPts = <LatLng>[];
          for (final item in (data['y'] as List)) {
            if (item is List && item.length >= 2) {
              yPts.add(
                LatLng(
                  (item[0] as num).toDouble(),
                  (item[1] as num).toDouble(),
                ),
              );
            }
          }
          if (yPts.isNotEmpty) mMap[yesterdayKey] = yPts;
        }
        if (data['ms'] is num) {
          final ms = (data['ms'] as num).toDouble();
          if (ms > (memberMaxSpeedMap[uid] ?? 0.0)) {
            memberMaxSpeedMap[uid] = ms;
          }
        }
      } catch (_) {}
    }
    final tList = mMap.putIfAbsent(todayKey, () => <LatLng>[]);
    if (tList.isEmpty) {
      tList.add(currentPt);
    } else if (calculateDistanceMeters(tList.last, currentPt) >= 12.0) {
      tList.add(currentPt);
    }
    try {
      final out = <String, dynamic>{};
      memberDailyRoutes.forEach((mUid, dMap) {
        out[mUid] = {};
        dMap.forEach((dKey, pts) {
          out[mUid][dKey] = pts
              .map(
                (p) => [
                  double.parse(p.latitude.toStringAsFixed(4)),
                  double.parse(p.longitude.toStringAsFixed(4)),
                ],
              )
              .toList();
        });
      });
      await _writePersistentText(
        'pingo_remote_timelines_v3.json',
        jsonEncode(out),
      );
    } catch (_) {}
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
    final targetPhone = (phone ?? rawPhone ?? '').replaceAll(
      RegExp(r'[^0-9+]'),
      '',
    );
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
    final target =
        rawUrl ??
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
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
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
                              final b64 = base64Encode(bytes);
                              final dataUrl = 'data:image/jpeg;base64,$b64';
                              instance.myCustomAvatarDataUrl = dataUrl;
                              if (onSelected != null) onSelected(dataUrl);
                              if (ctx.mounted) Navigator.pop(ctx, dataUrl);
                            }
                          } catch (_) {}
                        },
                        icon: const Icon(Icons.photo_library_rounded, size: 18),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(AppStrings.t('pick_photo_gallery')),
                        ),
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
                              final b64 = base64Encode(bytes);
                              final dataUrl = 'data:image/jpeg;base64,$b64';
                              instance.myCustomAvatarDataUrl = dataUrl;
                              if (onSelected != null) onSelected(dataUrl);
                              if (ctx.mounted) Navigator.pop(ctx, dataUrl);
                            }
                          } catch (_) {}
                        },
                        icon: const Icon(Icons.camera_alt_rounded, size: 18),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(AppStrings.t('pick_photo_camera')),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: PingoAvatars.presets.map((preset) {
                    final imgUrl = preset['url']!;
                    final isSelected = activeAvatar == imgUrl;
                    return GestureDetector(
                      onTap: () {
                        instance.myCustomAvatarDataUrl = imgUrl;
                        if (onSelected != null) onSelected(imgUrl);
                        Navigator.pop(ctx, imgUrl);
                      },
                      child: Container(
                        width: 54,
                        height: 54,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F0FF),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected
                                ? const Color(0xFF6C47FF)
                                : const Color(0xFFE4E7EC),
                            width: isSelected ? 2.8 : 1.5,
                          ),
                        ),
                        child: ClipOval(
                          child: Image.network(
                            imgUrl,
                            width: 50,
                            height: 50,
                            fit: BoxFit.cover,
                          ),
                        ),
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
    try {
      final targetName = (userName ?? myUserName).trim();
      final scopedId = buildCircleScopedUserId(circleCode);

      // 'locations' 테이블에서 내 현재 scopedId가 아닌데 내 이름과 똑같거나 파주 초기 좌표(37.7599, 126.7802)인 유령 행을 모두 삭제
      final rows = await Supabase.instance.client
          .from('locations')
          .select('user_id, user_name, lat, lng')
          .eq('circle_code', circleCode);

      for (final dynamic r in rows) {
        final uid = (r['user_id'] ?? '').toString();
        final uName = (r['user_name'] ?? '').toString().trim();
        final lat = (r['lat'] as num?)?.toDouble() ?? 0.0;
        final lng = (r['lng'] as num?)?.toDouble() ?? 0.0;
        final isPajuGhost =
            (lat - 37.7599).abs() < 0.0005 && (lng - 126.7802).abs() < 0.0005;

        if (uid != scopedId &&
            uid != currentUserId &&
            (uName == targetName || isPajuGhost)) {
          await Supabase.instance.client
              .from('locations')
              .delete()
              .eq('circle_code', circleCode)
              .eq('user_id', uid);
        }
      }
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
      final response = await InAppPurchase.instance.queryProductDetails({
        targetId,
      });
      if (response.productDetails.isNotEmpty) {
        final param = PurchaseParam(
          productDetails: response.productDetails.first,
        );
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
    if (safePlaces != null) {
      for (final sp in safePlaces) {
        if (calculateDistanceMeters(point, sp.point) <=
            math.max(sp.radiusMeters, 90.0)) {
          return sp.name;
        }
      }
    }
    if (!forceLookup && speedKmh >= 15.0) {
      return '🚗 ${AppStrings.t('status_driving')} (${speedKmh.toStringAsFixed(0)} km/h)';
    }
    final key =
        '${point.latitude.toStringAsFixed(4)}_${point.longitude.toStringAsFixed(4)}';
    if (_roadAddressCache.containsKey(key)) {
      return _roadAddressCache[key]!;
    }
    final label = await _lookupHybridPoiAndRoad(point);
    if (label.isNotEmpty) {
      _roadAddressCache[key] = label;
      return label;
    }
    return '${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}';
  }

  Future<List<LatLng>> fetchRoadSnappedRoute(
    dynamic firstPointOrList, [
    LatLng? secondPoint,
    String? profileOpt,
  ]) async {
    List<LatLng> waypoints = <LatLng>[];
    if (firstPointOrList is List<LatLng>) {
      waypoints = firstPointOrList;
    } else if (firstPointOrList is LatLng && secondPoint != null) {
      waypoints = <LatLng>[firstPointOrList, secondPoint];
    }
    if (waypoints.length < 2) return waypoints;

    final sampled = waypoints.length > 6
        ? simplifyRouteRDP(waypoints, epsilonDegrees: 0.00035, maxPoints: 6)
        : waypoints;

    final coordStr = sampled
        .map(
          (p) =>
              '${p.longitude.toStringAsFixed(5)},${p.latitude.toStringAsFixed(5)}',
        )
        .join(';');

    const token =
        'pk.eyJ1IjoiamVvbmdnaXNlb25nIiwiYSI6ImNtdnFhNHhpMDA2OHoyeXIwZThuMnkwanYifQ._Zouj-a9d2NaLWCVyRKwiQ';
    final url = Uri.parse(
      'https://api.mapbox.com/directions/v5/mapbox/walking/$coordStr'
      '?geometries=geojson&overview=full&access_token=$token',
    );

    try {
      final res = await http.get(url).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final coords = routes.first['geometry']?['coordinates'] as List?;
          if (coords != null && coords.length >= 2) {
            return coords.map((c) {
              final num lng = c[0] as num;
              final num lat = c[1] as num;
              return LatLng(lat.toDouble(), lng.toDouble());
            }).toList();
          }
        }
      }
    } catch (_) {}

    return _computeSmoothedRoute(waypoints);
  }

  List<LatLng> _computeSmoothedRoute(
    dynamic firstPointOrList, [
    LatLng? secondPoint,
  ]) {
    List<LatLng> waypoints = <LatLng>[];
    if (firstPointOrList is List<LatLng>) {
      waypoints = firstPointOrList;
    } else if (firstPointOrList is LatLng && secondPoint != null) {
      waypoints = <LatLng>[firstPointOrList, secondPoint];
    }
    if (waypoints.length < 2) return waypoints;
    final List<LatLng> smoothed = <LatLng>[];
    for (int i = 0; i < waypoints.length - 1; i++) {
      final p0 = waypoints[i];
      final p1 = waypoints[i + 1];
      smoothed.add(p0);
      smoothed.add(
        LatLng(
          p0.latitude * 0.67 + p1.latitude * 0.33,
          p0.longitude * 0.67 + p1.longitude * 0.33,
        ),
      );
      smoothed.add(
        LatLng(
          p0.latitude * 0.33 + p1.latitude * 0.67,
          p0.longitude * 0.33 + p1.longitude * 0.67,
        ),
      );
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
    if (currentUserId.isEmpty) {
      await _loadOrGeneratePersistentDeviceId();
    }
    final targetPos = point ?? position ?? const LatLng(37.5665, 126.9780);
    final targetBat = battery ?? batteryLevel ?? 90;
    final rawClip = audioClipDataUrl ?? signalClip ?? '';

    await recordMyLocationBreadcrumb(targetPos, speedKmh: speedKmh);

    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      myCustomAvatarDataUrl = avatarUrl;
    }

    final hasUrgentSignal =
        isSos ||
        forceImmediate ||
        (rawClip.isNotEmpty &&
            !rawClip.startsWith('BUBBLE::') &&
            !rawClip.startsWith('META::'));
    final now = DateTime.now();
    if (!hasUrgentSignal &&
        _lastServerPushTime != null &&
        _lastServerPushLatLng != null) {
      final elapsedSec = now.difference(_lastServerPushTime!).inSeconds;
      final movedMeters = calculateDistanceMeters(
        _lastServerPushLatLng!,
        targetPos,
      );
      if (elapsedSec < 8 && movedMeters < 12.0) {
        return;
      }
    }

    _lastServerPushTime = now;
    _lastServerPushLatLng = targetPos;

    if (rawClip.isNotEmpty) {
      activeSignalEnvelope = rawClip;
      activeSignalExpiresAt = now.add(const Duration(seconds: 30));
    } else if (activeSignalExpiresAt != null &&
        now.isAfter(activeSignalExpiresAt!)) {
      activeSignalEnvelope = '';
      activeSignalExpiresAt = null;
    }

    final routeB64 = _encodeMyCompactRouteMeta();
    final phoneTrimmed = myPhoneNumber.trim();
    final baseMeta = isBubblePrivacyActive
        ? 'BUBBLE::ON::$phoneTrimmed::ROUTE::$routeB64'
        : 'META::PHONE::$phoneTrimmed::ROUTE::$routeB64';

    final effectiveClip = rawClip.isNotEmpty
        ? '$rawClip::ROUTE::$routeB64'
        : (activeSignalEnvelope.isNotEmpty
              ? '$activeSignalEnvelope::ROUTE::$routeB64'
              : baseMeta);

    double sendLat = targetPos.latitude;
    double sendLng = targetPos.longitude;
    if (isBubblePrivacyActive && !isSos) {
      sendLat = double.parse(targetPos.latitude.toStringAsFixed(2));
      sendLng = double.parse(targetPos.longitude.toStringAsFixed(2));
    }

    final payloadPrimary = <String, dynamic>{
      'user_id': currentUserId,
      'circle_code': circleCode,
      'user_name': userName,
      'latitude': sendLat,
      'longitude': sendLng,
      'speed_kmh': speedKmh,
      'battery_level': targetBat,
      'is_sos': isSos,
      'audio_clip': effectiveClip,
      'updated_at': now.toIso8601String(),
    };
    if (myCustomAvatarDataUrl.isNotEmpty) {
      payloadPrimary['avatar_url'] = myCustomAvatarDataUrl;
    }

    try {
      await Supabase.instance.client.from('locations').upsert(payloadPrimary);
    } catch (_) {
      try {
        final payloadFallback = <String, dynamic>{
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
          payloadFallback['avatar_url'] = myCustomAvatarDataUrl;
        }
        await Supabase.instance.client
            .from('locations')
            .upsert(payloadFallback);
      } catch (_) {}
    }
  }

  Future<void> deleteMyServerDataAndReset() async {
    await deleteUserAccountAndData();
  }

  Future<void> deleteUserAccountAndData([
    List<CircleInfo>? joinedCircles,
  ]) async {
    if (!isSupabaseReady) return;
    try {
      if (currentUserId.isNotEmpty) {
        await Supabase.instance.client
            .from('locations')
            .delete()
            .eq('user_id', currentUserId);
      }
      for (final fName in [
        'pingo_saved_session_v1.json',
        'pingo_timeline_history_v3.json',
        'pingo_remote_timelines_v3.json',
      ]) {
        final f1 = _storageFile(fName);
        if (await f1.exists()) await f1.delete();
        final f2 = _fallbackTempFile(fName);
        if (await f2.exists()) await f2.delete();
      }
    } catch (_) {}
  }

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
            .map((c) => {'name': c.name, 'code': c.code, 'myRole': c.myRole})
            .toList(),
      };
      await _writePersistentText(
        'pingo_saved_session_v1.json',
        jsonEncode(data),
      );
    } catch (_) {}
  }

  Future<dynamic> loadLocalCirclesState() async {
    try {
      final raw = await _readPersistentText('pingo_saved_session_v1.json');
      if (raw.isEmpty) return null;
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
