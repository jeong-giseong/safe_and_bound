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
  final Map<String, LatLng> _lastGeocodedCoordByKey = {};
  final Map<String, DateTime> _lastGeocodedTimeByKey = {};
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
        'pingo_timeline_history_v3.json',
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

    final list = myDailyRoutes.putIfAbsent(tKey, () {
      final yList = myDailyRoutes[yesterdayKey];
      if (yList != null &&
          yList.isNotEmpty &&
          !isDummyOrInvalidPoint(yList.last)) {
        return <LatLng>[yList.last];
      }
      return <LatLng>[];
    });

    if (list.isEmpty) {
      list.add(point);
    } else {
      final dist = calculateDistanceMeters(list.last, point);
      if (dist >= 10.0 && dist <= 15000.0) {
        list.add(point);
      } else if (dist > 15000.0 && list.length <= 2) {
        list
          ..clear()
          ..add(point);
      }
      if (list.length > 1500) {
        final compacted = simplifyRouteRDP(
          list,
          epsilonDegrees: 0.00008,
          maxPoints: 1200,
        );
        list
          ..clear()
          ..addAll(compacted);
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
        'pingo_timeline_history_v3.json',
        jsonEncode(serialized),
      );
      await _writePersistentText(
        'pingo_timeline_maxspeed_v3.json',
        jsonEncode(myDailyMaxSpeed),
      );
    } catch (_) {}
    return List<LatLng>.from(list);
  }

  final Map<String, List<LatLng>> _snappedRoadCache = {};
  final Set<String> _pendingRoadSnapKeys = {};
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

    if ((memberId == 'm2' || memberId == 'm3') &&
        (sourceMap == null || sourceMap.isEmpty)) {
      final base = isDummyOrInvalidPoint(fallbackLoc)
          ? const LatLng(37.2636, 127.0286)
          : fallbackLoc;
      if (tabIndex == 0) {
        rawWaypoints = <LatLng>[
          LatLng(base.latitude - 0.0048, base.longitude - 0.0036),
          LatLng(base.latitude - 0.0022, base.longitude - 0.0029),
          LatLng(base.latitude - 0.0009, base.longitude - 0.0011),
          base,
        ];
      } else {
        rawWaypoints = <LatLng>[
          LatLng(base.latitude + 0.0052, base.longitude - 0.0038),
          LatLng(base.latitude + 0.0028, base.longitude - 0.0014),
          LatLng(base.latitude + 0.0012, base.longitude + 0.0019),
          base,
        ];
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

    if (rawWaypoints.length < 2) return rawWaypoints;

    final String cacheKey =
        '${memberId}_${tabIndex}_${customDateKey ?? ""}_${rawWaypoints.length}_${rawWaypoints.first.latitude.toStringAsFixed(4)}_${rawWaypoints.last.latitude.toStringAsFixed(4)}';

    if (_snappedRoadCache.containsKey(cacheKey)) {
      return _snappedRoadCache[cacheKey]!;
    }

    if (!_pendingRoadSnapKeys.contains(cacheKey)) {
      _pendingRoadSnapKeys.add(cacheKey);
      fetchRoadSnappedRoute(rawWaypoints).then((snapped) {
        if (snapped.length >= 2) {
          _snappedRoadCache[cacheKey] = snapped;
          onTimelineMetaUpdated?.call();
        }
      });
    }

    return rawWaypoints;
  }

  String resolvePlaceOrPoiName(
    LatLng point, {
    List<SafePlaceData>? safePlaces,
  }) {
    if (safePlaces != null) {
      for (final sp in safePlaces) {
        final d = calculateDistanceMeters(point, sp.point);
        if (d <= math.max(sp.radiusMeters, 120.0)) {
          return sp.name;
        }
      }
    }
    final key =
        '${point.latitude.toStringAsFixed(3)}_${point.longitude.toStringAsFixed(3)}';
    final cached = _roadAddressCache[key];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    if (!_pendingGeocodeKeys.contains(key)) {
      _pendingGeocodeKeys.add(key);
      _fetchPoiOrRoadNameInBackground(point, key);
    }
    return '${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}';
  }

  Future<void> _fetchPoiOrRoadNameInBackground(
    LatLng point,
    String cacheKey,
  ) async {
    const token =
        'pk.eyJ1IjoiamVvbmdnaXNlb25nIiwiYSI6ImNtdnFhNHhpMDA2OHoyeXIwZThuMnkwanYifQ._Zouj-a9d2NaLWCVyRKwiQ';
    final langCode = AppStrings.lang;
    final url = Uri.parse(
      'https://api.mapbox.com/geocoding/v5/mapbox.places/${point.longitude},${point.latitude}.json'
      '?types=poi,address,neighborhood,locality&language=$langCode&limit=1&access_token=$token',
    );
    try {
      final res = await http.get(url).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final features = data['features'] as List?;
        if (features != null && features.isNotEmpty) {
          final f = features.first;
          final placeText = (f['text'] ?? '').toString().trim();
          String contextStr = '';
          final ctxList = f['context'] as List?;
          if (ctxList != null && ctxList.isNotEmpty) {
            contextStr = (ctxList.first['text'] ?? '').toString().trim();
          }
          final label = (contextStr.isNotEmpty && contextStr != placeText)
              ? '$contextStr $placeText'
              : placeText;
          if (label.isNotEmpty) {
            _roadAddressCache[cacheKey] = label;
            onTimelineMetaUpdated?.call();
            return;
          }
        }
      }
    } catch (_) {}
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
            : (distKm * 6.5 + placesCnt * 4).round();
        result.add({
          'dateKey': k,
          'points': pts,
          'distanceKm': distKm,
          'placesCount': placesCnt,
          'minutes': mins,
        });
      }
    }

    if (result.isEmpty && (memberId == 'm2' || memberId == 'm3')) {
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
          'minutes': (distKm * 8).round().clamp(15, 240),
        });
      }
    }
    return result;
  }

  List buildDetailedTimelineSteps(
    List<LatLng> validRoute, {
    List<SafePlaceData>? safePlaces,
  }) {
    if (validRoute.isEmpty) return [];
    if (validRoute.length == 1) {
      final placeName = resolvePlaceOrPoiName(
        validRoute.first,
        safePlaces: safePlaces,
      );
      return [
        {
          'type': 'end',
          'point': validRoute.first,
          'placeName': placeName,
          'segmentKm': 0.0,
          'progressRatio': 1.0,
        },
      ];
    }

    // 1단계: 하루 외근/장거리 이동 시에도 실제 방문 거점이 누락되지 않도록 상한을 40곳으로 확장
    final rdpCandidates = simplifyRouteRDP(
      validRoute,
      epsilonDegrees: 0.00042,
      maxPoints: 40,
    );

    // 2단계: 단순 신호대기/골목 코너 중복을 걸러내는 160m 공간 클러스터링
    final keyNodes = [rdpCandidates.first];
    for (int i = 1; i < rdpCandidates.length - 1; i++) {
      final distFromPrev = calculateDistanceMeters(
        keyNodes.last,
        rdpCandidates[i],
      );
      final distToEnd = calculateDistanceMeters(
        rdpCandidates[i],
        rdpCandidates.last,
      );
      if (distFromPrev >= 160.0 && distToEnd >= 160.0) {
        keyNodes.add(rdpCandidates[i]);
      }
    }
    if (calculateDistanceMeters(keyNodes.last, rdpCandidates.last) >= 60.0 ||
        keyNodes.length == 1) {
      keyNodes.add(rdpCandidates.last);
    }

    // 3단계: 역지오코딩 주소 변환 + 직전 방문지와 주소/건물명이 동일하면 1곳으로 자동 병합(Merge)
    final mergedSteps = [];
    for (int i = 0; i < keyNodes.length; i++) {
      final pt = keyNodes[i];
      final placeName = resolvePlaceOrPoiName(pt, safePlaces: safePlaces);
      double segKm = 0.0;
      if (i > 0) {
        segKm = calculateDistanceMeters(keyNodes[i - 1], pt) / 1000.0;
      }

      final bool isCoordinateFallback =
          placeName.contains(',') &&
          RegExp(r'^\d+\.\d+').hasMatch(placeName.trim());

      if (mergedSteps.isNotEmpty &&
          !isCoordinateFallback &&
          mergedSteps.last['placeName'] == placeName) {
        mergedSteps.last['segmentKm'] =
            (mergedSteps.last['segmentKm'] as double) + segKm;
        mergedSteps.last['point'] = pt;
      } else {
        mergedSteps.add({
          'type': 'waypoint',
          'point': pt,
          'placeName': placeName,
          'segmentKm': segKm,
          'progressRatio': 0.0,
        });
      }
    }

    // 4단계: 시작점(start) / 경유점(waypoint) / 도착점(end) 타입 및 진행률 확정
    final int total = mergedSteps.length;
    for (int i = 0; i < total; i++) {
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
    if (!forceLookup && speedKmh >= 15.0) {
      return '🚗 ${AppStrings.t('filter_moving')} (${speedKmh.toStringAsFixed(0)} km/h)';
    }
    const lang = 'ko';
    final key =
        '${point.latitude.toStringAsFixed(3)}_${point.longitude.toStringAsFixed(3)}';
    if (_roadAddressCache.containsKey(key)) {
      return _roadAddressCache[key]!;
    }
    final lastCoord = _lastGeocodedCoordByKey[lang];
    final lastTime = _lastGeocodedTimeByKey[lang];
    if (!forceLookup && lastCoord != null && lastTime != null) {
      final movedMeters = calculateDistanceMeters(lastCoord, point);
      final elapsedSec = DateTime.now().difference(lastTime).inSeconds;
      if (movedMeters < 65.0 &&
          elapsedSec < 180 &&
          _roadAddressCache.isNotEmpty) {
        return _roadAddressCache.values.last;
      }
    }
    const token =
        'pk.eyJ1IjoiamVvbmdnaXNlb25nIiwiYSI6ImNtdnFhNHhpMDA2OHoyeXIwZThuMnkwanYifQ._Zouj-a9d2NaLWCVyRKwiQ';
    final url = Uri.parse(
      'https://api.mapbox.com/geocoding/v5/mapbox.places/${point.longitude},${point.latitude}.json'
      '?types=address,poi,neighborhood,locality,place&language=ko&limit=1&access_token=$token',
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
              : (f['place_name'] ?? placeText)
                    .toString()
                    .split(',')
                    .take(2)
                    .join(' ');
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
      if (myRecentRoute != null && myRecentRoute.isNotEmpty) {
        myDailyRoutes[todayKey] = List<LatLng>.from(myRecentRoute);
      }
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
