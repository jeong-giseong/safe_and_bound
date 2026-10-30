import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

class CircleInfo {
  final String name;
  final String code;
  final String myRole;

  CircleInfo({required this.name, required this.code, required this.myRole});
}

class MemberData {
  final String id;
  String name;
  String monogram;
  String avatarUrl;
  final List<Color> gradient;
  IconData statusIcon;
  String statusText;
  int battery;
  double speedKmh; // 🚗 실시간 속도 (km/h) 기반 스마트 배지 표시용
  LatLng location;
  List<LatLng> recentRoute;

  MemberData({
    required this.id,
    required this.name,
    required this.monogram,
    required this.avatarUrl,
    required this.gradient,
    required this.statusIcon,
    required this.statusText,
    required this.battery,
    this.speedKmh = 0.0,
    required this.location,
    required this.recentRoute,
  });
}

class SafePlaceData {
  final String id;
  final String name;
  final IconData iconData;
  final LatLng point;
  final double radiusMeters;

  SafePlaceData({
    required this.id,
    required this.name,
    required this.iconData,
    required this.point,
    required this.radiusMeters,
  });
}

