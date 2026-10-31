import 'dart:convert';
import 'package:share_plus/share_plus.dart';
import 'dart:async';

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
import 'circle_onboarding_screen.dart';
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
        recentRoute: [const LatLng(37.7599, 126.7802)],
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
    final url = m.avatarUrl;
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
        _allMembers[i].recentRoute = [_allMembers[i].location];
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

  void _subscribeToSupabaseRealtimeLocations() {
    try {
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

              // 본인 ID이거나 본인 닉네임과 동일한 과거 유령 행(Row)은 완벽 차단!
              if (uid == null ||
                  uid == AppEngineService.instance.currentUserId ||
                  uName.trim() == _allMembers[0].name.trim()) {
                continue;
              }
              if (_blockedMemberIds.contains(uid)) continue;

              final rowCircle = row['circle_code']?.toString();
              if (rowCircle != null &&
                  rowCircle.isNotEmpty &&
                  rowCircle != activeCircle.code) {
                continue;
              }

              final lat = (row['latitude'] as num?)?.toDouble();
              final lng = (row['longitude'] as num?)?.toDouble();
              final bat = (row['battery_level'] as num?)?.toInt() ?? 88;
              final spd = (row['speed_kmh'] as num?)?.toDouble() ?? 0.0;
              final isRowSos = row['is_sos'] == true;
              final uAvatar =
                  row['avatar_url']?.toString() ??
                  PingoAvatars.presets[1]['url']!;
              final incomingSignal = row['audio_clip']?.toString();

              if (lat == null || lng == null) continue;
              final newPoint = LatLng(lat, lng);

              // 상대방 버블 프라이버시 상태 및 전화번호 메타데이터 파싱
              final bool isRemoteBubble =
                  incomingSignal != null && incomingSignal.startsWith('BUBBLE::ON');
              if (isRemoteBubble) {
                _otherBubbleMemberIds.add(uid);
                final bParts = incomingSignal.split('::');
                if (bParts.length >= 3 && bParts[2] != '0' && bParts[2].isNotEmpty) {
                  AppEngineService.instance.memberPhones[uid] = bParts[2];
                }
              } else {
                _otherBubbleMemberIds.remove(uid);
                if (incomingSignal != null && incomingSignal.startsWith('META::PHONE::')) {
                  final ph = incomingSignal.replaceFirst('META::PHONE::', '').trim();
                  if (ph.isNotEmpty) {
                    AppEngineService.instance.memberPhones[uid] = ph;
                  }
                }
              }

              setState(() {
                final existIdx = _allMembers.indexWhere((m) => m.id == uid);
                if (existIdx != -1) {
                  _allMembers[existIdx].name = uName;
                  _allMembers[existIdx].location = newPoint;
                  _allMembers[existIdx].battery = bat;
                  _allMembers[existIdx].speedKmh = spd;
                  _allMembers[existIdx].avatarUrl = uAvatar;
                  if (isRemoteBubble) {
                    _allMembers[existIdx].statusText =
                        AppStrings.t('bubble_masked_addr');
                  }
                  if (_allMembers[existIdx].recentRoute.isEmpty) {
                    _allMembers[existIdx].recentRoute = [newPoint];
                  } else {
                    final lastPt = _allMembers[existIdx].recentRoute.last;
                    if (AppEngineService.instance.calculateDistanceMeters(
                          lastPt,
                          newPoint,
                        ) >=
                        15.0) {
                      _allMembers[existIdx].recentRoute = [
                        ..._allMembers[existIdx].recentRoute,
                        newPoint,
                      ];
                    }
                  }
                } else {
                  // 새로운 가족이 합류했을 때 내 위치도 즉시 재전송하여 양방향 동기화 보장
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
                      recentRoute: [newPoint],
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

              // 상대방 SOS 수신 시 즉시 카메라 이동 및 긴급 배너 표시
              if (isRowSos &&
                  _lastProcessedIncomingSignal['SOS_$uid'] != 'ACTIVE') {
                _lastProcessedIncomingSignal['SOS_$uid'] = 'ACTIVE';
                _mapController.move(newPoint, 16.0);
                _triggerIncomingDynamicBanner(
                  senderId: uid,
                  senderName: uName,
                  messageText: '🚨 SOS! ${AppStrings.t('sos_Active_banner')}',
                );
              } else if (!isRowSos) {
                _lastProcessedIncomingSignal.remove('SOS_$uid');
              }

              // 실시간 이모지 퀵 노트(PING) / 체크인(CHECKIN) / 장소알림(PLACE) 수신 처리 (35초 이내 최신 신호만 울림)
              if (incomingSignal != null &&
                  incomingSignal.isNotEmpty &&
                  !incomingSignal.startsWith('BUBBLE::') &&
                  !incomingSignal.startsWith('META::') &&
                  _lastProcessedIncomingSignal[uid] != incomingSignal) {
                _lastProcessedIncomingSignal[uid] = incomingSignal;

                final parts = incomingSignal.split('::');
                if (parts.length >= 2) {
                  final rawMsg = parts[1];
                  final ts = parts.length >= 3 ? int.tryParse(parts[2]) : null;
                  final nowMs = DateTime.now().millisecondsSinceEpoch;
                  // 과거에 쌓인 오래된 신호가 뒷북으로 울리는 현상 원천 차단 (35초 유효기간)
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
                onChanged: (v) { if (v.trim().length >= 4) { Navigator.pop(ctx); } },
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

  void _showMultiCircleSwitcherSheet() {
    final code = activeCircle.code.padRight(6, '0');
    final formattedCode = '${code.substring(0, 3)}-${code.substring(3, 6)}';
    final inviteFullText = AppStrings.t('invite_auto_msg')
        .replaceAll('{CODE}', activeCircle.code);
    final nameEditCtrl = TextEditingController(text: _allMembers[0].name);
    final phoneEditCtrl = TextEditingController(
      text: AppEngineService.instance.myPhoneNumber,
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.cardWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 22,
            right: 22,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        AppStrings.t('circle_switch_title'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textDark,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        Navigator.pushReplacement(
                          this.context,
                          MaterialPageRoute(
                            builder: (_) => const CircleInviteScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: Text(AppStrings.t('circle_add_join')),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: Text(
                              AppStrings.t('edit_my_profile_title'),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textGray,
                              ),
                            ),
                          ),
                          DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: AppStrings.lang,
                              isDense: true,
                              icon: const Icon(
                                Icons.language_rounded,
                                size: 16,
                                color: AppColors.primaryPurple,
                              ),
                              items: AppStrings.supportedLanguages
                                  .map(
                                    (item) => DropdownMenuItem<String>(
                                      value: item['code'],
                                      child: Text(
                                        item['name']!,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (newLang) {
                                if (newLang != null) {
                                  setState(() {
                                    AppStrings.lang = newLang;
                                    if (_allMembers.length >= 3) {
                                      _allMembers[1].name = AppStrings.t(
                                        'demo_member_1',
                                      );
                                      _allMembers[2].name = AppStrings.t(
                                        'demo_member_2',
                                      );
                                    }
                                  });
                                  setModalState(() {});
                                  _initRealRoadAddressesAndRoutes();
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          GestureDetector(
                            onTap: () =>
                                AppEngineService.showAvatarAndPhotoPickerModal(
                                  context: this.context,
                                  currentAvatarUrl: _allMembers[0].avatarUrl,
                                  onSelected: (newUrl) {
                                    setState(
                                      () => _allMembers[0].avatarUrl = newUrl,
                                    );
                                    setModalState(() {});
                                    AppEngineService.instance
                                        .pushLiveLocationToServer(
                                          circleCode: activeCircle.code,
                                          userName: _allMembers[0].name,
                                          point: _allMembers[0].location,
                                          battery: _allMembers[0].battery,
                                          avatarUrl: newUrl,
                                        );
                                  },
                                ),
                            child: Stack(
                              alignment: Alignment.bottomRight,
                              children: [
                                Container(
                                  width: 54,
                                  height: 54,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: AppColors.primaryPurple,
                                      width: 2,
                                    ),
                                  ),
                                  child: _buildMemberAvatarImage(
                                    _allMembers[0],
                                    size: 50,
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
                                    size: 11,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              children: [
                                TextField(
                                  controller: nameEditCtrl,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13.5,
                                  ),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 9,
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                TextField(
                                  controller: phoneEditCtrl,
                                  keyboardType: TextInputType.phone,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12.5,
                                  ),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    hintText: AppStrings.t('my_phone_hint'),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryPurple,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 14,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: () {
                              final newName = nameEditCtrl.text.trim();
                              final newPhone = phoneEditCtrl.text.trim();
                              AppEngineService.instance.myPhoneNumber = newPhone;
                              if (newName.isNotEmpty) {
                                setState(() {
                                  _allMembers[0].name = newName;
                                  _allMembers[0].monogram = newName.length >= 2
                                      ? newName.substring(newName.length - 2)
                                      : newName;
                                });
                                AppEngineService.instance
                                    .pushLiveLocationToServer(
                                      circleCode: activeCircle.code,
                                      userName: newName,
                                      point: _allMembers[0].location,
                                      battery: _allMembers[0].battery,
                                      avatarUrl: _allMembers[0].avatarUrl,
                                    );
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: AppColors.primaryPurple,
                                    content: Text(
                                      AppStrings.t('profile_saved_toast'),
                                    ),
                                  ),
                                );
                              }
                            },
                            child: Text(
                              AppStrings.t('save_profile_btn'),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                ...List.generate(myCircles.length, (idx) {
                  final c = myCircles[idx];
                  final isCurrent = idx == currentCircleIndex;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: isCurrent
                          ? AppColors.primaryPurple
                          : const Color(0xFFF3F4F6),
                      child: Icon(
                        Icons.people_alt_rounded,
                        color: isCurrent ? Colors.white : AppColors.textGray,
                        size: 18,
                      ),
                    ),
                    title: Text(
                      c.name,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: isCurrent
                            ? AppColors.primaryPurple
                            : AppColors.textDark,
                      ),
                    ),
                    trailing: isCurrent
                        ? const Icon(
                            Icons.check_circle_rounded,
                            color: AppColors.primaryPurple,
                          )
                        : null,
                    onTap: () {
                      setState(() {
                        currentCircleIndex = idx;
                        selectedMemberId = null;
                      });
                      Navigator.pop(ctx);
                    },
                  );
                }),
                const Divider(color: AppColors.divider, height: 20),
                // Life360 스타일 초대 코드 + [💬 메신저 공유] / [✉️ 문자 전송] / [📋 복사] 3종 자동 입력 세트
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.lightPurpleBg,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${activeCircle.name} • ${AppStrings.t('invite_code_label')}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textGray,
                            ),
                          ),
                          Text(
                            formattedCode,
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                              color: AppColors.primaryPurple,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primaryPurple,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: () {
                                SharePlus.instance.share(ShareParams(text: inviteFullText));
                              },
                              child: Text(
                                AppStrings.t('share_messenger_btn'),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF10B981),
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              onPressed: () {
                                AppEngineService.launchNativeSms(
                                  bodyText: inviteFullText,
                                );
                              },
                              child: Text(
                                AppStrings.t('share_sms_btn'),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white,
                            ),
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: inviteFullText),
                              );
                              Navigator.pop(ctx);
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(
                                  backgroundColor: AppColors.primaryPurple,
                                  content: Text(AppStrings.t('code_copied')),
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.copy_rounded,
                              size: 18,
                              color: AppColors.primaryPurple,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: TextButton(
                    onPressed: () async {
                      await AppEngineService.instance
                          .deleteMyServerDataAndReset();
                      if (!mounted) return;
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(
                          backgroundColor: Colors.redAccent,
                          content: Text(AppStrings.t('delete_account_confirm')),
                        ),
                      );
                      Navigator.pushReplacement(
                        this.context,
                        MaterialPageRoute(
                          builder: (_) => const CircleInviteScreen(),
                        ),
                      );
                    },
                    child: Text(
                      AppStrings.t('delete_account_btn'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.redAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
                            Text(
                              AppStrings.t('plan_monthly_price'),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                                color: AppColors.textDark,
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
                                Text(
                                  AppStrings.t('plan_yearly_price'),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w900,
                                    color: AppColors.textDark,
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
              if (selectedMember != null &&
                  selectedMember.recentRoute.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: selectedMember.recentRoute,
                      color: Colors.white,
                      strokeWidth: 9.0,
                    ),
                    Polyline(
                      points: selectedMember.recentRoute,
                      color: AppColors.primaryPurple,
                      strokeWidth: 5.5,
                    ),
                  ],
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
            top: 86,
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
            top: 86,
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
                        Icons.share_location_rounded,
                        size: 17,
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
                  setState(() => selectedMemberId = 'm1');
                  _mapController.move(_allMembers[0].location, 15.5);
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
                      Icon(
                        Icons.timeline_rounded,
                        size: 17,
                        color: AppColors.primaryPurple,
                      ),
                      SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          AppStrings.t('my_timeline_btn'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
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
            Expanded(
              child: GestureDetector(
                onTap: _toggleDemoFamilyMode,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const PingoBrandLogo(fontSize: 14),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '• ${AppStrings.t('members_count')} (${otherMembers.length})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textGray,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
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
                      '${AppStrings.t('places_btn')} ${safePlaces.length}/${isProUser ? "∞" : "2"}',
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
        const SizedBox(height: 6),
        const Divider(color: AppColors.divider, height: 10),
        if (otherMembers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0),
            child: InkWell(
              onTap: _showMultiCircleSwitcherSheet,
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.person_add_alt_1_rounded,
                      size: 18,
                      color: AppColors.primaryPurple,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '(' + activeCircle.code + ') ' + AppStrings.t('share_circle_banner'),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDark,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.arrow_forward_ios_rounded,
                      size: 13,
                      color: AppColors.textGray,
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          ...otherMembers.map(
            (m) => InkWell(
              onTap: () => _focusMemberOnMap(m),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10.0),
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
                            width: 19,
                            height: 19,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.divider,
                                width: 1,
                              ),
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
      ],
    );
  }

  Widget _buildMemberHistoryDrillDownSheet(MemberData member) {
    final bool isMe = member.id == 'm1';

    // Life360을 뛰어넘는 듀얼 파스텔 그라데이션 이모지 퀵 노트 8종 세트
    final emojiQuickNotes = [
      {
        'key': 'q_where',
        'bg': [const Color(0xFFEDE9FE), const Color(0xFFDDD6FE)],
        'border': const Color(0xFF8B5CF6),
        'text': const Color(0xFF5B21B6),
      },
      {
        'key': 'q_otw',
        'bg': [const Color(0xFFD1FAE5), const Color(0xFFA7F3D0)],
        'border': const Color(0xFF10B981),
        'text': const Color(0xFF065F46),
      },
      {
        'key': 'q_home',
        'bg': [const Color(0xFFDBEAFE), const Color(0xFFBFDBFE)],
        'border': const Color(0xFF3B82F6),
        'text': const Color(0xFF1E40AF),
      },
      {
        'key': 'q_call',
        'bg': [const Color(0xFFFEF3C7), const Color(0xFFFDE68A)],
        'border': const Color(0xFFF59E0B),
        'text': const Color(0xFF92400E),
      },
      {
        'key': 'q_meal',
        'bg': [const Color(0xFFFFEDD5), const Color(0xFFFED7AA)],
        'border': const Color(0xFFF97316),
        'text': const Color(0xFF9A3412),
      },
      {
        'key': 'q_coffee',
        'bg': [const Color(0xFFF3E8FF), const Color(0xFFE9D5FF)],
        'border': const Color(0xFFA855F7),
        'text': const Color(0xFF6B21A8),
      },
      {
        'key': 'q_lowbat',
        'bg': [const Color(0xFFFEE2E2), const Color(0xFFFECACA)],
        'border': const Color(0xFFEF4444),
        'text': const Color(0xFF991B1B),
      },
      {
        'key': 'q_love',
        'bg': [const Color(0xFFFCE7F3), const Color(0xFFFBCFE8)],
        'border': const Color(0xFFEC4899),
        'text': const Color(0xFF9D174D),
      },
    ];

    final now = DateTime.now();
    final tNow =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final tPrev1 =
        '${now.subtract(const Duration(minutes: 45)).hour.toString().padLeft(2, '0')}:${now.subtract(const Duration(minutes: 45)).minute.toString().padLeft(2, '0')}';
    final tPrev2 =
        '${now.subtract(const Duration(hours: 2)).hour.toString().padLeft(2, '0')}:${now.subtract(const Duration(hours: 2)).minute.toString().padLeft(2, '0')}';

    double totalDistKm = 0.0;
    for (int i = 1; i < member.recentRoute.length; i++) {
      totalDistKm +=
          AppEngineService.instance.calculateDistanceMeters(
            member.recentRoute[i - 1],
            member.recentRoute[i],
          ) /
          1000.0;
    }

    final cleanAddr = member.statusText.split('•').first.trim();

    // [옵션 B] 본인('나')을 클릭했을 때: 타임라인(오늘/어제/30일) + 버블 프라이버시 모드 스위치
    if (isMe) {
      final bubbleOn = AppEngineService.instance.isBubblePrivacyActive;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 17),
                onPressed: () => setState(() => selectedMemberId = null),
              ),
              const Icon(
                Icons.timeline_rounded,
                size: 18,
                color: AppColors.primaryPurple,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  AppStrings.t('my_timeline_btn'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textDark,
                  ),
                ),
              ),
              _buildSmartMotionBadge(member),
            ],
          ),
          const SizedBox(height: 8),
          // 🫧 Life360 버블 프라이버시 모드 스위치 카드
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: bubbleOn
                    ? [const Color(0xFFEDE9FE), const Color(0xFFFCE7F3)]
                    : [const Color(0xFFF8FAFC), const Color(0xFFF1F5F9)],
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: bubbleOn
                    ? const Color(0xFF8B5CF6)
                    : const Color(0xFFE2E8F0),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppStrings.t('bubble_mode_title'),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textDark,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        bubbleOn
                            ? AppStrings.t('bubble_mode_on_desc')
                            : AppStrings.t('bubble_mode_off_desc'),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textGray,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: bubbleOn,
                  activeThumbColor: AppColors.primaryPurple,
                  onChanged: (val) {
                    HapticFeedback.selectionClick();
                    setState(() {
                      AppEngineService.instance.isBubblePrivacyActive = val;
                    });
                    AppEngineService.instance.pushLiveLocationToServer(
                      circleCode: activeCircle.code,
                      userName: _allMembers[0].name,
                      point: _allMembers[0].location,
                      battery: _allMembers[0].battery,
                      avatarUrl: _allMembers[0].avatarUrl,
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildDatePill(
                  AppStrings.t('today'),
                  _selectedHistoryDayTab == 0,
                  false,
                  () => setState(() => _selectedHistoryDayTab = 0),
                ),
                const SizedBox(width: 8),
                _buildDatePill(
                  AppStrings.t('yesterday'),
                  _selectedHistoryDayTab == 1,
                  !isProUser,
                  () => setState(() => _selectedHistoryDayTab = 1),
                ),
                const SizedBox(width: 8),
                _buildDatePill(
                  AppStrings.t('days_30'),
                  _selectedHistoryDayTab == 2,
                  !isProUser,
                  () => setState(() => _selectedHistoryDayTab = 2),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_selectedHistoryDayTab == 0) ...[
                  Row(
                    children: [
                      const Icon(
                        Icons.route_rounded,
                        size: 16,
                        color: AppColors.primaryPurple,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${AppStrings.t('today')} • ${totalDistKm.toStringAsFixed(2)} km (${member.recentRoute.length} ${AppStrings.t('route_points_unit')})',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textDark,
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else if (_selectedHistoryDayTab == 1) ...[
                  Text(
                    '${AppStrings.t('yesterday')} • ${AppStrings.t('history_yesterday_sub')}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark,
                    ),
                  ),
                ] else ...[
                  Text(
                    '${AppStrings.t('days_30')} • ${AppStrings.t('history_30days_sub')}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }

    // 상대방(가족/친구)을 클릭했을 때: [📞 전화] [💬 문자] [🧭 길찾기] + 파스텔 그라데이션 이모지 8종 가로 스크롤 바
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 17,
                    ),
                    onPressed: () => setState(() => selectedMemberId = null),
                  ),
                  _buildMemberAvatarImage(member, size: 32),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      member.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textDark,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 📞 스마트폰 기본 전화 직통 버튼
                InkWell(
                  onTap: () => _handleMemberPhoneAction(
                    member: member,
                    isCall: true,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD1FAE5),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFF10B981)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.call_rounded,
                          size: 14,
                          color: Color(0xFF047857),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          AppStrings.t('call_btn'),
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF047857),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // 💬 스마트폰 기본 문자 직통 버튼
                InkWell(
                  onTap: () => _handleMemberPhoneAction(
                    member: member,
                    isCall: false,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDBEAFE),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFF3B82F6)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.sms_rounded,
                          size: 14,
                          color: Color(0xFF1D4ED8),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          AppStrings.t('sms_btn'),
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1D4ED8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // 🧭 내비게이션 길찾기 버튼
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryPurple,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  onPressed: () {
                    AppEngineService.openRealMapNavigation(
                      dest: member.location,
                      addressHint: member.statusText,
                    );
                  },
                  icon: const Icon(Icons.directions_rounded, size: 14),
                  label: Text(
                    AppStrings.t('directions_btn'),
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        // ✨ Life360을 뛰어넘는 좌우 스크롤 파스텔 그라데이션 이모지 퀵 노트 8종 바
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: emojiQuickNotes.map((item) {
              final String key = item['key'] as String;
              final bgList = item['bg'] as List;
              final bgColors = [bgList[0] as Color, bgList[1] as Color];
              final Color borderColor = item['border'] as Color;
              final Color textColor = item['text'] as Color;
              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: InkWell(
                  onTap: () => _sendQuickPingToMember(member, key),
                  borderRadius: BorderRadius.circular(22),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: bgColors,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: borderColor.withValues(alpha: 0.55),
                        width: 1.3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: borderColor.withValues(alpha: 0.16),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      AppStrings.t(key),
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: textColor,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildDatePill(
                AppStrings.t('today'),
                _selectedHistoryDayTab == 0,
                false,
                () => setState(() => _selectedHistoryDayTab = 0),
              ),
              const SizedBox(width: 8),
              _buildDatePill(
                AppStrings.t('yesterday'),
                _selectedHistoryDayTab == 1,
                !isProUser,
                () => setState(() => _selectedHistoryDayTab = 1),
              ),
              const SizedBox(width: 8),
              _buildDatePill(
                AppStrings.t('days_30'),
                _selectedHistoryDayTab == 2,
                !isProUser,
                () => setState(() => _selectedHistoryDayTab = 2),
              ),
              const SizedBox(width: 10),
              _buildSmartMotionBadge(member),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.place_rounded,
                    size: 16,
                    color: AppColors.primaryPurple,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$tNow • $cleanAddr',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textDark,
                      ),
                    ),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.only(left: 7, top: 2, bottom: 2),
                child: SizedBox(
                  height: 10,
                  child: VerticalDivider(
                    width: 2,
                    thickness: 1.5,
                    color: Color(0xFFCBD5E1),
                  ),
                ),
              ),
              Row(
                children: [
                  const Icon(
                    Icons.directions_walk_rounded,
                    size: 15,
                    color: AppColors.safeGreenText,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      member.recentRoute.length > 1
                          ? '$tPrev1 ~ $tNow • ${totalDistKm.toStringAsFixed(2)}km (${member.speedKmh.toStringAsFixed(1)}km/h)'
                          : '$tPrev2 ~ $tNow • ${AppStrings.t('status_staying')}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textGray,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
  Widget _buildDatePill(
    String label,
    bool active,
    bool locked,
    VoidCallback onTapUnlocked,
  ) {
    return GestureDetector(
      onTap: locked ? _showProPaywallSheet : onTapUnlocked,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppColors.primaryPurple : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: active ? Colors.white : AppColors.textGray,
              ),
            ),
            if (locked) ...[
              const SizedBox(width: 4),
              const Icon(
                Icons.lock_outline_rounded,
                size: 12,
                color: AppColors.textGray,
              ),
            ],
          ],
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
