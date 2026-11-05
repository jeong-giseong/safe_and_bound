import 'dart:convert';
import 'dart:async';

import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import 'package:battery_plus/battery_plus.dart';

import '../core/app_theme_and_strings.dart';
import '../models/app_models.dart';
import '../services/app_engine_service.dart';
import 'safe_return_live_web_screen.dart';

class MainLife360MapScreen extends StatefulWidget {
  final String userName;
  final String? userAvatarUrl;
  final List<CircleInfo> initialCircles;

  const MainLife360MapScreen({
    super.key,
    required this.userName,
    this.userAvatarUrl,
    required this.initialCircles,
  });

  @override
  State<MainLife360MapScreen> createState() => _MainLife360MapScreenState();
}

class _MainLife360MapScreenState extends State<MainLife360MapScreen>
    with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  final Battery _battery = Battery();

  late AnimationController _pulseController;
  late List<CircleInfo> myCircles;
  int currentCircleIndex = 0;

  int _mapStyleIndex = 0;
  final List<IconData> _mapStyleIcons = const [
    Icons.wb_sunny_rounded,
    Icons.dark_mode_rounded,
    Icons.satellite_alt_rounded,
  ];

  bool _showDemoMembers = false;
  bool _hasShownLocationDisclosure = false;
  int _selectedHistoryDayTab = 0;
  bool _selectedYearlyPlan = true;

  String? selectedMemberId;
  bool isMySosActive = false;

  // 상대방 머리 위 말풍선 & 상단 인터랙티브 원탭 답장 다이내믹 배너 상태
  final Map<String, String> _activeMemberBubblePings = {};
  final Set<String> _blockedMemberIds = {};
  final Set<String> _insidePlaceIds = {};
  final Set<String> _otherBubbleMemberIds = {};
  final Map<String, ImageProvider> _avatarMemoryCache = {};

  String? _incomingBannerSenderId;
  String? _incomingBannerSenderName;
  String? _incomingBannerText;
  Timer? _incomingBannerTimer;
  bool isSyncingGps = false;
  bool isProUser = false;

  StreamSubscription<List<Map<String, dynamic>>>? _realtimeLocationSub;
  StreamSubscription<Position>? _myGpsPositionSub;

  bool isPickingPlaceOnMap = false;
  LatLng draftPlacePoint = const LatLng(37.7599, 126.7802);
  double draftPlaceRadius = 200.0;
  IconData draftPlaceIcon = Icons.school_rounded;
  late TextEditingController _placeNameController;

  late List<MemberData> _allMembers;
  late List<SafePlaceData> safePlaces;

  final Map<String, int> _memberLastSeenMs = {};
  final Map<String, String> _memberInsidePlaceMap = {};

  String _formatMemberElapsed(String uid) {
    if (uid == 'm1' || uid == 'm2' || uid == 'm3') {
      return AppStrings.t('just_now');
    }
    final ts = _memberLastSeenMs[uid];
    if (ts == null) return AppStrings.t('just_now');
    final diffMin = ((DateTime.now().millisecondsSinceEpoch - ts) / 60000)
        .floor();
    if (diffMin < 1) return AppStrings.t('just_now');
    if (diffMin < 60) return '$diffMin${AppStrings.t('stat_mins_unit')}';
    final h = diffMin ~/ 60;
    return '$h${AppStrings.t('stat_hours_unit')}';
  }

  Future<void> _broadcastMySafeCheckIn() async {
    HapticFeedback.mediumImpact();
    final me = _allMembers[0];
    final cleanAddr = me.statusText.split('\u2022').first.trim();
    final payload =
        'PING::\uD83D\uDCCD ${AppStrings.t('checkin_bubble')} ($cleanAddr)::${DateTime.now().millisecondsSinceEpoch}::${AppEngineService.instance.myPhoneNumber}';
    await AppEngineService.instance.pushLiveLocationToServer(
      circleCode: activeCircle.code,
      userName: me.name,
      point: me.location,
      battery: me.battery,
      avatarUrl: me.avatarUrl,
      audioClipDataUrl: payload,
      speedKmh: me.speedKmh,
      forceImmediate: true,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.primaryPurple,
        behavior: SnackBarBehavior.floating,
        content: Text(AppStrings.t('checkin_toast')),
      ),
    );
  }

  CircleInfo get activeCircle => myCircles[currentCircleIndex];

  List<MemberData> get visibleMembers {
    final isReviewerCircle = activeCircle.code == '999999';
    return _allMembers.where((m) {
      if (_blockedMemberIds.contains(m.id)) return false;
      if (!_showDemoMembers &&
          !isReviewerCircle &&
          (m.id == 'm2' || m.id == 'm3')) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _placeNameController = TextEditingController(
      text: AppStrings.t('default_school'),
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    myCircles = List.from(widget.initialCircles);
    AppEngineService.instance.onTimelineMetaUpdated = () {
      if (mounted) setState(() {});
    };

    final myMono = widget.userName.length >= 2
        ? widget.userName.substring(widget.userName.length - 2)
        : widget.userName;

    _allMembers = [
      MemberData(
        id: 'm1',
        name: widget.userName,
        monogram: myMono,
        avatarUrl: widget.userAvatarUrl ?? PingoAvatars.presets[0]['url']!,
        gradient: [const Color(0xFF6C47FF), const Color(0xFF9D7BFF)],
        statusIcon: Icons.home_rounded,
        statusText: AppStrings.t('syncing_address'),
        battery: 95,
        speedKmh: 0.0,
        location: const LatLng(37.7599, 126.7802),
        recentRoute: <LatLng>[],
      ),
      MemberData(
        id: 'm2',
        name: AppStrings.t('demo_member_1'),
        monogram: 'M1',
        avatarUrl: PingoAvatars.presets[4]['url']!,
        gradient: [const Color(0xFF0EA5E9), const Color(0xFF38BDF8)],
        statusIcon: Icons.directions_walk_rounded,
        statusText: AppStrings.t('syncing_address'),
        battery: 78,
        speedKmh: 4.5,
        location: const LatLng(37.7645, 126.7795),
        recentRoute: [const LatLng(37.7645, 126.7795)],
      ),
      MemberData(
        id: 'm3',
        name: AppStrings.t('demo_member_2'),
        monogram: 'M2',
        avatarUrl: PingoAvatars.presets[3]['url']!,
        gradient: [const Color(0xFFEC4899), const Color(0xFFF472B6)],
        statusIcon: Icons.directions_car_rounded,
        statusText: AppStrings.t('syncing_address'),
        battery: 64,
        speedKmh: 34.0,
        location: const LatLng(37.7565, 126.7865),
        recentRoute: [const LatLng(37.7565, 126.7865)],
      ),
    ];

    safePlaces = [];

    _readRealBattery();
    _readRealBattery();
    _subscribeToSupabaseRealtimeLocations();
    AppEngineService.instance.cleanupDuplicateGhostRows(
      circleCode: activeCircle.code,
      myUserName: widget.userName,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoCenterToMyRealLocationOnLaunch();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _sheetController.dispose();
    _incomingBannerTimer?.cancel();
    _realtimeLocationSub?.cancel();
    _myGpsPositionSub?.cancel();
    _placeNameController.dispose();
    super.dispose();
  }

  Future<void> _autoCenterToMyRealLocationOnLaunch() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse) {
        _hasShownLocationDisclosure = true;
        await _syncMyRealGpsLocation();
        _startRealGpsPositionStream();
      } else {
        await _initRealRoadAddressesAndRoutes();
        if (!mounted) return;
        await _syncMyRealGpsLocationWithDisclosure();
        _startRealGpsPositionStream();
      }
    } catch (_) {
      await _initRealRoadAddressesAndRoutes();
    }
  }

  Widget _buildSmartMotionBadge(MemberData m) {
    final spd = m.speedKmh;
    late Color bgColor;
    late Color textColor;
    late String label;

    if (spd >= 15.0) {
      bgColor = AppColors.driveBlueBg;
      textColor = AppColors.driveBlueText;
      label = '🚗 ${spd.round()}km/h';
    } else if (spd >= 2.0) {
      bgColor = AppColors.safeGreenBg;
      textColor = AppColors.safeGreenText;
      label = AppStrings.t('status_walking');
    } else {
      bgColor = AppColors.lightPurpleBg;
      textColor = AppColors.primaryPurple;
      label = AppStrings.t('status_staying');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: textColor,
        ),
      ),
    );
  }

  void _toggleBottomSheetSnap() {
    if (!_sheetController.isAttached) return;
    final currentSize = _sheetController.size;
    final targetSize = currentSize > 0.25 ? 0.14 : 0.34;
    _sheetController.animateTo(
      targetSize,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggleDemoFamilyMode() {
    HapticFeedback.selectionClick();
    final myPos = _allMembers[0].location;
    setState(() {
      _showDemoMembers = !_showDemoMembers;
      if (_showDemoMembers && _allMembers.length >= 3) {
        _allMembers[1].location = LatLng(
          myPos.latitude + 0.0032,
          myPos.longitude - 0.0021,
        );
        _allMembers[1].recentRoute = [_allMembers[1].location];
        _allMembers[2].location = LatLng(
          myPos.latitude - 0.0028,
          myPos.longitude + 0.0035,
        );
        _allMembers[2].recentRoute = [_allMembers[2].location];
      }
      if (!_showDemoMembers &&
          (selectedMemberId == 'm2' || selectedMemberId == 'm3')) {
        selectedMemberId = null;
      }
    });
    if (_showDemoMembers) {
      _initRealRoadAddressesAndRoutes();
      _mapController.move(myPos, 14.8);
    }
  }

  Widget _buildMemberAvatarImage(MemberData m, {double size = 46}) {
    final url =
        (m.avatarUrl.startsWith('http') || m.avatarUrl.startsWith('data:image'))
        ? m.avatarUrl
        : PingoAvatars.presets[0]['url']!;
    if (url.startsWith('data:image')) {
      try {
        ImageProvider? provider = _avatarMemoryCache[url];
        if (provider == null) {
          final comma = url.indexOf(',');
          final bytes = base64Decode(url.substring(comma + 1));
          provider = MemoryImage(bytes);
          _avatarMemoryCache[url] = provider;
        }
        return ClipOval(
          child: Image(
            image: provider,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        );
      } catch (_) {}
    }
    return ClipOval(
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: size,
          height: size,
          color: AppColors.primaryPurple,
          alignment: Alignment.center,
          child: Text(
            m.monogram,
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: size * 0.36,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _initRealRoadAddressesAndRoutes() async {
    for (int i = 0; i < _allMembers.length; i++) {
      final addr = await AppEngineService.instance.fetchRoadAddress(
        _allMembers[i].location,
      );
      if (!mounted) return;
      setState(() {
        _allMembers[i].statusText = '$addr • ${AppStrings.t('just_now')}';
        if (i == 0) {
          final savedToday = AppEngineService.instance.getRouteForMemberTab(
            'm1',
            0,
            _allMembers[0].location,
          );
          _allMembers[0].recentRoute = savedToday.isNotEmpty
              ? savedToday
              : [_allMembers[0].location];
        } else if (_allMembers[i].recentRoute.isEmpty) {
          _allMembers[i].recentRoute = [_allMembers[i].location];
        }
      });
    }
  }

  Future<void> _startRealGpsPositionStream() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) return;

      _myGpsPositionSub?.cancel();
      _myGpsPositionSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 8,
            ),
          ).listen((pos) async {
            final newLatLng = LatLng(pos.latitude, pos.longitude);
            final addr = await AppEngineService.instance.fetchRoadAddress(
              newLatLng,
            );
            final rawSpeed = pos.speed.isNaN || pos.speed < 0 ? 0.0 : pos.speed;
            final speedKmh = (rawSpeed * 3.6).clamp(0.0, 200.0);

            if (!mounted) return;
            setState(() {
              _allMembers[0].location = newLatLng;
              _allMembers[0].speedKmh = speedKmh;
              _allMembers[0].statusIcon = speedKmh >= 15.0
                  ? Icons.directions_car_rounded
                  : (speedKmh >= 2.0
                        ? Icons.directions_walk_rounded
                        : Icons.home_rounded);
              _allMembers[0].statusText = '$addr • ${AppStrings.t('just_now')}';
              _allMembers[0].recentRoute = [
                ..._allMembers[0].recentRoute,
                newLatLng,
              ];
            });

            // 자동 장소 알림 (Place Alerts / Geofencing: 진입 150m / 이탈 +30m 완충)
            for (final place in safePlaces) {
              final dist = AppEngineService.instance.calculateDistanceMeters(
                newLatLng,
                place.point,
              );
              final wasInside = _insidePlaceIds.contains(place.id);
              if (dist <= place.radiusMeters && !wasInside) {
                _insidePlaceIds.add(place.id);
                final alertText = AppStrings.t('place_arrived_alert')
                    .replaceAll('{PLACE}', place.name);
                setState(() {
                  _allMembers[0].statusIcon = place.iconData;
                  _allMembers[0].statusText =
                      '$addr • ${place.name} (${AppStrings.t('inside_safe_zone')})';
                  _activeMemberBubblePings['m1'] = alertText;
                });
                await AppEngineService.instance.pushLiveLocationToServer(
                  circleCode: activeCircle.code,
                  userName: _allMembers[0].name,
                  point: newLatLng,
                  battery: _allMembers[0].battery,
                  avatarUrl: _allMembers[0].avatarUrl,
                  audioClipDataUrl:
                      'PLACE::$alertText::${DateTime.now().millisecondsSinceEpoch}',
                  speedKmh: speedKmh,
                );
              } else if (dist > place.radiusMeters + 30.0 && wasInside) {
                _insidePlaceIds.remove(place.id);
                final leftText = AppStrings.t('place_left_alert')
                    .replaceAll('{PLACE}', place.name);
                setState(() {
                  _activeMemberBubblePings['m1'] = leftText;
                });
                await AppEngineService.instance.pushLiveLocationToServer(
                  circleCode: activeCircle.code,
                  userName: _allMembers[0].name,
                  point: newLatLng,
                  battery: _allMembers[0].battery,
                  avatarUrl: _allMembers[0].avatarUrl,
                  audioClipDataUrl:
                      'PLACE::$leftText::${DateTime.now().millisecondsSinceEpoch}',
                  speedKmh: speedKmh,
                );
              }
            }

            await AppEngineService.instance.pushLiveLocationToServer(
              circleCode: activeCircle.code,
              userName: _allMembers[0].name,
              point: newLatLng,
              battery: _allMembers[0].battery,
              avatarUrl: _allMembers[0].avatarUrl,
              speedKmh: speedKmh,
              isSos: isMySosActive,
            );
          });
    } catch (_) {}
  }

  final Map<String, String> _lastProcessedIncomingSignal = {};

  String _resolveIncomingSignalText(String rawKeyOrText) {
    if (rawKeyOrText.startsWith('q_')) {
      return AppStrings.t(rawKeyOrText);
    }
    return rawKeyOrText;
  }

  void _triggerIncomingDynamicBanner({
    required String senderId,
    required String senderName,
    required String messageText,
  }) {
    HapticFeedback.heavyImpact();
    _incomingBannerTimer?.cancel();
    setState(() {
      _activeMemberBubblePings[senderId] = messageText;
      _incomingBannerSenderId = senderId;
      _incomingBannerSenderName = senderName;
      _incomingBannerText = messageText;
    });
    _incomingBannerTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted) return;
      setState(() {
        _activeMemberBubblePings.remove(senderId);
        if (_incomingBannerSenderId == senderId) {
          _incomingBannerSenderId = null;
        }
      });
    });
  }

  void _syncMySafePlacesToEngine({bool broadcastNow = false}) {
    AppEngineService.instance.sharedPlacesPayload = safePlaces
        .map(
          (p) => {
            'id': p.id,
            'n': p.name,
            'lat': double.parse(p.point.latitude.toStringAsFixed(5)),
            'lng': double.parse(p.point.longitude.toStringAsFixed(5)),
            'r': p.radiusMeters.round(),
          },
        )
        .toList();
    if (broadcastNow && _allMembers.isNotEmpty) {
      AppEngineService.instance.pushLiveLocationToServer(
        circleCode: activeCircle.code,
        userName: _allMembers[0].name,
        point: _allMembers[0].location,
        battery: _allMembers[0].battery,
        avatarUrl: _allMembers[0].avatarUrl,
        speedKmh: _allMembers[0].speedKmh,
        forceImmediate: true,
      );
    }
  }

  void _subscribeToSupabaseRealtimeLocations() {
    _syncMySafePlacesToEngine();
    AppEngineService.instance.onRemotePlacesSynced = (remoteList) {
      if (!mounted) return;
      bool changed = false;
      for (final rp in remoteList) {
        final rName = (rp['n'] ?? '').toString().trim();
        final rLat = (rp['lat'] as num?)?.toDouble();
        final rLng = (rp['lng'] as num?)?.toDouble();
        final rRad = (rp['r'] as num?)?.toDouble() ?? 150.0;
        if (rName.isEmpty || rLat == null || rLng == null) continue;
        final exists = safePlaces.any(
          (sp) =>
              sp.name == rName ||
              AppEngineService.instance.calculateDistanceMeters(
                    sp.point,
                    LatLng(rLat, rLng),
                  ) <
                  35.0,
        );
        if (!exists) {
          safePlaces.add(
            SafePlaceData(
              id: (rp['id'] ?? DateTime.now().millisecondsSinceEpoch)
                  .toString(),
              name: rName,
              point: LatLng(rLat, rLng),
              radiusMeters: rRad,
              iconData: Icons.verified_user_rounded,
            ),
          );
          changed = true;
        }
      }
      if (changed && mounted) setState(() {});
    };
    try {
      _realtimeLocationSub?.cancel();
      // 방 입장 직후 내 현재 위치를 즉시 1회 강제 발송하여 상대방 화면에 나를 즉시 생성
      if (_allMembers.isNotEmpty) {
        AppEngineService.instance.pushLiveLocationToServer(
          circleCode: activeCircle.code,
          userName: _allMembers[0].name,
          point: _allMembers[0].location,
          battery: _allMembers[0].battery,
          avatarUrl: _allMembers[0].avatarUrl,
          speedKmh: _allMembers[0].speedKmh,
          forceImmediate: true,
        );
      }
      _realtimeLocationSub = Supabase.instance.client
          .from('locations')
          .stream(primaryKey: ['user_id'])
          .listen((rows) {
            if (!mounted || rows.isEmpty) return;
            for (final row in rows) {
              final uid = row['user_id']?.toString();
              final uName =
                  row['user_name']?.toString() ??
                  AppStrings.t('default_member_name');

              // 오직 기기 고유 ID(currentUserId)가 나 자신일 때만 스킵 (동명이인/기본이름 차단 버그 제거)
              if (uid == null ||
                  uid == AppEngineService.instance.currentUserId ||
                  uid ==
                      AppEngineService.instance.buildCircleScopedUserId(
                        activeCircle.code,
                      )) {
                continue;
              }
              if (_blockedMemberIds.contains(uid)) continue;

              final rowCircle = row['circle_code']?.toString();
              if (rowCircle != null &&
                  rowCircle.isNotEmpty &&
                  rowCircle != activeCircle.code) {
                continue;
              }

              // latitude/longitude 와 lat/lng 컬럼 모두 100% 호환 파싱
              final lat = ((row['latitude'] ?? row['lat']) as num?)?.toDouble();
              final lng = ((row['longitude'] ?? row['lng']) as num?)
                  ?.toDouble();
              final bat = (row['battery_level'] as num?)?.toInt() ?? 88;
              final spd = (row['speed_kmh'] as num?)?.toDouble() ?? 0.0;
              final isRowSos = row['is_sos'] == true;
              final uAvatar =
                  row['avatar_url']?.toString() ??
                  PingoAvatars.presets[1]['url']!;
              final rawSignal = row['audio_clip']?.toString() ?? '';

              if (lat == null || lng == null) continue;
              final newPoint = LatLng(lat, lng);
              _memberLastSeenMs[uid] = DateTime.now().millisecondsSinceEpoch;
              if (_showDemoMembers) {
                _showDemoMembers = false;
              }
              for (final sp in safePlaces) {
                final dMeters = AppEngineService.instance
                    .calculateDistanceMeters(newPoint, sp.point);
                final prevPlaceId = _memberInsidePlaceMap[uid];
                if (dMeters <= sp.radiusMeters && prevPlaceId != sp.id) {
                  _memberInsidePlaceMap[uid] = sp.id;
                  _triggerIncomingDynamicBanner(
                    senderId: uid,
                    senderName: uName,
                    messageText: AppStrings.t('place_arrived_alert')
                        .replaceAll('{PLACE}', sp.name),
                  );
                } else if (dMeters > sp.radiusMeters + 25.0 &&
                    prevPlaceId == sp.id) {
                  _memberInsidePlaceMap.remove(uid);
                  _triggerIncomingDynamicBanner(
                    senderId: uid,
                    senderName: uName,
                    messageText: AppStrings.t('place_left_alert')
                        .replaceAll('{PLACE}', sp.name),
                  );
                }
              }

              // 패킷 내 압축된 상대방 타임라인(::ROUTE::<b64>) 분리 추출 및 캐싱
              String incomingSignal = rawSignal;
              String encodedRouteB64 = '';
              if (rawSignal.contains('::ROUTE::')) {
                final rSplit = rawSignal.split('::ROUTE::');
                incomingSignal = rSplit.first;
                encodedRouteB64 = rSplit.last.trim();
              }
              AppEngineService.instance.decodeAndStoreRemoteMemberRoute(
                uid,
                encodedRouteB64,
                newPoint,
                spd,
              );

              final bool isRemoteBubble = incomingSignal.startsWith(
                'BUBBLE::ON',
              );
              if (isRemoteBubble) {
                _otherBubbleMemberIds.add(uid);
                final bParts = incomingSignal.split('::');
                if (bParts.length >= 3 &&
                    bParts[2] != '0' &&
                    bParts[2].isNotEmpty) {
                  AppEngineService.instance.memberPhones[uid] = bParts[2];
                }
              } else {
                _otherBubbleMemberIds.remove(uid);
                if (incomingSignal.startsWith('META::PHONE::')) {
                  final ph = incomingSignal
                      .replaceFirst('META::PHONE::', '')
                      .trim();
                  if (ph.isNotEmpty) {
                    AppEngineService.instance.memberPhones[uid] = ph;
                  }
                }
              }

              final syncedTodayRoute = AppEngineService.instance
                  .getRouteForMemberTab(uid, 0, newPoint);

              bool isNewlyDiscoveredMember = false;
              setState(() {
                final existIdx = _allMembers.indexWhere((m) => m.id == uid);
                if (existIdx != -1) {
                  _allMembers[existIdx].name = uName;
                  _allMembers[existIdx].location = newPoint;
                  _allMembers[existIdx].battery = bat;
                  _allMembers[existIdx].speedKmh = spd;
                  _allMembers[existIdx].avatarUrl = uAvatar;
                  _allMembers[existIdx].recentRoute = syncedTodayRoute;
                  if (isRemoteBubble) {
                    _allMembers[existIdx].statusText = AppStrings.t(
                      'bubble_masked_addr',
                    );
                  }
                } else {
                  isNewlyDiscoveredMember = true;
                  _allMembers.add(
                    MemberData(
                      id: uid,
                      name: uName,
                      monogram: uName.length >= 2
                          ? uName.substring(uName.length - 2)
                          : uName,
                      avatarUrl: uAvatar,
                      gradient: [
                        const Color(0xFF10B981),
                        const Color(0xFF34D399),
                      ],
                      statusIcon: spd >= 15
                          ? Icons.directions_car_rounded
                          : Icons.person_pin_circle_rounded,
                      statusText: isRemoteBubble
                          ? AppStrings.t('bubble_masked_addr')
                          : AppStrings.t('just_now'),
                      battery: bat,
                      speedKmh: spd,
                      location: newPoint,
                      recentRoute: syncedTodayRoute,
                    ),
                  );
                  if (!isRemoteBubble) {
                    AppEngineService.instance.fetchRoadAddress(newPoint).then((
                      resolvedAddr,
                    ) {
                      if (!mounted) return;
                      final idx = _allMembers.indexWhere((m) => m.id == uid);
                      if (idx != -1 && !_otherBubbleMemberIds.contains(uid)) {
                        setState(() {
                          _allMembers[idx].statusText =
                              '$resolvedAddr • ${AppStrings.t('just_now')}';
                        });
                      }
                    });
                  }
                }
              });

              // 새 가족이 내 화면에 처음 추가된 순간, 내 위치도 즉시 강제 답장(Sync-Ack)하여 상대방 폰에도 나를 즉시 생성!
              if (isNewlyDiscoveredMember && _allMembers.isNotEmpty) {
                AppEngineService.instance.pushLiveLocationToServer(
                  circleCode: activeCircle.code,
                  userName: _allMembers[0].name,
                  point: _allMembers[0].location,
                  battery: _allMembers[0].battery,
                  avatarUrl: _allMembers[0].avatarUrl,
                  speedKmh: _allMembers[0].speedKmh,
                  forceImmediate: true,
                );
              }

              if (isRowSos &&
                  _lastProcessedIncomingSignal['SOS_$uid'] != 'ACTIVE') {
                _lastProcessedIncomingSignal['SOS_$uid'] = 'ACTIVE';
                _mapController.move(newPoint, 16.0);
                _triggerIncomingDynamicBanner(
                  senderId: uid,
                  senderName: uName,
                  messageText: '🚨 SOS! ${AppStrings.t('sos_active_banner')}',
                );
              } else if (!isRowSos) {
                _lastProcessedIncomingSignal.remove('SOS_$uid');
              }

              if (incomingSignal.isNotEmpty &&
                  !incomingSignal.startsWith('BUBBLE::') &&
                  !incomingSignal.startsWith('META::') &&
                  _lastProcessedIncomingSignal[uid] != incomingSignal) {
                _lastProcessedIncomingSignal[uid] = incomingSignal;

                final parts = incomingSignal.split('::');
                if (parts.length >= 2) {
                  final rawMsg = parts[1];
                  final ts = parts.length >= 3 ? int.tryParse(parts[2]) : null;
                  final nowMs = DateTime.now().millisecondsSinceEpoch;
                  if (ts == null || (nowMs - ts).abs() <= 35000) {
                    if (parts.length >= 4 && parts[3].isNotEmpty) {
                      AppEngineService.instance.memberPhones[uid] = parts[3];
                    }
                    final displayMsg = _resolveIncomingSignalText(rawMsg);
                    if (displayMsg.isNotEmpty) {
                      _triggerIncomingDynamicBanner(
                        senderId: uid,
                        senderName: uName,
                        messageText: displayMsg,
                      );
                    }
                  }
                }
              }
            }
          });
    } catch (_) {}
  }

  // 파스텔 그라데이션 이모지 퀵 노트 전송 + 데모 모드일 때 2초 뒤 상대방 자동 답장 시뮬레이션!
  Future<void> _sendQuickPingToMember(
    MemberData target,
    String pingKeyOrText,
  ) async {
    HapticFeedback.mediumImpact();
    final displayText = _resolveIncomingSignalText(pingKeyOrText);
    setState(() {
      _activeMemberBubblePings[target.id] = displayText;
    });
    _mapController.move(target.location, 15.3);

    final pingPayload =
        'PING::$pingKeyOrText::${DateTime.now().millisecondsSinceEpoch}::${AppEngineService.instance.myPhoneNumber}';
    await AppEngineService.instance.pushLiveLocationToServer(
      circleCode: activeCircle.code,
      userName: _allMembers[0].name,
      point: _allMembers[0].location,
      battery: _allMembers[0].battery,
      avatarUrl: _allMembers[0].avatarUrl,
      audioClipDataUrl: pingPayload,
      speedKmh: _allMembers[0].speedKmh,
      isSos: isMySosActive,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.primaryPurple,
        behavior: SnackBarBehavior.floating,
        content: Text('✨ ${target.name} ➔ $displayText'),
        duration: const Duration(seconds: 2),
      ),
    );

    // [스마트 데모 에코 시뮬레이터]: 샘플 캐릭터(m2, m3)에게 보내면 2초 뒤 나에게 이모지 답장을 자동으로 쏴줌!
    if (target.id == 'm2' || target.id == 'm3') {
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted) return;
        final autoReplyKey = pingKeyOrText == 'q_where'
            ? 'q_otw'
            : (pingKeyOrText == 'q_love' ? 'q_love' : 'q_home');
        _triggerIncomingDynamicBanner(
          senderId: target.id,
          senderName: target.name,
          messageText: AppStrings.t(autoReplyKey),
        );
      });
    } else {
      Future.delayed(const Duration(seconds: 6), () {
        if (mounted) {
          setState(() => _activeMemberBubblePings.remove(target.id));
        }
      });
    }
  }

  // 상대방에게 전화 걸기 또는 문자 보내기 (번호 미등록 시 1회 미니 입력 모달 자동 연결)
  Future<void> _handleMemberPhoneAction({
    required MemberData member,
    required bool isCall,
  }) async {
    HapticFeedback.selectionClick();
    final savedPhone = AppEngineService.instance.memberPhones[member.id] ?? '';
    if (savedPhone.isNotEmpty) {
      if (isCall) {
        await AppEngineService.launchNativePhoneCall(savedPhone);
      } else {
        await AppEngineService.launchNativeSms(
          phone: savedPhone,
          bodyText: '[Pingo] ${member.name}, ${AppStrings.t('q_where')}',
        );
      }
      return;
    }

    final phoneCtrl = TextEditingController();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.cardWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 22,
          right: 22,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isCall ? Icons.call_rounded : Icons.sms_rounded,
                  color: AppColors.primaryPurple,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${member.name} • ${AppStrings.t('phone_input_title')}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              autofocus: true,
              decoration: InputDecoration(
                hintText: AppStrings.t('phone_input_hint'),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryPurple,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: () async {
                  final input = phoneCtrl.text.trim();
                  Navigator.pop(ctx);
                  if (input.isNotEmpty) {
                    await AppEngineService.instance.savePhoneForMember(
                      member.id,
                      input,
                    );
                    if (isCall) {
                      await AppEngineService.launchNativePhoneCall(input);
                    } else {
                      await AppEngineService.launchNativeSms(
                        phone: input,
                        bodyText:
                            '[Pingo] ${member.name}, ${AppStrings.t('q_where')}',
                      );
                    }
                  } else if (!isCall) {
                    await AppEngineService.launchNativeSms(
                      bodyText:
                          '[Pingo] ${member.name}, ${AppStrings.t('q_where')}',
                    );
                  }
                },
                icon: Icon(isCall ? Icons.call_rounded : Icons.send_rounded),
                label: Text(
                  AppStrings.t('phone_save_call'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLife360SilentSosModal() {
    HapticFeedback.heavyImpact();
    // 이미 SOS가 켜져 있다면 즉시 SOS 해제!
    if (isMySosActive) {
      setState(() {
        isMySosActive = false;
        _activeMemberBubblePings.remove('m1');
      });
      AppEngineService.instance.pushLiveLocationToServer(
        circleCode: activeCircle.code,
        userName: _allMembers[0].name,
        point: _allMembers[0].location,
        battery: _allMembers[0].battery,
        avatarUrl: _allMembers[0].avatarUrl,
        isSos: false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.safeGreenText,
          content: Text(AppStrings.t('sos_cleared_toast')),
        ),
      );
      return;
    }

    int secondsLeft = 5;
    Timer? sosTimer;
    final TextEditingController pinCtrl = TextEditingController();

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            sosTimer ??= Timer.periodic(const Duration(seconds: 1), (t) async {
              if (secondsLeft <= 1) {
                t.cancel();
                if (Navigator.canPop(ctx)) Navigator.pop(ctx);

                setState(() {
                  isMySosActive = true;
                  AppEngineService.instance.isBubblePrivacyActive = false;
                  _activeMemberBubblePings['m1'] = '🚨 SOS';
                });

                await AppEngineService.instance.pushLiveLocationToServer(
                  circleCode: activeCircle.code,
                  userName: _allMembers[0].name,
                  point: _allMembers[0].location,
                  battery: _allMembers[0].battery,
                  avatarUrl: _allMembers[0].avatarUrl,
                  audioClipDataUrl:
                      'PING::🚨 SOS!::${DateTime.now().millisecondsSinceEpoch}::${AppEngineService.instance.myPhoneNumber}',
                  isSos: true,
                );

                if (!mounted) return;
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(
                    backgroundColor: Colors.redAccent,
                    duration: const Duration(seconds: 4),
                    content: Text(AppStrings.t('sos_sent_toast')),
                  ),
                );
              } else {
                setModalState(() => secondsLeft--);
              }
            });

            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 26,
                bottom: MediaQuery.of(context).viewInsets.bottom + 26,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      AppStrings.t('sos_silent_badge'),
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.redAccent, width: 3),
                    ),
                    child: Center(
                      child: Text(
                        '$secondsLeft',
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          color: Colors.redAccent,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    AppStrings.t('sos_waiting'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    AppStrings.t('sos_desc'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: pinCtrl,
                    onChanged: (v) {
                      if (v.trim().length >= 4) {
                        Navigator.pop(ctx);
                      }
                    },
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      letterSpacing: 8,
                      fontWeight: FontWeight.bold,
                    ),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: AppStrings.t('sos_pin_hint'),
                      hintStyle: const TextStyle(
                        color: Colors.white38,
                        fontSize: 13,
                        letterSpacing: 0,
                      ),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.08),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: AppColors.textDark,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                      ),
                      onPressed: () {
                        sosTimer?.cancel();
                        Navigator.pop(ctx);
                      },
                      child: Text(
                        AppStrings.t('sos_cancel'),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ).whenComplete(() => sosTimer?.cancel());
  }

  Future<void> _sendOneTapCheckIn() async {
    HapticFeedback.mediumImpact();
    // 체크인 시 버블 모드가 켜져 있다면 즉시 해제하고 실제 도로명 주소와 함께 서클 전체에 발송!
    final cleanAddr = _allMembers[0].statusText.split('•').first.trim();
    final checkInMsg = '📍 ${AppStrings.t('checkin_bubble')} ($cleanAddr)';
    setState(() {
      AppEngineService.instance.isBubblePrivacyActive = false;
      _activeMemberBubblePings['m1'] = checkInMsg;
    });
    await AppEngineService.instance.pushLiveLocationToServer(
      circleCode: activeCircle.code,
      userName: _allMembers[0].name,
      point: _allMembers[0].location,
      battery: _allMembers[0].battery,
      avatarUrl: _allMembers[0].avatarUrl,
      audioClipDataUrl:
          'CHECKIN::$checkInMsg::${DateTime.now().millisecondsSinceEpoch}::${AppEngineService.instance.myPhoneNumber}',
      speedKmh: _allMembers[0].speedKmh,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppColors.primaryPurple,
        content: Text('📍 ${AppStrings.t('checkin_toast')} ($cleanAddr)'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _readRealBattery() async {
    try {
      final level = await _battery.batteryLevel;
      if (mounted && level > 0) {
        setState(() => _allMembers[0].battery = level);
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // [분리 1] 상단 좌측 사람 아이콘 클릭 시: 내 프로필(캐릭터/이름) 및 통화연결용 전화번호 설정 모달
  // ---------------------------------------------------------------------------
  void _showMyProfileAndPhoneModal() {
    final TextEditingController nameCtrl = TextEditingController(
      text: _allMembers[0].name,
    );
    final TextEditingController phoneCtrl = TextEditingController(
      text: AppEngineService.instance.myPhoneNumber,
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  16,
                  20,
                  MediaQuery.of(ctx).viewInsets.bottom + 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          AppStrings.t('edit_my_profile'),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textDark,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(
                            Icons.close_rounded,
                            color: AppColors.textGray,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        GestureDetector(
                          onTap: () async {
                            final String? pickedUrl =
                                await AppEngineService.showAvatarAndPhotoPickerModal(
                                  context: ctx,
                                  currentAvatarUrl: _allMembers[0].avatarUrl,
                                );
                            if (pickedUrl != null && mounted) {
                              setState(
                                () => _allMembers[0].avatarUrl = pickedUrl,
                              );
                              setModalState(() {});
                            }
                          },
                          child: Stack(
                            alignment: Alignment.bottomRight,
                            children: [
                              Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppColors.primaryPurple,
                                    width: 2.5,
                                  ),
                                ),
                                child: _buildMemberAvatarImage(
                                  _allMembers[0],
                                  size: 60,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                  color: AppColors.primaryPurple,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.camera_alt_rounded,
                                  size: 12,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: TextField(
                            controller: nameCtrl,
                            decoration: InputDecoration(
                              labelText: AppStrings.t('nickname_hint'),
                              filled: true,
                              fillColor: const Color(0xFFF8FAFC),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: phoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(
                          Icons.phone_iphone_rounded,
                          color: AppColors.primaryPurple,
                        ),
                        hintText: AppStrings.t('my_phone_hint'),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryPurple,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: () {
                          final String newName = nameCtrl.text.trim();
                          final String newPhone = phoneCtrl.text.trim();
                          setState(() {
                            if (newName.isNotEmpty) {
                              _allMembers[0].name = newName;
                            }
                            AppEngineService.instance.myPhoneNumber = newPhone;
                          });
                          Navigator.pop(ctx);
                        },
                        child: Text(
                          AppStrings.t('save_phone_btn'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showMultiCircleSwitcherSheet() {
    final String rawCode = activeCircle.code;
    final String formattedCode = rawCode.length == 6
        ? '${rawCode.substring(0, 3)} ${rawCode.substring(3)}'
        : rawCode;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  22,
                  12,
                  22,
                  MediaQuery.of(ctx).viewInsets.bottom + 20,
                ),
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
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          AppStrings.t('invite_circle_member_title'),
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textDark,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(
                            Icons.close_rounded,
                            color: AppColors.textGray,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F3FF),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              formattedCode,
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 2.0,
                                color: AppColors.primaryPurple,
                              ),
                            ),
                          ),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFEDE9FE),
                              foregroundColor: AppColors.primaryPurple,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: activeCircle.code),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    AppStrings.t('code_copied_msg'),
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: Text(
                              AppStrings.t('copy_btn'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryPurple,
                          foregroundColor: Colors.white,
                          elevation: 2,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          SharePlus.instance.share(
                            ShareParams(
                              text:
                                  '[Pingo] ${activeCircle.name} Code: ${activeCircle.code}',
                            ),
                          );
                        },
                        child: Text(
                          AppStrings.t('share_invite_link_btn'),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Divider(color: Color(0xFFE2E8F0), height: 1),
                    const SizedBox(height: 14),
                    Text(
                      AppStrings.t('switch_or_create_circle'),
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textGray,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...List.generate(myCircles.length, (idx) {
                      final c = myCircles[idx];
                      final bool isCurrent = idx == currentCircleIndex;
                      return InkWell(
                        onTap: () {
                          setState(() => currentCircleIndex = idx);
                          _subscribeToSupabaseRealtimeLocations();
                          Navigator.pop(ctx);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10.0),
                          child: Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: isCurrent
                                      ? AppColors.lightPurpleBg
                                      : const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  idx == 0
                                      ? Icons.home_rounded
                                      : Icons.favorite_border_rounded,
                                  color: isCurrent
                                      ? AppColors.primaryPurple
                                      : AppColors.textGray,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  c.name,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: isCurrent
                                        ? FontWeight.w900
                                        : FontWeight.w700,
                                    color: AppColors.textDark,
                                  ),
                                ),
                              ),
                              if (isCurrent)
                                const Icon(
                                  Icons.check_circle_rounded,
                                  color: AppColors.primaryPurple,
                                  size: 18,
                                )
                              else
                                const Icon(
                                  Icons.chevron_right_rounded,
                                  color: AppColors.textGray,
                                  size: 20,
                                ),
                            ],
                          ),
                        ),
                      );
                    }),
                    const Divider(color: Color(0xFFE2E8F0), height: 12),
                    InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _showJoinOrCreateCircleDialog();
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10.0),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.add_rounded,
                              color: AppColors.primaryPurple,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                AppStrings.t('join_or_create_circle_action'),
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.primaryPurple,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                Navigator.pop(ctx);
                                _showMyProfileAndPhoneModal();
                              },
                              child: Text(
                                AppStrings.t('edit_my_profile'),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textGray,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showJoinOrCreateCircleDialog() {
    final TextEditingController codeCtrl = TextEditingController();
    final TextEditingController nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (dCtx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          title: Text(
            AppStrings.t('switch_or_create_circle'),
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: codeCtrl,
                maxLength: 6,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: AppStrings.t('join_circle_hint'),
                  counterText: '',
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryPurple,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    final String c = codeCtrl.text.trim();
                    if (c.length == 6) {
                      setState(() {
                        myCircles.add(
                          CircleInfo(
                            name: 'Circle $c',
                            code: c,
                            myRole: 'member',
                          ),
                        );
                        currentCircleIndex = myCircles.length - 1;
                      });
                      _subscribeToSupabaseRealtimeLocations();
                      Navigator.pop(dCtx);
                    }
                  },
                  child: Text(AppStrings.t('join_btn')),
                ),
              ),
              const Divider(height: 24),
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  hintText: AppStrings.t('new_circle_hint'),
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    final String n = nameCtrl.text.trim();
                    if (n.isNotEmpty) {
                      final String newCode =
                          AppEngineService.generateRandomInviteCode();
                      setState(() {
                        myCircles.add(
                          CircleInfo(name: n, code: newCode, myRole: 'admin'),
                        );
                        currentCircleIndex = myCircles.length - 1;
                      });
                      _subscribeToSupabaseRealtimeLocations();
                      Navigator.pop(dCtx);
                    }
                  },
                  child: Text(AppStrings.t('create_btn')),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _syncMyRealGpsLocationWithDisclosure() async {
    if (!_hasShownLocationDisclosure) {
      final agreed = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: AppColors.cardWhite,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        builder: (ctx) => Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  color: AppColors.lightPurpleBg,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.location_on_rounded,
                  color: AppColors.primaryPurple,
                  size: 28,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                AppStrings.t('loc_disclosure_title'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textDark,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                AppStrings.t('loc_disclosure_body'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textGray,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryPurple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    AppStrings.t('loc_disclosure_agree'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      if (agreed != true) return;
      _hasShownLocationDisclosure = true;
    }

    await _syncMyRealGpsLocation();
  }

  Future<void> _syncMyRealGpsLocation() async {
    if (!mounted) return;
    setState(() => isSyncingGps = true);
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final realLatLng = LatLng(pos.latitude, pos.longitude);
      final rawSpeed = pos.speed.isNaN || pos.speed < 0 ? 0.0 : pos.speed;
      final speedKmh = (rawSpeed * 3.6).clamp(0.0, 200.0);

      await _readRealBattery();
      final realAddr = await AppEngineService.instance.fetchRoadAddress(
        realLatLng,
      );

      if (!mounted) return;
      setState(() {
        _allMembers[0].location = realLatLng;
        _allMembers[0].speedKmh = speedKmh;
        _allMembers[0].statusText = '$realAddr • ${AppStrings.t('just_now')}';
        if (_allMembers[0].recentRoute.length <= 1) {
          _allMembers[0].recentRoute = [realLatLng];
        } else {
          final lastPt = _allMembers[0].recentRoute.last;
          if (AppEngineService.instance.calculateDistanceMeters(
                lastPt,
                realLatLng,
              ) >=
              15.0) {
            _allMembers[0].recentRoute = [
              ..._allMembers[0].recentRoute,
              realLatLng,
            ];
          }
        }

        if (_allMembers.length >= 3 &&
            (_showDemoMembers || activeCircle.code == '999999')) {
          _allMembers[1].location = LatLng(
            realLatLng.latitude + 0.0042,
            realLatLng.longitude - 0.0018,
          );
          _allMembers[2].location = LatLng(
            realLatLng.latitude - 0.0035,
            realLatLng.longitude + 0.0048,
          );
        }
      });
      _mapController.move(realLatLng, 15.3);

      await AppEngineService.instance.pushLiveLocationToServer(
        circleCode: activeCircle.code,
        userName: _allMembers[0].name,
        point: realLatLng,
        battery: _allMembers[0].battery,
        avatarUrl: _allMembers[0].avatarUrl,
        speedKmh: speedKmh,
      );

      await _initRealRoadAddressesAndRoutes();
    } catch (_) {
      if (!mounted) return;
      _mapController.move(_allMembers[0].location, 14.8);
    } finally {
      if (mounted) setState(() => isSyncingGps = false);
    }
  }

  void _startAddingNewPlace({LatLng? initialPoint}) {
    if (!isProUser && safePlaces.length >= 2) {
      _showProPaywallSheet();
      return;
    }

    setState(() {
      selectedMemberId = null;
      isPickingPlaceOnMap = true;
      draftPlacePoint = initialPoint ?? _mapController.camera.center;
      draftPlaceRadius = 200.0;
      draftPlaceIcon = Icons.school_rounded;
      _placeNameController.text = AppStrings.t('default_school');
    });
    _mapController.move(draftPlacePoint, 15.2);
  }

  Future<void> _confirmAndSaveNewPlace() async {
    final nameText = _placeNameController.text.trim().isEmpty
        ? AppStrings.t('places_btn')
        : _placeNameController.text.trim();

    final newPlace = SafePlaceData(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: nameText,
      iconData: draftPlaceIcon,
      point: draftPlacePoint,
      radiusMeters: draftPlaceRadius,
    );

    setState(() {
      safePlaces.add(newPlace);
      isPickingPlaceOnMap = false;
    });
    _syncMySafePlacesToEngine(broadcastNow: true);

    try {
      await Supabase.instance.client.from('places').insert({
        'name': nameText,
        'latitude': draftPlacePoint.latitude,
        'longitude': draftPlacePoint.longitude,
        'radius_meters': draftPlaceRadius.round(),
      });
    } catch (_) {}
  }

  void _showManagePlacesSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.cardWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      AppStrings.t('manage_places_title'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textDark,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.lightPurpleBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      isProUser
                          ? AppStrings.t('pro_unlimited')
                          : '${AppStrings.t('free_limit')} ${safePlaces.length}/2',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryPurple,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ...safePlaces.map(
                (p) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: AppColors.lightPurpleBg,
                    child: Icon(
                      p.iconData,
                      color: AppColors.primaryPurple,
                      size: 20,
                    ),
                  ),
                  title: Text(
                    p.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  subtitle: Text(
                    '${p.radiusMeters.round()}m • ${AppStrings.t('radius_alert_on')}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textGray,
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: AppColors.textGray,
                    ),
                    onPressed: () {
                      setState(() {
                        safePlaces.removeWhere((item) => item.id == p.id);
                      });
                      setModalState(() {});
                    },
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _mapController.move(p.point, 15.5);
                  },
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryPurple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    _startAddingNewPlace();
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: Text(
                    (!isProUser && safePlaces.length >= 2)
                        ? AppStrings.t('add_unlimited_pro')
                        : AppStrings.t('add_new_place'),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _focusMemberOnMap(MemberData member) {
    HapticFeedback.selectionClick();
    setState(() {
      isPickingPlaceOnMap = false;
      selectedMemberId = member.id;
      _selectedHistoryDayTab = 0;
    });
    _mapController.move(member.location, 15.2);
    if (_sheetController.isAttached && _sheetController.size < 0.3) {
      _sheetController.animateTo(
        0.36,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _showSafeReturnWebLinkDialog() async {
    final token =
        'PINGO-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
    final shareUrl = 'https://pingo.pages.dev/live/$token';

    try {
      await Supabase.instance.client.from('live_shares').insert({
        'token': token,
        'expires_at': DateTime.now()
            .add(const Duration(minutes: 30))
            .toIso8601String(),
        'is_active': true,
      });
    } catch (_) {}

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.cardWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.safeGreenBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.share_location_rounded,
                    color: AppColors.safeGreenText,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppStrings.t('safe_share'),
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textDark,
                        ),
                      ),
                      Text(
                        AppStrings.t('safe_share_sub'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textGray,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.divider),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      shareUrl,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryPurple,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.copy_rounded,
                      color: AppColors.primaryPurple,
                    ),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: shareUrl));
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(
                          backgroundColor: AppColors.primaryPurple,
                          content: Text(AppStrings.t('copy_link')),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryPurple,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(25),
                  ),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    this.context,
                    MaterialPageRoute(
                      builder: (_) => SafeReturnLiveWebScreen(
                        sharerName: _allMembers[0].name,
                        shareToken: token,
                        startLocation: _allMembers[0].location,
                        initialBattery: _allMembers[0].battery,
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                label: Text(
                  AppStrings.t('preview_web_screen'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showProPaywallSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.cardWhite,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: AppColors.lightPurpleBg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  AppStrings.t('pro_header_badge'),
                  style: const TextStyle(
                    color: AppColors.primaryPurple,
                    fontWeight: FontWeight.bold,
                    fontSize: 11,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                AppStrings.t('upgrade_pro'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textDark,
                ),
              ),
              const SizedBox(height: 10),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.history_rounded,
                  color: AppColors.primaryPurple,
                ),
                title: Text(
                  AppStrings.t('pro_feat_1_title'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13.5,
                  ),
                ),
                subtitle: Text(
                  AppStrings.t('pro_feat_1_sub'),
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.notifications_active_rounded,
                  color: AppColors.primaryPurple,
                ),
                title: Text(
                  AppStrings.t('pro_feat_2_title'),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13.5,
                  ),
                ),
                subtitle: Text(
                  AppStrings.t('pro_feat_2_sub'),
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () =>
                          setModalState(() => _selectedYearlyPlan = false),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: !_selectedYearlyPlan
                              ? AppColors.lightPurpleBg
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: !_selectedYearlyPlan
                                ? AppColors.primaryPurple
                                : const Color(0xFFE5E7EB),
                            width: !_selectedYearlyPlan ? 2.2 : 1.2,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppStrings.t('plan_monthly_title'),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textGray,
                              ),
                            ),
                            const SizedBox(height: 4),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                AppStrings.t('plan_monthly_price'),
                                maxLines: 1,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w900,
                                  color: AppColors.textDark,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      onTap: () =>
                          setModalState(() => _selectedYearlyPlan = true),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _selectedYearlyPlan
                                  ? AppColors.lightPurpleBg
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _selectedYearlyPlan
                                    ? AppColors.primaryPurple
                                    : const Color(0xFFE5E7EB),
                                width: _selectedYearlyPlan ? 2.2 : 1.2,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppStrings.t('plan_yearly_title'),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.primaryPurple,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    AppStrings.t('plan_yearly_price'),
                                    maxLines: 1,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w900,
                                      color: AppColors.textDark,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Positioned(
                            top: -9,
                            right: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.accentPink,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                AppStrings.t('plan_best_badge'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryPurple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                  onPressed: () async {
                    final targetProdId = _selectedYearlyPlan
                        ? AppEngineService.proYearlyProductId
                        : AppEngineService.proMonthlyProductId;
                    await AppEngineService.instance.purchaseProSubscription(
                      productId: targetProdId,
                      onProUnlocked: () {
                        if (mounted) {
                          setState(() => isProUser = true);
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            SnackBar(
                              backgroundColor: AppColors.safeGreenText,
                              content: Text(
                                AppStrings.t('pro_activated_toast'),
                              ),
                            ),
                          );
                        }
                      },
                    );
                  },
                  child: Text(
                    AppStrings.t('pro_start_btn'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: () => AppEngineService.openExternalLegalUrl(
                      isTermsOfUse: true,
                    ),
                    child: Text(
                      AppStrings.t('terms_eula'),
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        color: AppColors.primaryPurple,
                      ),
                    ),
                  ),
                  const Text('•', style: TextStyle(color: AppColors.textGray)),
                  TextButton(
                    onPressed: () => AppEngineService.openExternalLegalUrl(
                      isTermsOfUse: false,
                    ),
                    child: Text(
                      AppStrings.t('privacy_policy'),
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        color: AppColors.primaryPurple,
                      ),
                    ),
                  ),
                  const Text('•', style: TextStyle(color: AppColors.textGray)),
                  TextButton(
                    onPressed: () async {
                      await AppEngineService.instance.restoreProPurchases(
                        onProUnlocked: () {
                          if (!mounted) return;
                          setState(() => isProUser = true);
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            SnackBar(
                              backgroundColor: AppColors.primaryPurple,
                              content: Text(AppStrings.t('restore_toast')),
                            ),
                          );
                        },
                      );
                    },
                    child: Text(
                      AppStrings.t('restore_purchases'),
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        color: AppColors.textGray,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                AppStrings.t('sub_auto_renew_notice'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, color: AppColors.textGray),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeMembers = visibleMembers;
    MemberData? selectedMember;
    for (final m in activeMembers) {
      if (m.id == selectedMemberId) {
        selectedMember = m;
        break;
      }
    }

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _allMembers[0].location,
              initialZoom: 15.0,
              onPositionChanged: (pos, hasGesture) {
                if (isPickingPlaceOnMap) {
                  setState(() => draftPlacePoint = pos.center);
                }
              },
              onTap: (_, tappedLatLng) {
                if (isPickingPlaceOnMap) {
                  HapticFeedback.lightImpact();
                  setState(() => draftPlacePoint = tappedLatLng);
                } else {
                  setState(() => selectedMemberId = null);
                  if (_sheetController.isAttached &&
                      _sheetController.size > 0.25) {
                    _sheetController.animateTo(
                      0.14,
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOutCubic,
                    );
                  }
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: AppConfig.buildLocalizedMapTileUrl(_mapStyleIndex),
                userAgentPackageName: 'com.jgsoft.pingolive',
              ),
              CircleLayer(
                circles: [
                  ...safePlaces.map(
                    (p) => CircleMarker(
                      point: p.point,
                      radius: p.radiusMeters,
                      useRadiusInMeter: true,
                      color: AppColors.geofenceFill,
                      borderColor: AppColors.primaryPurple,
                      borderStrokeWidth: 2.2,
                    ),
                  ),
                  if (AppEngineService.instance.isBubblePrivacyActive)
                    CircleMarker(
                      point: _allMembers[0].location,
                      radius: 600.0,
                      useRadiusInMeter: true,
                      color: const Color(0x308B5CF6),
                      borderColor: const Color(0xFF7C3AED),
                      borderStrokeWidth: 2.5,
                    ),
                  ...activeMembers
                      .where((m) => _otherBubbleMemberIds.contains(m.id))
                      .map(
                        (m) => CircleMarker(
                          point: m.location,
                          radius: 600.0,
                          useRadiusInMeter: true,
                          color: const Color(0x30EC4899),
                          borderColor: const Color(0xFFDB2777),
                          borderStrokeWidth: 2.5,
                        ),
                      ),
                  if (isPickingPlaceOnMap)
                    CircleMarker(
                      point: draftPlacePoint,
                      radius: draftPlaceRadius,
                      useRadiusInMeter: true,
                      color: const Color(0x386C47FF),
                      borderColor: AppColors.primaryPurple,
                      borderStrokeWidth: 2.5,
                    ),
                ],
              ),
              if (selectedMember != null)
                Builder(
                  builder: (context) {
                    final bool canShowRoute =
                        _selectedHistoryDayTab < 2 || isProUser;
                    if (!canShowRoute) return const SizedBox.shrink();

                    final List<LatLng> activePts = AppEngineService.instance
                        .getRouteForMemberTab(
                          selectedMember!.id,
                          _selectedHistoryDayTab,
                          selectedMember.location,
                          customDateKey: _selectedHistoryDayTab == 3
                              ? _selectedCustomDateKey
                              : null,
                        );
                    if (activePts.length < 2) return const SizedBox.shrink();

                    return PolylineLayer(
                      polylines: [
                        Polyline(
                          points: activePts,
                          color: AppColors.primaryPurple.withValues(
                            alpha: 0.22,
                          ),
                          strokeWidth: 14.0,
                        ),
                        Polyline(
                          points: activePts,
                          color: Colors.white,
                          strokeWidth: 9.0,
                        ),
                        Polyline(
                          points: activePts,
                          color: AppColors.primaryPurple,
                          strokeWidth: 5.5,
                        ),
                      ],
                    );
                  },
                ),
              MarkerLayer(
                markers: [
                  ...safePlaces.map(
                    (p) => Marker(
                      point: LatLng(
                        p.point.latitude - 0.0011,
                        p.point.longitude,
                      ),
                      width: 110,
                      height: 30,
                      child: GestureDetector(
                        onTap: _showManagePlacesSheet,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.primaryPurple.withValues(
                                alpha: 0.90,
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(p.iconData, size: 12, color: Colors.white),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    p.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (isPickingPlaceOnMap)
                    Marker(
                      point: draftPlacePoint,
                      width: 60,
                      height: 60,
                      child: const Icon(
                        Icons.location_on_rounded,
                        size: 48,
                        color: AppColors.primaryPurple,
                      ),
                    ),
                ],
              ),
              MarkerLayer(
                markers: activeMembers.map((m) {
                  final isSelected = selectedMemberId == m.id;
                  final activePing = _activeMemberBubblePings[m.id];

                  return Marker(
                    point: m.location,
                    width: 132,
                    height: 142,
                    child: GestureDetector(
                      onTap: () => _focusMemberOnMap(m),

                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (isSelected)
                            AnimatedBuilder(
                              animation: _pulseController,
                              builder: (context, _) {
                                return Container(
                                  width: 48 + (_pulseController.value * 44),
                                  height: 48 + (_pulseController.value * 44),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppColors.primaryPurple.withValues(
                                      alpha:
                                          (1.0 - _pulseController.value) * 0.35,
                                    ),
                                  ),
                                );
                              },
                            ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (activePing != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.primaryPurple,
                                    borderRadius: BorderRadius.circular(12),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Colors.black26,
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    activePing,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                )
                              else
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.cardWhite,
                                    borderRadius: BorderRadius.circular(10),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Colors.black12,
                                        blurRadius: 4,
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.bolt_rounded,
                                        size: 11,
                                        color: AppColors.safeGreenText,
                                      ),
                                      Text(
                                        '${m.battery}%',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.safeGreenText,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              const SizedBox(height: 3),
                              Stack(
                                clipBehavior: Clip.none,
                                alignment: Alignment.bottomCenter,
                                children: [
                                  Positioned(
                                    bottom: -11,
                                    child: Container(
                                      width: 22,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.25,
                                        ),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    bottom: -7,
                                    child: CustomPaint(
                                      size: const Size(14, 9),
                                      painter: _PinTailPainter(
                                        color: isSelected
                                            ? AppColors.primaryPurple
                                            : Colors.white,
                                      ),
                                    ),
                                  ),
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    width: isSelected ? 54 : 48,
                                    height: isSelected ? 54 : 48,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.white,
                                      border: Border.all(
                                        color: isSelected
                                            ? AppColors.primaryPurple
                                            : Colors.white,
                                        width: isSelected ? 3.2 : 2.5,
                                      ),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black26,
                                          blurRadius: 10,
                                          offset: Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: _buildMemberAvatarImage(
                                      m,
                                      size: isSelected ? 50 : 44,
                                    ),
                                  ),
                                  Positioned(
                                    right: -2,
                                    bottom: -2,
                                    child: Container(
                                      width: 20,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: AppColors.divider,
                                          width: 1,
                                        ),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Colors.black12,
                                            blurRadius: 3,
                                          ),
                                        ],
                                      ),
                                      child: Center(
                                        child: Icon(
                                          m.statusIcon,
                                          size: 12,
                                          color: AppColors.primaryPurple,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),

          // ✨ 지도 상단: [Family ∨] 선택창을 제거하여 지도 시야가 시원하게 뚫린 상단 바
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: _showMultiCircleSwitcherSheet,
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: AppColors.cardWhite,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 12,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.manage_accounts_rounded,
                        color: AppColors.primaryPurple,
                        size: 21,
                      ),
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _showProPaywallSheet,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: isProUser
                            ? AppColors.safeGreenText
                            : AppColors.cardWhite,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 12,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.workspace_premium_rounded,
                            size: 16,
                            color: isProUser
                                ? Colors.white
                                : AppColors.primaryPurple,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isProUser
                                ? AppStrings.t('pro_active_badge')
                                : AppStrings.t('pro_badge_btn'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: isProUser
                                  ? Colors.white
                                  : AppColors.primaryPurple,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          Positioned(
            left: 16,
            top: MediaQuery.of(context).padding.top + 68,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onLongPress: _showLife360SilentSosModal,
                  onTap: _showLife360SilentSosModal,
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFF4D4F),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: Colors.black26, blurRadius: 8),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        AppStrings.t('sos_btn_label'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'checkin_btn',
                  backgroundColor: AppColors.cardWhite,
                  foregroundColor: AppColors.primaryPurple,
                  onPressed: _sendOneTapCheckIn,
                  child: const Icon(Icons.where_to_vote_rounded, size: 20),
                ),
              ],
            ),
          ),

          Positioned(
            right: 16,
            top: MediaQuery.of(context).padding.top + 68,
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'map_style_toggle',
                  backgroundColor: _mapStyleIndex == 1
                      ? AppColors.textDark
                      : AppColors.cardWhite,
                  foregroundColor: _mapStyleIndex == 1
                      ? Colors.amber
                      : AppColors.primaryPurple,
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    setState(() {
                      _mapStyleIndex =
                          (_mapStyleIndex + 1) % _mapStyleIcons.length;
                    });
                  },
                  child: Icon(_mapStyleIcons[_mapStyleIndex], size: 18),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'zoom_in',
                  backgroundColor: AppColors.cardWhite,
                  foregroundColor: AppColors.textDark,
                  onPressed: () {
                    final z = _mapController.camera.zoom + 1;
                    _mapController.move(_mapController.camera.center, z);
                  },
                  child: const Icon(Icons.add),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'zoom_out',
                  backgroundColor: AppColors.cardWhite,
                  foregroundColor: AppColors.textDark,
                  onPressed: () {
                    final z = _mapController.camera.zoom - 1;
                    _mapController.move(_mapController.camera.center, z);
                  },
                  child: const Icon(Icons.remove),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'my_real_gps',
                  backgroundColor: AppColors.cardWhite,
                  foregroundColor: AppColors.primaryPurple,
                  onPressed: isSyncingGps
                      ? null
                      : _syncMyRealGpsLocationWithDisclosure,
                  child: isSyncingGps
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            color: AppColors.primaryPurple,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.my_location_rounded, size: 18),
                ),
              ],
            ),
          ),

          if (_incomingBannerSenderId != null && _incomingBannerText != null)
            Positioned(
              top: 66,
              left: 16,
              right: 16,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1E1B4B), Color(0xFF312E81)],
                    ),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 18,
                        offset: Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.auto_awesome_rounded,
                        color: Color(0xFFF472B6),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _incomingBannerSenderName ?? '',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              _incomingBannerText!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () {
                          final sender = _allMembers.firstWhere(
                            (m) => m.id == _incomingBannerSenderId,
                            orElse: () => _allMembers.last,
                          );
                          setState(() => _incomingBannerSenderId = null);
                          _sendQuickPingToMember(sender, 'q_otw');
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF10B981), Color(0xFF059669)],
                            ),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            AppStrings.t('reply_otw'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () {
                          final sender = _allMembers.firstWhere(
                            (m) => m.id == _incomingBannerSenderId,
                            orElse: () => _allMembers.last,
                          );
                          _handleMemberPhoneAction(
                            member: sender,
                            isCall: true,
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.all(7),
                          decoration: const BoxDecoration(
                            color: Colors.white24,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.call_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          DraggableScrollableSheet(
            controller: _sheetController,
            initialChildSize: 0.33,
            minChildSize: 0.14,
            maxChildSize: 0.65,
            snap: true,
            snapSizes: const [0.14, 0.33, 0.65],
            builder: (context, scrollController) {
              return Container(
                decoration: const BoxDecoration(
                  color: AppColors.cardWhite,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x18000000),
                      blurRadius: 24,
                      offset: Offset(0, -4),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: isPickingPlaceOnMap
                      ? _buildAddPlaceInteractiveSheet()
                      : (selectedMember == null
                            ? _buildDefaultMemberListSheet()
                            : _buildMemberHistoryDrillDownSheet(
                                selectedMember,
                              )),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAddPlaceInteractiveSheet() {
    final iconChoices = [
      Icons.home_rounded,
      Icons.school_rounded,
      Icons.work_rounded,
      Icons.local_cafe_rounded,
      Icons.fitness_center_rounded,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                AppStrings.t('pick_place_title'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textDark,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded),
              onPressed: () => setState(() => isPickingPlaceOnMap = false),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            ...iconChoices.map((ic) {
              final selected = draftPlaceIcon == ic;
              return GestureDetector(
                onTap: () => setState(() => draftPlaceIcon = ic),
                child: Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.primaryPurple
                        : const Color(0xFFF3F4F6),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    ic,
                    size: 17,
                    color: selected ? Colors.white : AppColors.textGray,
                  ),
                ),
              );
            }),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                controller: _placeNameController,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                  hintText: AppStrings.t('place_name_hint'),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              AppStrings.t('radius_label'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            Expanded(
              child: Slider(
                value: draftPlaceRadius,
                min: 100,
                max: 500,
                divisions: 8,
                activeColor: AppColors.primaryPurple,
                onChanged: (v) => setState(() => draftPlaceRadius = v),
              ),
            ),
            Text(
              '${draftPlaceRadius.round()}m',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryPurple,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryPurple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            onPressed: _confirmAndSaveNewPlace,
            child: Text(
              AppStrings.t('save_place_btn'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // [시안 1번 완벽 구현] 메인 지도 하단 기본 시트 (프로필/멤버 리스트 + 멤버 초대하기 버튼)
  // ---------------------------------------------------------------------------
  Widget _buildDefaultMemberListSheet() {
    final otherMembers = visibleMembers.where((m) => m.id != 'm1').toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _toggleBottomSheetSnap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 40),
            child: Container(
              width: 42,
              height: 4.5,
              decoration: BoxDecoration(
                color: const Color(0xFFD1D5DB),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: _showSafeReturnWebLinkDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.safeGreenBg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.near_me_rounded,
                        size: 16,
                        color: AppColors.safeGreenText,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          AppStrings.t('safe_share'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: AppColors.safeGreenText,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() {
                    selectedMemberId = 'm1';
                    _selectedHistoryDayTab = 0;
                    _selectedCustomDateKey = null;
                    _customCalendarDateLabel = '';
                  });
                  _fitMapToRouteOrMember(_allMembers[0], 0);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.lightPurpleBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppColors.primaryPurple.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.history_rounded,
                        size: 17,
                        color: AppColors.primaryPurple,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          AppStrings.t('my_timeline_btn'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: AppColors.primaryPurple,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: AppColors.safeGreenText,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${otherMembers.length + 1} ${AppStrings.t('members_count')}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textDark,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: _broadcastMySafeCheckIn,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.safeGreenBg,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      size: 12,
                      color: AppColors.safeGreenText,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      AppStrings.t('checkin_bubble'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppColors.safeGreenText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 5),
            GestureDetector(
              onTap: _toggleDemoFamilyMode,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: _showDemoMembers
                      ? AppColors.primaryPurple
                      : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  _showDemoMembers
                      ? AppStrings.t('demo_chip_off')
                      : AppStrings.t('demo_chip_on'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _showDemoMembers ? Colors.white : AppColors.textGray,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 5),
            GestureDetector(
              onTap: _showManagePlacesSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.lightPurpleBg,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.add_location_alt_rounded,
                      size: 12,
                      color: AppColors.primaryPurple,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${AppStrings.t('places_btn')} ${safePlaces.length}/${isProUser ? "\u221E" : "2"}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppColors.primaryPurple,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Divider(color: AppColors.divider, height: 10),
        if (otherMembers.isNotEmpty)
          ...otherMembers.map(
            (m) => InkWell(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() {
                  selectedMemberId = m.id;
                  _selectedHistoryDayTab = 0;
                  _selectedCustomDateKey = null;
                  _customCalendarDateLabel = '';
                });
                _fitMapToRouteOrMember(m, 0);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9.0),
                child: Row(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppColors.primaryPurple.withValues(
                                alpha: 0.35,
                              ),
                              width: 2,
                            ),
                          ),
                          child: _buildMemberAvatarImage(m, size: 42),
                        ),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              m.statusIcon,
                              size: 11,
                              color: AppColors.primaryPurple,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  m.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.textDark,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _buildSmartMotionBadge(m),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            m.statusText,
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textGray,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.safeGreenBg,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${m.battery}%',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: AppColors.safeGreenText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryPurple,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: _showMultiCircleSwitcherSheet,
            icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
            label: Text(
              AppStrings.t('invite_member_btn'),
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _customCalendarDateLabel = '';
  String? _selectedCustomDateKey;

  // ---------------------------------------------------------------------------
  // [고도화] 탭 전환 시 해당 날짜 경로 전체가 한눈에 들어오도록 지도 카메라 자동 줌핏
  // ---------------------------------------------------------------------------
  void _fitMapToRouteOrMember(
    MemberData member,
    int tabIdx, {
    String? customDateKey,
  }) {
    final List<LatLng> pts = AppEngineService.instance.getRouteForMemberTab(
      member.id,
      tabIdx,
      member.location,
      customDateKey: customDateKey,
    );
    if (pts.length < 2) {
      _mapController.move(pts.isNotEmpty ? pts.last : member.location, 15.5);
      return;
    }
    double minLat = pts.first.latitude, maxLat = pts.first.latitude;
    double minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final LatLng p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    if ((maxLat - minLat).abs() < 0.0008 && (maxLng - minLng).abs() < 0.0008) {
      _mapController.move(pts.last, 15.8);
      return;
    }
    try {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng)),
          padding: const EdgeInsets.fromLTRB(56, 140, 56, 300),
          maxZoom: 16.2,
        ),
      );
    } catch (_) {
      _mapController.move(pts.last, 15.0);
    }
  }

  Future<void> _openTimelineCalendarPicker(MemberData member) async {
    HapticFeedback.selectionClick();
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.subtract(const Duration(days: 2)),
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now,
      builder: (ctx, child) {
        return Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.primaryPurple,
              onPrimary: Colors.white,
              onSurface: AppColors.textDark,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null || !mounted) return;
    final pickedKey = AppEngineService.dateKeyOf(picked);
    final tKey = AppEngineService.todayKey;
    final yKey = AppEngineService.yesterdayKey;

    setState(() {
      if (pickedKey == tKey) {
        _selectedHistoryDayTab = 0;
        _selectedCustomDateKey = null;
        _customCalendarDateLabel = '';
      } else if (pickedKey == yKey) {
        _selectedHistoryDayTab = 1;
        _selectedCustomDateKey = null;
        _customCalendarDateLabel = '';
      } else {
        _selectedHistoryDayTab = 3;
        _selectedCustomDateKey = pickedKey;
        _customCalendarDateLabel = '${picked.month}/${picked.day}';
      }
      final pts = AppEngineService.instance.getRouteForMemberTab(
        member.id,
        _selectedHistoryDayTab,
        member.location,
        customDateKey: _selectedCustomDateKey,
      );
      member.recentRoute = pts.isNotEmpty ? pts : [member.location];
    });

    if (_selectedHistoryDayTab < 2 || isProUser) {
      _fitMapToRouteOrMember(
        member,
        _selectedHistoryDayTab,
        customDateKey: _selectedCustomDateKey,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // [고도화] 멤버 상세 및 이동 타임라인 모달 (오늘 | 어제 | 👑 30일 | 📅 캘린더)
  // ---------------------------------------------------------------------------
  Widget _buildMemberHistoryDrillDownSheet(MemberData member) {
    final bool isMe = member.id == 'm1';

    final emojiQuickNotes = [
      {
        'emoji': '\uD83C\uDFE0',
        'label': AppStrings.t('note_at_home'),
        'msg': '\uD83C\uDFE0 ${AppStrings.t('note_at_home')}',
      },
      {
        'emoji': '\uD83C\uDFEB',
        'label': AppStrings.t('note_at_school'),
        'msg': '\uD83C\uDFEB ${AppStrings.t('note_at_school')}',
      },
      {
        'emoji': '\uD83C\uDFE2',
        'label': AppStrings.t('note_at_work'),
        'msg': '\uD83C\uDFE2 ${AppStrings.t('note_at_work')}',
      },
      {
        'emoji': '\uD83D\uDE97',
        'label': AppStrings.t('note_on_way'),
        'msg': '\uD83D\uDE97 ${AppStrings.t('note_on_way')}',
      },
      {
        'emoji': '\u26A1',
        'label': AppStrings.t('note_charging'),
        'msg': '\u26A1 ${AppStrings.t('note_charging')}',
      },
    ];

    final oneTouchPingItems = [
      {
        'emoji': '\uD83D\uDC4B',
        'label': AppStrings.t('ping_wave'),
        'msg': '\uD83D\uDC4B ${AppStrings.t('ping_wave')}!',
      },
      {
        'emoji': '\u2764\uFE0F',
        'label': AppStrings.t('ping_heart'),
        'msg': '\u2764\uFE0F ${AppStrings.t('ping_heart')}!',
      },
      {
        'emoji': '\uD83D\uDC40',
        'label': AppStrings.t('ping_where'),
        'msg': '\uD83D\uDC40 ${AppStrings.t('ping_where')}',
      },
      {
        'emoji': '\u26A1',
        'label': AppStrings.t('ping_charge'),
        'msg': '\u26A1 ${AppStrings.t('ping_charge')}',
      },
    ];

    final List<LatLng> activeTabRoute = AppEngineService.instance
        .getRouteForMemberTab(
          member.id,
          _selectedHistoryDayTab,
          member.location,
          customDateKey: _selectedHistoryDayTab == 3
              ? _selectedCustomDateKey
              : null,
        );

    final List timelineSteps = AppEngineService.instance
        .buildDetailedTimelineSteps(activeTabRoute, safePlaces: safePlaces);

    final List thirtyDayList = AppEngineService.instance
        .getThirtyDaysDailyBreakdown(
          member.id,
          member.location,
          safePlaces: safePlaces,
        );

    double displayDistKm = 0.0;
    int estMinutes = 0;
    int visitedCount = 0;

    if (_selectedHistoryDayTab == 2) {
      for (final dynamic d in thirtyDayList) {
        displayDistKm += (d['distanceKm'] as double? ?? 0.0);
        estMinutes += (d['minutes'] as int? ?? 0);
        visitedCount += (d['placesCount'] as int? ?? 0);
      }
    } else {
      displayDistKm = AppEngineService.instance.computeRouteDistanceKm(
        activeTabRoute,
      );
      visitedCount = timelineSteps.length;
      estMinutes = activeTabRoute.length < 2
          ? 0
          : (displayDistKm * 6.5 + visitedCount * 4).round();
    }

    final int hrs = estMinutes ~/ 60;
    final int mins = estMinutes % 60;
    final String durationText = hrs > 0
        ? '$hrs${AppStrings.t('stat_hours_unit')} $mins${AppStrings.t('stat_mins_unit')}'
        : '$mins${AppStrings.t('stat_mins_unit')}';
    final String visitedText =
        '$visitedCount${AppStrings.t('stat_places_unit')}';

    final String cleanAddress = member.statusText.split('\u2022').first.trim();
    final String elapsedText = _formatMemberElapsed(member.id);
    final String statusSubText = member.speedKmh >= 2.0
        ? '$elapsedText \u2022 ${AppStrings.t('filter_moving')}'
        : '$elapsedText \u2022 ${AppStrings.t('status_staying')}';

    final bool isLockedProTab = _selectedHistoryDayTab >= 2 && !isProUser;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: GestureDetector(
            onTap: _toggleBottomSheetSnap,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: 4.0,
                horizontal: 40,
              ),
              child: Container(
                width: 42,
                height: 4.5,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1D5DB),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primaryPurple, width: 2.2),
              ),
              child: _buildMemberAvatarImage(member, size: 46),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          member.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                            color: AppColors.textDark,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.safeGreenBg,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.bolt_rounded,
                              size: 12,
                              color: AppColors.safeGreenText,
                            ),
                            Text(
                              '${member.battery}%',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: AppColors.safeGreenText,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      statusSubText,
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textGray,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!isMe) ...[
              _buildJungDaEunActionBtn(
                icon: Icons.call_rounded,
                label: AppStrings.t('call_btn'),
                bgColor: const Color(0xFF16A34A),
                onTap: () async {
                  final phone =
                      AppEngineService.instance.memberPhones[member.id] ?? '';
                  if (phone.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(AppStrings.t('no_phone_msg'))),
                    );
                    return;
                  }
                  final uri = Uri.parse('tel:$phone');
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                },
              ),
              const SizedBox(width: 6),
              _buildJungDaEunActionBtn(
                icon: Icons.chat_bubble_rounded,
                label: AppStrings.t('sms_btn'),
                bgColor: AppColors.primaryPurple,
                onTap: () async {
                  final phone =
                      AppEngineService.instance.memberPhones[member.id] ?? '';
                  if (phone.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(AppStrings.t('no_phone_msg'))),
                    );
                    return;
                  }
                  final uri = Uri.parse('sms:$phone');
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                },
              ),
              const SizedBox(width: 6),
              _buildJungDaEunActionBtn(
                icon: Icons.near_me_rounded,
                label: AppStrings.t('nav_btn'),
                bgColor: const Color(0xFF0284C7),
                onTap: () async {
                  final lat = member.location.latitude;
                  final lng = member.location.longitude;
                  final uri = Uri.parse(
                    'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng',
                  );
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              ),
              const SizedBox(width: 6),
            ] else ...[
              GestureDetector(
                onTap: _broadcastMySafeCheckIn,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.safeGreenBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.check_circle_rounded,
                        size: 14,
                        color: AppColors.safeGreenText,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        AppStrings.t('checkin_bubble'),
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.safeGreenText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            IconButton(
              onPressed: () => setState(() => selectedMemberId = null),
              icon: const Icon(Icons.close_rounded, color: AppColors.textGray),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9)),
        const SizedBox(height: 10),
        if (isMe)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: emojiQuickNotes.map((item) {
                final String msg = item['msg']!;
                final bool isSelected =
                    _activeMemberBubblePings[member.id] == msg;
                return Padding(
                  padding: const EdgeInsets.only(right: 6.0),
                  child: GestureDetector(
                    onTap: () async {
                      HapticFeedback.lightImpact();
                      setState(() {
                        _activeMemberBubblePings[member.id] = msg;
                      });
                      await AppEngineService.instance.pushLiveLocationToServer(
                        circleCode: activeCircle.code,
                        userName: member.name,
                        point: member.location,
                        battery: member.battery,
                        avatarUrl: member.avatarUrl,
                        audioClipDataUrl:
                            'PING::$msg::${DateTime.now().millisecondsSinceEpoch}::${AppEngineService.instance.myPhoneNumber}',
                        speedKmh: member.speedKmh,
                        forceImmediate: true,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 6.5,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFFF3E8FF)
                            : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: isSelected
                              ? AppColors.primaryPurple
                              : const Color(0xFFE2E8F0),
                          width: isSelected ? 1.5 : 1.0,
                        ),
                      ),
                      child: Text(
                        '${item['emoji']} ${item['label']}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: isSelected
                              ? AppColors.primaryPurple
                              : AppColors.textDark,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.t('one_touch_ping_title'),
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textDark,
                ),
              ),
              const SizedBox(height: 7),
              Row(
                children: oneTouchPingItems.map((item) {
                  final String pingMsg =
                      '${widget.userName} \u2192 ${member.name}: ${item['msg']}';
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3.0),
                      child: GestureDetector(
                        onTap: () async {
                          HapticFeedback.mediumImpact();
                          setState(() {
                            _activeMemberBubblePings[member.id] = item['msg']!;
                          });
                          ScaffoldMessenger.of(context).hideCurrentSnackBar();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              behavior: SnackBarBehavior.floating,
                              duration: const Duration(seconds: 2),
                              backgroundColor: AppColors.primaryPurple,
                              content: Text(
                                pingMsg,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          );
                          await AppEngineService.instance.pushLiveLocationToServer(
                            circleCode: activeCircle.code,
                            userName: widget.userName,
                            point: member.location,
                            battery: member.battery,
                            avatarUrl: widget.userAvatarUrl,
                            audioClipDataUrl:
                                'PING::$pingMsg::${DateTime.now().millisecondsSinceEpoch}::${AppEngineService.instance.myPhoneNumber}',
                            speedKmh: member.speedKmh,
                            forceImmediate: true,
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          alignment: Alignment.center,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${item['emoji']} ${item['label']}',
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textDark,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              _buildDatePill(AppStrings.t('tab_today'), 0, member),
              _buildDatePill(AppStrings.t('tab_yesterday'), 1, member),
              _buildDatePill(
                '\uD83D\uDC51 ${AppStrings.t('tab_30days')}',
                2,
                member,
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () => _openTimelineCalendarPicker(member),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _selectedHistoryDayTab == 3
                          ? Colors.white
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: _selectedHistoryDayTab == 3
                          ? const [
                              BoxShadow(color: Colors.black12, blurRadius: 4),
                            ]
                          : null,
                    ),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '\uD83D\uDCC5 ${_customCalendarDateLabel.isNotEmpty ? _customCalendarDateLabel : AppStrings.t('tab_calendar')}',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: _selectedHistoryDayTab == 3
                                ? FontWeight.w900
                                : FontWeight.w600,
                            color: _selectedHistoryDayTab == 3
                                ? AppColors.primaryPurple
                                : AppColors.textGray,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Text(
                      '${displayDistKm.toStringAsFixed(1)}km',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: AppColors.primaryPurple,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AppStrings.t('stat_distance_label'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textGray,
                      ),
                    ),
                  ],
                ),
              ),
              Container(width: 1, height: 28, color: const Color(0xFFE2E8F0)),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      durationText,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textDark,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AppStrings.t('stat_duration_label'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textGray,
                      ),
                    ),
                  ],
                ),
              ),
              Container(width: 1, height: 28, color: const Color(0xFFE2E8F0)),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      visitedText,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: AppColors.safeGreenText,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AppStrings.t('stat_places_label'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textGray,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (isLockedProTab)
          GestureDetector(
            onTap: _showProPaywallSheet,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6C47FF), Color(0xFF9333EA)],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.lock_open_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      AppStrings.t('pro_timeline_banner_title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                  Text(
                    AppStrings.t('pro_banner_cta'),
                    style: const TextStyle(
                      color: Color(0xFFFDE047),
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          )
        else if (_selectedHistoryDayTab == 2)
          Container(
            constraints: const BoxConstraints(maxHeight: 145),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: thirtyDayList.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(14.0),
                    child: Center(
                      child: Text(
                        AppStrings.t('no_route_recorded'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textGray,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: thirtyDayList.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 10, color: Color(0xFFE2E8F0)),
                    itemBuilder: (ctx, idx) {
                      final dynamic item = thirtyDayList[idx];
                      final String dk = item['dateKey'] as String;
                      final double dKm = item['distanceKm'] as double;
                      final int pCnt = item['placesCount'] as int;
                      return InkWell(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() {
                            if (dk == AppEngineService.todayKey) {
                              _selectedHistoryDayTab = 0;
                              _selectedCustomDateKey = null;
                              _customCalendarDateLabel = '';
                            } else if (dk == AppEngineService.yesterdayKey) {
                              _selectedHistoryDayTab = 1;
                              _selectedCustomDateKey = null;
                              _customCalendarDateLabel = '';
                            } else {
                              _selectedHistoryDayTab = 3;
                              _selectedCustomDateKey = dk;
                              _customCalendarDateLabel = dk.length >= 10
                                  ? dk.substring(5).replaceAll('-', '/')
                                  : dk;
                            }
                          });
                          _fitMapToRouteOrMember(
                            member,
                            _selectedHistoryDayTab,
                            customDateKey: _selectedCustomDateKey,
                          );
                        },
                        child: Row(
                          children: [
                            const Icon(
                              Icons.calendar_today_rounded,
                              size: 14,
                              color: AppColors.primaryPurple,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                dk,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.textDark,
                                ),
                              ),
                            ),
                            Text(
                              '${dKm.toStringAsFixed(1)}km \u2022 $pCnt${AppStrings.t('stat_places_unit')}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primaryPurple,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.chevron_right_rounded,
                              size: 16,
                              color: AppColors.textGray,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          )
        else
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 155),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: timelineSteps.isEmpty
                ? Center(
                    child: Text(
                      AppStrings.t('no_route_recorded'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textGray,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: List.generate(timelineSteps.length, (idx) {
                        final dynamic step = timelineSteps[idx];
                        final String placeName = step['placeName'] as String;
                        final double segKm = step['segmentKm'] as double;
                        final LatLng pt = step['point'] as LatLng;
                        final bool isFirst = idx == 0;
                        final bool isLast = idx == timelineSteps.length - 1;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkWell(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                _mapController.move(pt, 16.5);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 2.5,
                                ),
                                child: Row(
                                  children: [
                                    if (isLast)
                                      const Icon(
                                        Icons.place_rounded,
                                        size: 15,
                                        color: AppColors.primaryPurple,
                                      )
                                    else
                                      Container(
                                        width: 10,
                                        height: 10,
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 2.5,
                                        ),
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: isFirst
                                              ? Colors.white
                                              : const Color(0xFF9333EA),
                                          border: isFirst
                                              ? Border.all(
                                                  color:
                                                      AppColors.primaryPurple,
                                                  width: 2.2,
                                                )
                                              : null,
                                        ),
                                      ),
                                    const SizedBox(width: 7),
                                    Expanded(
                                      child: Text(
                                        isLast && cleanAddress.isNotEmpty
                                            ? cleanAddress
                                            : placeName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: isLast ? 12.5 : 11.5,
                                          fontWeight: isLast
                                              ? FontWeight.w800
                                              : FontWeight.w700,
                                          color: isFirst
                                              ? AppColors.textGray
                                              : AppColors.textDark,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      isFirst
                                          ? '${AppStrings.t('timeline_max_speed')} ${AppEngineService.instance.getMaxSpeedForMemberTab(member.id, _selectedHistoryDayTab, member.speedKmh).toStringAsFixed(0)}km/h'
                                          : (isLast
                                                ? elapsedText
                                                : '+${segKm.toStringAsFixed(1)}km'),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: isLast
                                            ? AppColors.primaryPurple
                                            : AppColors.textGray,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (!isLast)
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 6.8,
                                  top: 1,
                                  bottom: 1,
                                ),
                                child: Container(
                                  width: 1.5,
                                  height: 10,
                                  color: const Color(0xFFCBD5E1),
                                ),
                              ),
                          ],
                        );
                      }),
                    ),
                  ),
          ),
      ],
    );
  }

  Widget _buildJungDaEunActionBtn({
    required IconData icon,
    required String label,
    required Color bgColor,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 50,
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: bgColor.withValues(alpha: 0.28),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: Colors.white),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDatePill(String label, int tabIdx, MemberData member) {
    final bool isSelected = _selectedHistoryDayTab == tabIdx;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          setState(() {
            _selectedHistoryDayTab = tabIdx;
            _selectedCustomDateKey = null;
            _customCalendarDateLabel = '';
            final pts = AppEngineService.instance.getRouteForMemberTab(
              member.id,
              tabIdx,
              member.location,
            );
            member.recentRoute = pts.isNotEmpty ? pts : [member.location];
          });
          if (tabIdx < 2 || isProUser) {
            _fitMapToRouteOrMember(member, tabIdx);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: isSelected
                ? const [BoxShadow(color: Colors.black12, blurRadius: 4)]
                : null,
          ),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
                  color: isSelected
                      ? AppColors.primaryPurple
                      : AppColors.textGray,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinTailPainter extends CustomPainter {
  final Color color;
  _PinTailPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _PinTailPainter oldDelegate) =>
      oldDelegate.color != color;
}
