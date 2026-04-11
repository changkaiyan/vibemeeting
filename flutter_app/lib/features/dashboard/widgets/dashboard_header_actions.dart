import 'package:flutter/material.dart';

import '../../../app/theme/meeting_theme.dart';
import '../../../app/widgets/theme_preset_menu_button.dart';

class DashboardHeaderActions extends StatelessWidget {
  const DashboardHeaderActions({
    super.key,
    required this.currentThemePreset,
    required this.onThemeSelected,
    required this.onOpenProfile,
    required this.onRefresh,
    required this.onLogout,
    required this.onOpenBilling,
    required this.isAdmin,
    this.displayName,
    this.avatar,
    this.showDisplayName = true,
    this.showLogoutLabel = false,
  });

  final MeetingThemePreset currentThemePreset;
  final ValueChanged<MeetingThemePreset> onThemeSelected;
  final VoidCallback onOpenProfile;
  final VoidCallback onRefresh;
  final VoidCallback onLogout;
  final VoidCallback onOpenBilling;
  final bool isAdmin;
  final String? displayName;
  final Widget? avatar;
  final bool showDisplayName;
  final bool showLogoutLabel;

  @override
  Widget build(BuildContext context) {
    final hasDisplayName = (displayName ?? '').trim().isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (avatar != null && hasDisplayName && showDisplayName) ...[
          avatar!,
          const SizedBox(width: 8),
          Text(
            displayName!,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
        ],
        ThemePresetMenuButton(
          currentPreset: currentThemePreset,
          onSelected: onThemeSelected,
          foregroundColor: Colors.white,
        ),
        IconButton(
          tooltip: '编辑资料',
          onPressed: onOpenProfile,
          icon: const Icon(Icons.person_outline, color: Colors.white),
        ),
        IconButton(
          tooltip: '刷新',
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh, color: Colors.white),
        ),
        if (isAdmin)
          IconButton(
            tooltip: '计费管理',
            onPressed: onOpenBilling,
            icon: const Icon(Icons.payments_outlined, color: Colors.white),
          ),
        if (showLogoutLabel)
          TextButton.icon(
            onPressed: onLogout,
            icon: const Icon(Icons.logout, color: Colors.white, size: 18),
            label: const Text('退出', style: TextStyle(color: Colors.white)),
          )
        else
          IconButton(
            tooltip: '退出登录',
            onPressed: onLogout,
            icon: const Icon(Icons.logout, color: Colors.white),
          ),
      ],
    );
  }
}
