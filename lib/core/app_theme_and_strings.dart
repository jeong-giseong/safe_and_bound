import 'dart:ui' as ui;

import 'package:flutter/material.dart';

typedef LangDict = Map<String, String>;

class AppConfig {
  static const Color primaryPurple = Color(0xFF6C47FF);

  static const String supabaseUrl = 'https://wgonnoaoputcwuewhnzl.supabase.co';
  static const String supabaseAnonKey =
      'sb_publishable_TmbmuSQBaJ6ScfcOEKRbEQ_i7Lh76KH';
  static const String mapboxToken =
      'pk.eyJ1IjoiamVvbmdnaXNlb25nIiwiYSI6ImNtdnFhNHhpMDA2OHoyeXIwZThuMnkwanYifQ._Zouj-a9d2NaLWCVyRKwiQ';
  static const String mapboxStyleId = 'mapbox/streets-v12';

  static const String termsOfUseUrl =
      'https://jeong-giseong.github.io/safebound-legal/?tab=terms';
  static const String privacyPolicyUrl =
      'https://jeong-giseong.github.io/safebound-legal/?tab=privacy';
  static const String supportEmail = 'jeonggiseong73@gmail.com';

  static String buildLocalizedMapTileUrl(int styleIndex) {
    final lang = AppStrings.lang;
    if (styleIndex == 1) {
      return 'https://api.mapbox.com/styles/v1/mapbox/dark-v11/tiles/256/{z}/{x}/{y}@2x?access_token=$mapboxToken&language=$lang';
    } else if (styleIndex == 2) {
      return 'https://api.mapbox.com/styles/v1/mapbox/satellite-streets-v12/tiles/256/{z}/{x}/{y}@2x?access_token=$mapboxToken&language=$lang';
    }
    return 'https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}&hl=$lang';
  }
}

class AppColors {
  static const Color primaryPurple = Color(0xFF6C47FF);
  static const Color accentPink = Color(0xFFEC4899);
  static const Color lightPurpleBg = Color(0xFFF5F3FF);
  static const Color geofenceFill = Color(0x246C47FF);
  static const Color cardWhite = Color(0xFFFFFFFF);
  static const Color textDark = Color(0xFF111827);
  static const Color textGray = Color(0xFF6B7280);
  static const Color divider = Color(0xFFF2F4F7);
  static const Color safeGreenBg = Color(0xFFE8F8F0);
  static const Color safeGreenText = Color(0xFF12B76A);
  static const Color driveBlueBg = Color(0xFFEFF6FF);
  static const Color driveBlueText = Color(0xFF2563EB);
}

class PingoAvatars {
  static const List<LangDict> presets = [
    {
      'id': 'toon_1',
      'styleKey': 'style_webtoon',
      'url': 'https://api.dicebear.com/9.x/adventurer/png?seed=Felix&size=256&backgroundColor=b6e3f4',
    },
    {
      'id': 'toon_2',
      'styleKey': 'style_webtoon',
      'url': 'https://api.dicebear.com/9.x/adventurer/png?seed=Aneka&size=256&backgroundColor=ffdfbf',
    },
    {
      'id': 'toon_3',
      'styleKey': 'style_webtoon',
      'url': 'https://api.dicebear.com/9.x/lorelei/png?seed=Milo&size=256&backgroundColor=c0aede',
    },
    {
      'id': 'toon_4',
      'styleKey': 'style_webtoon',
      'url': 'https://api.dicebear.com/9.x/lorelei/png?seed=Aria&size=256&backgroundColor=ffd5dc',
    },
    {
      'id': '3d_1',
      'styleKey': 'style_3d',
      'url': 'https://api.dicebear.com/9.x/big-smile/png?seed=Lucas&size=256&backgroundColor=d1d4f9',
    },
    {
      'id': '3d_2',
      'styleKey': 'style_3d',
      'url': 'https://api.dicebear.com/9.x/big-smile/png?seed=Chloe&size=256&backgroundColor=ffd5dc',
    },
    {
      'id': '3d_3',
      'styleKey': 'style_3d',
      'url': 'https://api.dicebear.com/9.x/big-smile/png?seed=Leo&size=256&backgroundColor=b6e3f4',
    },
    {
      'id': '3d_4',
      'styleKey': 'style_3d',
      'url': 'https://api.dicebear.com/9.x/big-smile/png?seed=Sofia&size=256&backgroundColor=ffdfbf',
    },
    {
      'id': 'cute_1',
      'styleKey': 'style_cute',
      'url': 'https://api.dicebear.com/9.x/open-peeps/png?seed=Yul&size=256&backgroundColor=c0aede',
    },
    {
      'id': 'cute_2',
      'styleKey': 'style_cute',
      'url': 'https://api.dicebear.com/9.x/open-peeps/png?seed=Narae&size=256&backgroundColor=ffd5dc',
    },
    {
      'id': 'fun_1',
      'styleKey': 'style_mascot',
      'url': 'https://api.dicebear.com/9.x/fun-emoji/png?seed=Captain&size=256&backgroundColor=b6e3f4',
    },
    {
      'id': 'fun_2',
      'styleKey': 'style_mascot',
      'url': 'https://api.dicebear.com/9.x/fun-emoji/png?seed=Star&size=256&backgroundColor=ffdfbf',
    },
  ];
}

class PingoBrandLogo extends StatelessWidget {
  final double fontSize;
  const PingoBrandLogo({super.key, this.fontSize = 22});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: fontSize + 8,
          height: fontSize + 8,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF6C47FF), Color(0xFFEC4899)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryPurple.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(
            Icons.location_on_rounded,
            color: Colors.white,
            size: fontSize * 0.82,
          ),
        ),
        const SizedBox(width: 8),
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFF5B34FF), Color(0xFFD946EF)],
          ).createShader(bounds),
          child: Text(
            'Pingo',
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              letterSpacing: -0.6,
            ),
          ),
        ),
        const SizedBox(width: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: AppColors.lightPurpleBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppColors.primaryPurple.withValues(alpha: 0.25),
            ),
          ),
          child: const Text(
            'LIVE',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w900,
              color: AppColors.primaryPurple,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }
}

class AppStrings {
  static String lang = 'ko';

  static final List<LangDict> supportedLanguages = [
    {'code': 'ko', 'name': '한국어'},
    {'code': 'en', 'name': 'English'},
    {'code': 'ja', 'name': '日本語'},
    {'code': 'zh', 'name': '繁體中文'},
    {'code': 'vi', 'name': 'Tiếng Việt'},
    {'code': 'th', 'name': 'ภาษาไทย'},
  ];

  static void initFromSystemLocale() {
    final sysCode = ui.PlatformDispatcher.instance.locale.languageCode
        .toLowerCase();
    final isSupported = supportedLanguages.any(
      (item) => item['code'] == sysCode,
    );
    lang = isSupported ? sysCode : 'ko';
  }

  static const LangDict _ko = {
    'app_title': 'Pingo',
    'circle_title': 'Pingo 시작하기',
    'circle_sub': '소중한 사람들과 실시간 위치를 안전하게 공유하세요',
    'my_name_label': '내 닉네임',
    'my_name_hint': '닉네임 입력 (예: 엄마, 민준)',
    'my_phone_hint': '내 전화번호 입력 (가족 간 바로 통화·문자 연결용)',
    'name_required_toast': '닉네임을 입력해 주세요',
    'choose_avatar_btn': '아바타 변경',
    'avatar_sheet_title': '아바타 선택',
    'avatar_picker_title': '프로필 아바타 또는 사진 선택',
    'upload_my_photo': '📷 앨범에서 내 사진 선택',
    'pick_photo_gallery': '앨범에서 선택',
    'pick_photo_camera': '카메라 촬영',
    'or_select_character': '또는 기본 캐릭터 선택',
    'style_webtoon': '웹툰',
    'style_3d': '3D',
    'style_cute': '일러스트',
    'style_mascot': '마스코트',
    'join_with_code': '초대 코드로 합류',
    'create_new_circle': '새 서클 만들기',
    'choose_circle_name': '서클 이름 설정',
    'circle_name': '우리 가족',
    'preset_family': '우리 가족',
    'preset_couple': '커플',
    'preset_parents': '부모님',
    'preset_trip': '여행 모임',
    'enter_invite_code': '6자리 초대 코드 입력',
    'enter_invite_sub': '가족이나 친구에게 받은 6자리 숫자를 입력하세요',
    'complete_join': '서클 합류하기',
    'finish_open_map': '지도 열기 및 시작하기',
    'share_code_btn': '초대 코드 공유하기',
    'share_code_48h': '초대 코드로 가족과 친구가 즉시 합류할 수 있습니다',
    'regenerate_code': '코드 재발급',
    'code_copied': '초대 코드가 복사되었습니다',
    'copy_link': '링크 복사',
    'join_confirm_q': '서클에 합류하시겠습니까?',
    'me_default': '나',
    'default_member_name': '가족 멤버',
    'default_sharer_name': '가족 멤버',
    'default_school': '안심 학교/직장',
    'demo_member_1': '민준 (체험 파트너)',
    'demo_member_2': '서연 (체험 파트너)',
    'demo_chip_on': '체험 모드 켜짐',
    'demo_chip_off': '체험 모드 끄기',
    'demo_member_notice_toast': '체험용 파트너입니다. 초대 코드로 실제 가족을 초대해 보세요!',
    'demo_nav_unsupported': '체험용 파트너는 실제 길찾기를 지원하지 않습니다.',
    'current_members': '서클 멤버',
    'members_count': '명 함께하는 중',
    'role_owner': '서클장',
    'role_member': '멤버',
    'just_now': '방금 전',
    'syncing_address': '도로명 주소 확인 중...',
    'filter_moving': '이동 중',
    'Filter_Moving': '이동 중',
    'status_staying': '현재 위치 체류 중',
    'status_walking': '도보 이동 중',
    'inside_safe_zone': '안심 구역 내',
    'safe_zone_in': '안심 구역 내',
    'places_btn': '안심장소',
    'manage_places_title': '안심 장소 알림 (Geofence) 관리',
    'add_new_place': '지도에서 새 안심 장소 추가',
    'add_unlimited_pro': '무제한 장소 추가 (Pro)',
    'free_limit': '무료 최대 2곳',
    'pro_unlimited': 'Pro 무제한',
    'pick_place_title': '지도를 움직여 안심 장소 위치를 지정하세요',
    'place_name_hint': '장소 이름 입력 (예: 집, 초등학교, 회사)',
    'radius_label': '알림 반경',
    'radius_alert_on': '진입·이탈 시 서클 자동 알림 켜짐',
    'save_place_btn': '이 위치에 안심 장소 저장',
    'place_arrived_alert': '📍 {PLACE} 안심 존에 도착했습니다',
    'place_left_alert': '🚶 {PLACE} 안심 존에서 출발했습니다',
    'checkin_bubble': '안심 체크인',
    'checkin_toast': '서클 멤버들에게 안심 도착 체크인을 보냈습니다',
    'safe_share': '실시간 귀가 공유',
    'safe_share_sub': '앱이 없는 지인에게도 웹 링크로 실시간 귀가 동선을 공유합니다',
    'preview_web_screen': '귀가 웹 화면 미리보기',
    'web_live_badge': '실시간 귀갓길 보호 작동 중',
    'web_arrived_msg': '목적지에 안전하게 도착했습니다!',
    'web_remaining_dist': '이동 거리',
    'web_last_will_alert': '배터리 잔량이 극소량(2%)입니다. 마지막 위치가 자동 고정 보존됩니다.',
    'web_test_low_bat': '배터리 2% 마지막 위치 고정 테스트',
    'web_ping_cheer': '응원 하트 보내기',
    'web_cheer_sent': '안심 귀가 응원 신호를 보냈습니다!',
    'dest_home': '🏠 안심 귀가 목적지',
    'sos_btn_label': 'SOS',
    'sos_silent_badge': '무음 긴급 구조 요청 (Silent SOS)',
    'sos_desc': '위급 상황 시 소리 없이 서클 멤버 전원에게 현재 위치와 구조 신호를 즉시 발송합니다.',
    'sos_waiting': '초 후 자동 발송 (취소하려면 아래 버튼을 누르세요)',
    'sos_pin_hint': '긴급 알림 즉시 전송',
    'sos_cancel': 'SOS 발송 취소 및 해제',
    'sos_sent_toast': '🚨 서클 전원에게 긴급 SOS 위치 신호를 발송했습니다!',
    'sos_cleared_toast': '✅ SOS 긴급 구조 요청이 해제되었습니다.',
    'sos_active_banner': 'SOS 위급 신호 발령 중! 즉시 위치를 확인하세요.',
    'sos_Active_banner': 'SOS 위급 신호 발령 중! 즉시 위치를 확인하세요.',
    'circle_switch_title': '내 프로필 & 서클 초대 관리',
    'circle_add_join': '새 서클 추가/합류',
    'edit_my_profile_title': '내 프로필 및 전화번호 설정',
    'save_profile_btn': '저장',
    'profile_saved_toast': '프로필과 전화번호가 저장되었습니다.',
    'invite_code_label': '초대 코드',
    'share_circle_banner': '서클 초대 코드 복사 및 가족 초대하기',
    'share_messenger_btn': '카카오톡 · 메신저로 초대장 공유',
    'share_sms_btn': '문자로 초대장 전송',
    'invite_auto_msg': '📍 [Pingo] 실시간 위치 공유 서클에 초대합니다!\n초대 코드: [{CODE}]\n앱에서 초대 코드를 입력해 지금 바로 합류하세요!',
    'call_btn': '전화',
    'sms_btn': '문자',
    'directions_btn': '길찾기',
    'navigate_btn': '길찾기',
    'phone_input_title': '전화번호 등록 및 바로 연결',
    'phone_input_hint': '상대방 전화번호 입력 (예: 010-1234-5678)',
    'phone_save_call': '번호 저장 후 바로 연결하기',
    'my_timeline_btn': '내 이동 타임라인 & 프라이버시',
    'bubble_mode_title': '🫧 버블 프라이버시 모드 (반경 500m 보호)',
    'bubble_mode_on_desc': '현재 상세 주소 대신 반경 500m 대략적 위치만 서클에 표시됩니다.',
    'bubble_mode_off_desc': '현재 정확한 실시간 위치와 도로명 주소가 서클에 공유됩니다.',
    'bubble_masked_addr': '🫧 버블 프라이버시 보호 중 (반경 500m 대략적 위치)',
    'today': '오늘',
    'yesterday': '어제',
    'days_30': '30일 기록',
    'route_points_unit': '개 지점',
    'route_point_unit': '개 지점',
    'timeline_empty_yesterday': '어제 기록된 이동 경로가 없습니다 (오늘부터 자동 기록됩니다)',
    'timeline_points_label': '경유 지점',
    'timeline_max_speed': '최고 속도',
    'timeline_total_dist': '총 이동 거리',
    'pro_30d_tease_title': '👑 최근 30일 누적 타임라인 & 방문 기록',
    'pro_30d_tease_desc':
        'Pingo Pro로 업그레이드하고 나와 가족의 최근 30일 전체 이동 동선과 체류 기록을 제한 없이 확인하세요.',
    'pro_unlock_btn': '👑 Pro 패스로 30일 전체 기록 잠금 해제',
    'q_where': '👋 지금 어디야?',
    'q_otw': '🏃 지금 가는 중!',
    'q_home': '🏠 집 도착했어',
    'q_call': '📞 전화 좀 해줘',
    'q_meal': '🍚 밥 챙겨 먹었어?',
    'q_coffee': '☕ 커피 한잔할래?',
    'q_lowbat': '🪫 배터리 얼마 없어',
    'q_love': '❤️ 사랑해!',
    'reply_otw': '🏃 가는 중이라고 답장',
    'pro_badge_btn': 'PRO 업그레이드',
    'pro_active_badge': 'PRO 이용중',
    'pro_header_badge': 'PINGO PRO PASS',
    'upgrade_pro': 'Pingo Pro 프리미엄 패스',
    'pro_feat_1_title': '최근 30일 이동 타임라인 무제한 열람',
    'pro_feat_1_sub': '나와 가족의 오늘·어제·최근 30일 전체 이동 경로와 방문 기록 확인',
    'pro_feat_2_title': '안심 장소(Geofence) 무제한 등록',
    'pro_feat_2_sub': '집·학교·학원·직장 등 개수 제한 없이 자동 출입 알림 설정',
    'plan_yearly_title': '연간 패스 (가장 인기가 많아요)',
    'plan_yearly_price': '₩29,000 / 년 (월 ₩2,400 수준)',
    'plan_monthly_title': '월간 패스',
    'plan_monthly_price': '₩3,900 / 월',
    'plan_best_badge': 'BEST 38% 할인',
    'pro_start_btn': '👑 Pingo Pro 지금 시작하기',
    'pro_activated_toast': '🎉 Pingo Pro 모든 프리미엄 기능이 활성화되었습니다!',
    'restore_purchases': '기존 구매 내역 복원',
    'restore_toast': '구매 내역 확인이 완료되었습니다.',
    'sub_auto_renew_notice':
        '구독은 언제든 스토어 설정에서 해지할 수 있으며, 해지하지 않으면 기간 종료 시 자동 갱신됩니다.',
    'terms_eula': '이용약관 (EULA)',
    'privacy_policy': '개인정보처리방침',
    'delete_account_btn': '내 위치 데이터 및 계정 즉시 삭제',
    'delete_account_confirm': '서버에 저장된 내 위치 기록을 즉시 영구 삭제하고 초기화합니다.',
    'loc_disclosure_title': '실시간 위치 공유 및 안심 존 안내',
    'loc_disclosure_body':
        'Pingo는 가족 간 실시간 위치 공유, 이동 타임라인 기록, 안심 장소 출입 알림을 위해 위치 권한을 사용합니다.',
    'loc_disclosure_agree': '동의 및 위치 공유 시작',
  };

  static const LangDict _en = {
    'app_title': 'Pingo',
    'circle_title': 'Welcome to Pingo',
    'circle_sub': 'Share live locations safely with your loved ones',
    'my_name_label': 'My Nickname',
    'my_name_hint': 'Enter nickname (e.g. Mom, Alex)',
    'my_phone_hint': 'My phone number (for quick family call/SMS)',
    'name_required_toast': 'Please enter your nickname',
    'choose_avatar_btn': 'Change Avatar',
    'avatar_sheet_title': 'Choose Avatar',
    'avatar_picker_title': 'Select Avatar or Photo',
    'upload_my_photo': '📷 Choose from Gallery',
    'pick_photo_gallery': 'Gallery',
    'pick_photo_camera': 'Camera',
    'or_select_character': 'Or pick a character',
    'style_webtoon': 'Toon',
    'style_3d': '3D',
    'style_cute': 'Cute',
    'style_mascot': 'Mascot',
    'join_with_code': 'Join with Code',
    'create_new_circle': 'Create New Circle',
    'choose_circle_name': 'Circle Name',
    'circle_name': 'My Family',
    'preset_family': 'Family',
    'preset_couple': 'Couple',
    'preset_parents': 'Parents',
    'preset_trip': 'Trip',
    'enter_invite_code': 'Enter 6-Digit Invite Code',
    'enter_invite_sub': 'Enter the 6-digit code shared by your family',
    'complete_join': 'Join Circle',
    'finish_open_map': 'Open Map & Start',
    'share_code_btn': 'Share Invite Code',
    'share_code_48h': 'Family members can join instantly with this code',
    'regenerate_code': 'New Code',
    'code_copied': 'Invite code copied',
    'copy_link': 'Copy',
    'join_confirm_q': 'Join this circle?',
    'me_default': 'Me',
    'default_member_name': 'Member',
    'default_sharer_name': 'Member',
    'default_school': 'Safe Place',
    'demo_member_1': 'Alex (Demo)',
    'demo_member_2': 'Chloe (Demo)',
    'demo_chip_on': 'Demo On',
    'demo_chip_off': 'Demo Off',
    'demo_member_notice_toast':
        'Demo partner. Share your invite code to add family!',
    'demo_nav_unsupported': 'Directions not available for demo partner.',
    'current_members': 'Members',
    'members_count': 'active',
    'role_owner': 'Owner',
    'role_member': 'Member',
    'just_now': 'Just now',
    'syncing_address': 'Locating address...',
    'filter_moving': 'Moving',
    'Filter_Moving': 'Moving',
    'status_staying': 'Staying here',
    'status_walking': 'Walking',
    'inside_safe_zone': 'In Safe Zone',
    'safe_zone_in': 'In Safe Zone',
    'places_btn': 'Places',
    'manage_places_title': 'Safe Places (Geofence)',
    'add_new_place': 'Add Safe Place on Map',
    'add_unlimited_pro': 'Unlimited Places (Pro)',
    'free_limit': 'Free up to 2',
    'pro_unlimited': 'Unlimited',
    'pick_place_title': 'Move map to set safe place pin',
    'place_name_hint': 'Place name (e.g. Home, School, Office)',
    'radius_label': 'Alert Radius',
    'radius_alert_on': 'Auto arrival & departure alerts enabled',
    'save_place_btn': 'Save Safe Place',
    'place_arrived_alert': '📍 Arrived at {PLACE}',
    'place_left_alert': '🚶 Left {PLACE}',
    'checkin_bubble': 'Check-In',
    'checkin_toast': 'Sent safe arrival check-in to circle',
    'safe_share': 'Safe Return Link',
    'safe_share_sub': 'Share live trip progress via web link',
    'preview_web_screen': 'Preview Live Web View',
    'web_live_badge': 'Live Safe Return Active',
    'web_arrived_msg': 'Arrived safely at destination!',
    'web_remaining_dist': 'Distance',
    'web_last_will_alert': 'Battery critically low (2%). Last location pinned.',
    'web_test_low_bat': 'Test 2% Battery Pin',
    'web_ping_cheer': 'Send Cheer',
    'web_cheer_sent': 'Cheer sent!',
    'dest_home': '🏠 Safe Destination',
    'sos_btn_label': 'SOS',
    'sos_silent_badge': 'Silent SOS Alert',
    'sos_desc': 'Immediately alert all circle members with your live location.',
    'sos_waiting': 's until alert is sent (Tap below to cancel)',
    'sos_pin_hint': 'Send SOS Now',
    'sos_cancel': 'Cancel SOS',
    'sos_sent_toast': '🚨 Emergency SOS sent to your circle!',
    'sos_cleared_toast': '✅ SOS alert has been cleared.',
    'sos_active_banner': 'SOS Emergency active! Check location now.',
    'sos_Active_banner': 'SOS Emergency active! Check location now.',
    'circle_switch_title': 'Profile & Circle Invite',
    'circle_add_join': 'Add / Join',
    'edit_my_profile_title': 'My Profile & Phone',
    'save_profile_btn': 'Save',
    'profile_saved_toast': 'Profile saved.',
    'invite_code_label': 'Invite Code',
    'share_circle_banner': 'Copy Invite Code & Invite Family',
    'share_messenger_btn': 'Share via Messenger',
    'share_sms_btn': 'Share via SMS',
    'invite_auto_msg': '📍 Join my Pingo live location circle!\nInvite Code: [{CODE}]\nEnter this code in the Pingo app to join!',
    'call_btn': 'Call',
    'sms_btn': 'SMS',
    'directions_btn': 'Route',
    'navigate_btn': 'Route',
    'phone_input_title': 'Save Phone Number',
    'phone_input_hint': 'Enter phone number',
    'phone_save_call': 'Save & Connect',
    'my_timeline_btn': 'My Timeline & Privacy',
    'bubble_mode_title': '🫧 Bubble Privacy Mode (500m)',
    'bubble_mode_on_desc': 'Showing approximate 500m area to circle members.',
    'bubble_mode_off_desc': 'Sharing exact live location with circle members.',
    'bubble_masked_addr': '🫧 Bubble Privacy Active (~500m area)',
    'today': 'Today',
    'yesterday': 'Yesterday',
    'days_30': '30 Days',
    'route_points_unit': 'pts',
    'route_point_unit': 'pts',
    'timeline_empty_yesterday': 'No route recorded yesterday',
    'timeline_points_label': 'Points',
    'timeline_max_speed': 'Max',
    'timeline_total_dist': 'Distance',
    'pro_30d_tease_title': '👑 30-Day Timeline & Route History',
    'pro_30d_tease_desc': 'Upgrade to Pingo Pro to unlock full 30-day route history and stops for you and your family.',
    'pro_unlock_btn': '👑 Unlock 30-Day History with Pro',
    'q_where': '👋 Where are you?',
    'q_otw': '🏃 On my way!',
    'q_home': '🏠 Im home',
    'q_call': '📞 Call me please',
    'q_meal': '🍚 Did you eat?',
    'q_coffee': '☕ Coffee break?',
    'q_lowbat': '🪫 Low battery',
    'q_love': '❤️ Love you!',
    'reply_otw': '🏃 Reply: On my way',
    'pro_badge_btn': 'PRO',
    'pro_active_badge': 'PRO Active',
    'pro_header_badge': 'PINGO PRO PASS',
    'upgrade_pro': 'Pingo Pro Pass',
    'pro_feat_1_title': 'Full 30-Day Location Timeline',
    'pro_feat_1_sub': 'View complete 30-day routes and stops for all members',
    'pro_feat_2_title': 'Unlimited Safe Places (Geofence)',
    'pro_feat_2_sub': 'Get automatic arrival/departure alerts for any place',
    'plan_yearly_title': 'Annual Pass (Best Value)',
    'plan_yearly_price': '\$24.99 / year',
    'plan_monthly_title': 'Monthly Pass',
    'plan_monthly_price': '\$3.49 / month',
    'plan_best_badge': 'SAVE 38%',
    'pro_start_btn': '👑 Start Pingo Pro',
    'pro_activated_toast': '🎉 Pingo Pro unlocked!',
    'restore_purchases': 'Restore Purchases',
    'restore_toast': 'Purchases restored.',
    'sub_auto_renew_notice':
        'Auto-renews unless canceled in store settings before period ends.',
    'terms_eula': 'Terms of Use (EULA)',
    'privacy_policy': 'Privacy Policy',
    'delete_account_btn': 'Delete My Location Data & Reset',
    'delete_account_confirm': 'Permanently delete your server location data.',
    'loc_disclosure_title': 'Location Sharing & Safe Zones',
    'loc_disclosure_body': 'Pingo uses location data to share real-time positions, record timelines, and trigger safe zone alerts.',
    'loc_disclosure_agree': 'Agree & Continue',
  };

  static String t(String key) {
    if (lang == 'ko') {
      return _ko[key] ?? _en[key] ?? key;
    }
    return _en[key] ?? _ko[key] ?? key;
  }
}
