import 'package:flutter/material.dart';

import '../theme/meeting_theme.dart';

class ThemePresetMenuButton extends StatelessWidget {
  const ThemePresetMenuButton({
    super.key,
    required this.currentPreset,
    required this.onSelected,
    this.foregroundColor,
  });

  final MeetingThemePreset currentPreset;
  final ValueChanged<MeetingThemePreset> onSelected;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<MeetingThemePreset>(
      tooltip: '切换主题',
      initialValue: currentPreset,
      onSelected: onSelected,
      icon: Icon(Icons.palette_outlined, color: foregroundColor),
      itemBuilder: (context) => MeetingThemePreset.values
          .map(
            (preset) => PopupMenuItem<MeetingThemePreset>(
              value: preset,
              child: Row(
                children: [
                  if (preset == currentPreset)
                    const Icon(Icons.check, size: 18)
                  else
                    const SizedBox(width: 18),
                  const SizedBox(width: 8),
                  Text(meetingThemePresetLabel(preset)),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}
