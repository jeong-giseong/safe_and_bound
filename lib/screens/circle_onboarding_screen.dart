import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_theme_and_strings.dart';
import '../models/app_models.dart';
import '../services/app_engine_service.dart';
import 'main_map_screen.dart';

enum _OnboardingStep { welcome, joinCode, createCircle }

class CircleInviteScreen extends StatefulWidget {
  const CircleInviteScreen({super.key});

  @override
  State<CircleInviteScreen> createState() => _CircleInviteScreenState();
}

class _CircleInviteScreenState extends State<CircleInviteScreen> {
  _OnboardingStep _step = _OnboardingStep.welcome;

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _joinCodeController = TextEditingController();
  late TextEditingController _circleNameController;

  String _selectedAvatarUrl = PingoAvatars.presets[0]['url']!;
  String _generatedCode = AppEngineService.generateRandomInviteCode();
  bool _isCodeVerified = false;

  @override
  void initState() {
    super.initState();
    _circleNameController = TextEditingController(
      text: AppStrings.t('preset_family'),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _joinCodeController.dispose();
    _circleNameController.dispose();
    super.dispose();
  }

  void _syncDefaultCircleNameOnLangChange() {
    final current = _circleNameController.text.trim();
    const defaultPresets = [
      '우리 가족',
      'Family',
      'ファミリー',
      '家人',
      'Gia đình',
      'ครอบครัว',
    ];
    if (current.isEmpty || defaultPresets.contains(current)) {
      _circleNameController.text = AppStrings.t('preset_family');
    }
  }

  String _ensureUserName() {
    final raw = _nameController.text.trim();
    return raw.isEmpty ? AppStrings.t('me_default') : raw;
  }

  void _goToMainMap({
    required String circleName,
    required String code,
    required String role,
  }) {
    final userName = _ensureUserName();
    final finalCircleName = circleName.trim().isEmpty
        ? AppStrings.t('preset_family')
        : circleName;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => MainLife360MapScreen(
          userName: userName,
          userAvatarUrl: _selectedAvatarUrl,
          initialCircles: [
            CircleInfo(name: finalCircleName, code: code, myRole: role),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.cardWhite,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (_step != _OnboardingStep.welcome)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(
                            Icons.arrow_back_ios_new_rounded,
                            size: 18,
                          ),
                          onPressed: () => setState(() {
                            _step = _OnboardingStep.welcome;
                            _isCodeVerified = false;
                          }),
                        )
                      else
                        const Flexible(child: PingoBrandLogo(fontSize: 20)),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: AppStrings.lang,
                            isDense: true,
                            icon: const Icon(
                              Icons.arrow_drop_down_rounded,
                              size: 18,
                              color: AppColors.textDark,
                            ),
                            items: AppStrings.supportedLanguages
                                .map(
                                  (item) => DropdownMenuItem<String>(
                                    value: item['code'],
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.language_rounded,
                                          size: 14,
                                          color: AppColors.primaryPurple,
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          item['name']!,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.textDark,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (newLang) {
                              if (newLang != null) {
                                setState(() {
                                  AppStrings.lang = newLang;
                                  _syncDefaultCircleNameOnLangChange();
                                });
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_step == _OnboardingStep.welcome) _buildWelcomeStep(),
                  if (_step == _OnboardingStep.joinCode) _buildJoinCodeStep(),
                  if (_step == _OnboardingStep.createCircle)
                    _buildCreateCircleStep(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWelcomeStep() {
    return Column(
      children: [
        GestureDetector(
          onTap: () => AppEngineService.showAvatarAndPhotoPickerModal(
            context: context,
            currentAvatarUrl: _selectedAvatarUrl,
            onSelected: (url) => setState(() => _selectedAvatarUrl = url),
          ),
          child: Column(
            children: [
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.primaryPurple,
                        width: 3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primaryPurple.withValues(
                            alpha: 0.22,
                          ),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: Image.network(
                        _selectedAvatarUrl,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.primaryPurple,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(
                      Icons.camera_alt_rounded,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: AppColors.lightPurpleBg,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '✨ ${AppStrings.t('choose_avatar_btn')}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primaryPurple,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Text(
          AppStrings.t('circle_title'),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: AppColors.textDark,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          AppStrings.t('circle_sub'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13.5, color: AppColors.textGray),
        ),
        const SizedBox(height: 22),
        TextField(
          controller: _nameController,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          decoration: InputDecoration(
            hintText: AppStrings.t('my_name_hint'),
            filled: true,
            fillColor: const Color(0xFFF9FAFB),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 15,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
            ),
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryPurple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
            ),
            onPressed: () {
              setState(() => _step = _OnboardingStep.joinCode);
            },
            child: Text(
              AppStrings.t('join_with_code'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primaryPurple,
              side: const BorderSide(
                color: AppColors.primaryPurple,
                width: 1.6,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
            ),
            onPressed: () {
              _syncDefaultCircleNameOnLangChange();
              setState(() => _step = _OnboardingStep.createCircle);
            },
            child: Text(
              AppStrings.t('create_new_circle'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildJoinCodeStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppStrings.t('enter_invite_code'),
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w900,
            color: AppColors.textDark,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          AppStrings.t('enter_invite_sub'),
          style: const TextStyle(fontSize: 13, color: AppColors.textGray),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _joinCodeController,
          maxLength: 6,
          textCapitalization: TextCapitalization.characters,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            letterSpacing: 6,
            color: AppColors.primaryPurple,
          ),
          decoration: InputDecoration(
            counterText: '',
            hintText: 'A1B2C3',
            hintStyle: const TextStyle(
              color: Color(0xFFD1D5DB),
              letterSpacing: 6,
            ),
            filled: true,
            fillColor: AppColors.lightPurpleBg,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: (v) {
            setState(() => _isCodeVerified = v.trim().length == 6);
          },
        ),
        const SizedBox(height: 18),
        if (_isCodeVerified) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.safeGreenBg,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: AppColors.safeGreenText,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${AppStrings.t('join_confirm_q')} (${AppStrings.t('current_members')})',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: AppColors.safeGreenText,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryPurple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
            ),
            onPressed: () {
              final rawCode = _joinCodeController.text.trim().toUpperCase();
              final finalCode = rawCode.length == 6 ? rawCode : _generatedCode;
              _goToMainMap(
                circleName: AppStrings.t('preset_family'),
                code: finalCode,
                role: AppStrings.t('role_member'),
              );
            },
            child: Text(
              AppStrings.t('complete_join'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCreateCircleStep() {
    final presets = [
      AppStrings.t('preset_family'),
      AppStrings.t('preset_couple'),
      AppStrings.t('preset_parents'),
      AppStrings.t('preset_trip'),
    ];
    final formattedCode =
        '${_generatedCode.substring(0, 3)}-${_generatedCode.substring(3, 6)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppStrings.t('choose_circle_name'),
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: AppColors.textDark,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _circleNameController,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFFF9FAFB),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: presets
              .map(
                (label) => ActionChip(
                  backgroundColor: AppColors.lightPurpleBg,
                  side: BorderSide.none,
                  label: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryPurple,
                    ),
                  ),
                  onPressed: () {
                    setState(() => _circleNameController.text = label);
                  },
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.lightPurpleBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppColors.primaryPurple.withValues(alpha: 0.25),
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      AppStrings.t('share_code_48h'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textGray,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      setState(() {
                        _generatedCode =
                            AppEngineService.generateRandomInviteCode();
                      });
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.refresh_rounded,
                          size: 15,
                          color: AppColors.primaryPurple,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          AppStrings.t('regenerate_code'),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryPurple,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  formattedCode,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4,
                    color: AppColors.primaryPurple,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primaryPurple,
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: AppColors.primaryPurple),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                    ),
                  ),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _generatedCode));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        backgroundColor: AppColors.primaryPurple,
                        content: Text(AppStrings.t('code_copied')),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: Text(
                    AppStrings.t('share_code_btn'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryPurple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
            ),
            onPressed: () {
              _goToMainMap(
                circleName: _circleNameController.text.trim(),
                code: _generatedCode,
                role: AppStrings.t('role_owner'),
              );
            },
            child: Text(
              AppStrings.t('finish_open_map'),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
        ),
      ],
    );
  }
}
