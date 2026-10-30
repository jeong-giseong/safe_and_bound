import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/app_theme_and_strings.dart';
import 'services/app_engine_service.dart';
import 'screens/circle_onboarding_screen.dart';
import 'screens/safe_return_live_web_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppStrings.initFromSystemLocale();

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  await AppEngineService.instance.ensureAnonymousSession();

  runApp(const PingoApp());
}

class PingoApp extends StatelessWidget {
  const PingoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final uri = Uri.base;
    String? liveToken;
    if (uri.pathSegments.length >= 2 && uri.pathSegments[0] == 'live') {
      liveToken = uri.pathSegments[1];
    } else if (uri.queryParameters.containsKey('live')) {
      liveToken = uri.queryParameters['live'];
    }

    return MaterialApp(
      title: AppStrings.t('app_title'),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: AppColors.cardWhite,
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.primaryPurple),
        useMaterial3: true,
      ),
      home: liveToken != null && liveToken.isNotEmpty
          ? SafeReturnLiveWebScreen(
              sharerName: AppStrings.t('default_sharer_name'),
              shareToken: liveToken,
              startLocation: const LatLng(37.7599, 126.7802),
              initialBattery: 92,
            )
          : const CircleInviteScreen(),
    );
  }
}

