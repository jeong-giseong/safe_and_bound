import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
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
  Timer? _walkTimer;

  int _remainingSeconds = 1800;
  int _currentStep = 0;
  late int _batteryLevel;
  bool _isLastWillPinned = false;
  bool _isArrived = false;
  late String _currentRoadAddress;

  List<LatLng> _homewardRoute = [];
  late LatLng _currentPos;
  late LatLng _destPos;

  @override
  void initState() {
    super.initState();
    _currentRoadAddress = AppStrings.t('syncing_address');
    _batteryLevel = widget.initialBattery;
    _currentPos = widget.startLocation;
    _destPos = LatLng(
      widget.startLocation.latitude + 0.0052,
      widget.startLocation.longitude + 0.0040,
    );
    _homewardRoute = [_currentPos, _destPos];

    _initRealRoadRouteAndAddress();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_remainingSeconds > 0 && !_isArrived) {
        setState(() => _remainingSeconds--);
      }
    });
  }

  Future<void> _initRealRoadRouteAndAddress() async {
    final roadPoints = await AppEngineService.instance.fetchRoadSnappedRoute(
      _currentPos,
      _destPos,
      
    );
    final addr = await AppEngineService.instance.fetchRoadAddress(_currentPos);

    if (!mounted) return;
    setState(() {
      _homewardRoute = roadPoints;
      _currentRoadAddress = addr;
    });

    _walkTimer = Timer.periodic(const Duration(milliseconds: 900), (t) {
      if (!mounted || _isLastWillPinned || _isArrived) return;
      if (_currentStep < _homewardRoute.length - 1) {
        setState(() {
          _currentStep++;
          _currentPos = _homewardRoute[_currentStep];
        });
      } else {
        setState(() => _isArrived = true);
        t.cancel();
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _walkTimer?.cancel();
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
    final remainingMeters = AppEngineService.instance
        .calculateDistanceMeters(_currentPos, _destPos)
        .round();

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
                'pingo.pages.dev/live/${widget.shareToken}',
                style: const TextStyle(
                  fontSize: 13,
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
              color: Colors.redAccent,
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
                  _formatCountdown(_remainingSeconds),
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
            options: MapOptions(initialCenter: _currentPos, initialZoom: 15.3),
            children: [
              TileLayer(
                urlTemplate: AppConfig.buildLocalizedMapTileUrl(0),
                userAgentPackageName: 'com.pingo.app',
              ),
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: _destPos,
                    radius: 140,
                    useRadiusInMeter: true,
                    color: AppColors.geofenceFill,
                    borderColor: AppColors.primaryPurple,
                    borderStrokeWidth: 2,
                  ),
                ],
              ),
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _homewardRoute,
                    color: AppColors.primaryPurple.withValues(alpha: 0.28),
                    strokeWidth: 6.0,
                  ),
                  Polyline(
                    points: _homewardRoute.sublist(
                      0,
                      (_currentStep + 1).clamp(1, _homewardRoute.length),
                    ),
                    color: Colors.white,
                    strokeWidth: 9.0,
                  ),
                  Polyline(
                    points: _homewardRoute.sublist(
                      0,
                      (_currentStep + 1).clamp(1, _homewardRoute.length),
                    ),
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
                    point: _destPos,
                    width: 120,
                    height: 36,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primaryPurple,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child: Text(
                          AppStrings.t('dest_home'),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Marker(
                    point: _currentPos,
                    width: 125,
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
                                ? '🪫 $_batteryLevel% (${AppStrings.t('last_will_pin')})'
                                : '⚡ $_batteryLevel%',
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
                                  ? '🎉 ${widget.sharerName} ${AppStrings.t('web_arrived_msg')}'
                                  : '${widget.sharerName} • ${AppStrings.t('web_live_badge')}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: AppColors.textDark,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '📍 $_currentRoadAddress • ${AppStrings.t('web_remaining_dist')} ${remainingMeters}m',
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
                          label: Text(
                            AppStrings.t('web_test_low_bat'),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primaryPurple,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                backgroundColor: AppColors.primaryPurple,
                                content: Text(
                                  '❤️ ${widget.sharerName} ${AppStrings.t('web_cheer_sent')}',
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.favorite_rounded, size: 16),
                          label: Text(
                            AppStrings.t('web_ping_cheer'),
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

