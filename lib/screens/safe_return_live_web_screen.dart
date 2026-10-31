import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../core/app_theme_and_strings.dart';
import '../services/app_engine_service.dart';

class SafeReturnLiveWebScreen extends StatefulWidget {
  final String sharerName;
  final String shareToken;
  final LatLng startLocation;
  final int initialBattery;

  const SafeReturnLiveWebScreen({
    super.key,
    required this.sharerName,
    required this.shareToken,
    required this.startLocation,
    required this.initialBattery,
  });

  @override
  State<SafeReturnLiveWebScreen> createState() =>
      _SafeReturnLiveWebScreenState();
}

class _SafeReturnLiveWebScreenState extends State<SafeReturnLiveWebScreen> {
  final MapController _webMapController = MapController();
  Timer? _countdownTimer;
  StreamSubscription<Position>? _realGpsSub;

  int _remainingSeconds = 1800;
  late int _batteryLevel;
  bool _isLastWillPinned = false;
  bool _isArrived = false;
  late String _currentRoadAddress;

  List<LatLng> _walkedBreadcrumbs = [];
  late LatLng _currentPos;
  late LatLng _startOriginPos;
  double _currentSpeedKmh = 0.0;

  @override
  void initState() {
    super.initState();
    _currentRoadAddress = AppStrings.t('syncing_address');
    _batteryLevel = widget.initialBattery;
    _currentPos = widget.startLocation;
    _startOriginPos = widget.startLocation;
    _walkedBreadcrumbs = [_currentPos];

    _initRealRoadAddressAndLiveGps();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_remainingSeconds > 0 && !_isArrived) {
        setState(() => _remainingSeconds--);
      }
    });
  }

  Future<void> _initRealRoadAddressAndLiveGps() async {
    final addr = await AppEngineService.instance.fetchRoadAddress(
      _currentPos,
      forceLookup: true,
    );
    if (mounted) {
      setState(() => _currentRoadAddress = addr);
    }

    try {
      _realGpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
        ),
      ).listen((Position pos) async {
        if (!mounted || _isArrived || _isLastWillPinned) return;
        if (pos.accuracy > 65.0) return;

        final nextPt = LatLng(pos.latitude, pos.longitude);
        final moved = AppEngineService.instance.calculateDistanceMeters(
          _currentPos,
          nextPt,
        );
        final spd = (pos.speed * 3.6).clamp(0.0, 180.0);

        setState(() {
          _currentPos = nextPt;
          _currentSpeedKmh = spd;
          if (moved >= 4.0) {
            _walkedBreadcrumbs.add(nextPt);
          }
        });

        _webMapController.move(nextPt, _webMapController.camera.zoom);
        final updatedAddr = await AppEngineService.instance.fetchRoadAddress(
          nextPt,
          speedKmh: spd,
        );
        if (mounted) {
          setState(() => _currentRoadAddress = updatedAddr);
        }
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _realGpsSub?.cancel();
    super.dispose();
  }

  String _formatCountdown(int totalSeconds) {
    final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _triggerLastWillBatteryTest() {
    HapticFeedback.heavyImpact();
    setState(() {
      _batteryLevel = 2;
      _isLastWillPinned = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    double movedMeters = 0;
    for (int i = 1; i < _walkedBreadcrumbs.length; i++) {
      movedMeters += AppEngineService.instance.calculateDistanceMeters(
        _walkedBreadcrumbs[i - 1],
        _walkedBreadcrumbs[i],
      );
    }

    return Scaffold(
      backgroundColor: AppColors.cardWhite,
      appBar: AppBar(
        backgroundColor: AppColors.textDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            const Icon(
              Icons.lock_rounded,
              size: 15,
              color: AppColors.safeGreenText,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'jeong-giseong.github.io/pingo-live.html?circle=${widget.shareToken}',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                  color: Colors.white70,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _isArrived ? AppColors.safeGreenText : Colors.redAccent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.fiber_manual_record,
                  size: 10,
                  color: Colors.white,
                ),
                const SizedBox(width: 4),
                Text(
                  _isArrived ? '귀가 완료' : _formatCountdown(_remainingSeconds),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _webMapController,
            options: MapOptions(initialCenter: _currentPos, initialZoom: 16.0),
            children: [
              TileLayer(
                urlTemplate: AppConfig.buildLocalizedMapTileUrl(0),
                userAgentPackageName: 'com.pingo.app',
              ),
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: _currentPos,
                    radius: 45,
                    useRadiusInMeter: true,
                    color: AppColors.geofenceFill,
                    borderColor: AppColors.primaryPurple,
                    borderStrokeWidth: 2,
                  ),
                ],
              ),
              if (_walkedBreadcrumbs.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _walkedBreadcrumbs,
                      color: Colors.white,
                      strokeWidth: 9.0,
                    ),
                    Polyline(
                      points: _walkedBreadcrumbs,
                      color: _isLastWillPinned
                          ? Colors.redAccent
                          : AppColors.primaryPurple,
                      strokeWidth: 5.5,
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: _startOriginPos,
                    width: 90,
                    height: 32,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.textDark.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Text(
                          '🚩 출발 위치',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Marker(
                    point: _currentPos,
                    width: 130,
                    height: 98,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: _isLastWillPinned
                                ? Colors.redAccent
                                : AppColors.cardWhite,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: const [
                              BoxShadow(color: Colors.black26, blurRadius: 4),
                            ],
                          ),
                          child: Text(
                            _isLastWillPinned
                                ? '🪫 $_batteryLevel% (마지막 위치 고정)'
                                : '⚡ $_batteryLevel% • ${_currentSpeedKmh.toStringAsFixed(0)}km/h',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              color: _isLastWillPinned
                                  ? Colors.white
                                  : AppColors.safeGreenText,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _isLastWillPinned
                                ? Colors.redAccent
                                : AppColors.primaryPurple,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: const [
                              BoxShadow(color: Colors.black26, blurRadius: 8),
                            ],
                          ),
                          child: Center(
                            child: Text(
                              widget.sharerName.length >= 2
                                  ? widget.sharerName.substring(
                                      widget.sharerName.length - 2,
                                    )
                                  : widget.sharerName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.cardWhite.withValues(alpha: 0.96),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(color: Colors.black12, blurRadius: 12),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _isArrived
                              ? AppColors.safeGreenBg
                              : AppColors.lightPurpleBg,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isArrived
                              ? Icons.check_circle_rounded
                              : Icons.sensors_rounded,
                          color: _isArrived
                              ? AppColors.safeGreenText
                              : AppColors.primaryPurple,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _isArrived
                                  ? '🎉 ${widget.sharerName}님이 안전하게 귀가 완료했습니다!'
                                  : '${widget.sharerName} • 실시간 귀갓길 위치 공유 중',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14.5,
                                color: AppColors.textDark,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '📍 현재 위치: $_currentRoadAddress (실시간 이동 ${movedMeters.round()}m)',
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
                ),
                if (_isLastWillPinned) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.redAccent, width: 1.5),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.battery_alert_rounded,
                          color: Colors.redAccent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            AppStrings.t('web_last_will_alert'),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.redAccent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            side: const BorderSide(color: Colors.redAccent),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: _triggerLastWillBatteryTest,
                          icon: const Icon(
                            Icons.battery_0_bar_rounded,
                            size: 18,
                          ),
                          label: const Text(
                            '배터리 2% 핀 고정 테스트',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isArrived
                                ? AppColors.safeGreenText
                                : AppColors.primaryPurple,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: () {
                            HapticFeedback.mediumImpact();
                            setState(() => _isArrived = true);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                backgroundColor: AppColors.safeGreenText,
                                content: Text('✅ 안전 귀가 완료 상태가 가족에게 공유되었습니다.'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.home_rounded, size: 17),
                          label: Text(
                            _isArrived ? '귀가 완료됨' : '안전 귀가 완료 알림',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}