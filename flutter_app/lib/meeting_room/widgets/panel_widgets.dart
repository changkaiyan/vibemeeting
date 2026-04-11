import 'package:flutter/material.dart';
import '../../app/theme/meeting_theme.dart';

class MeetingPanelHeaderActionBar extends StatelessWidget {
  final String panelLabel;
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;

  const MeetingPanelHeaderActionBar({
    super.key,
    required this.panelLabel,
    required this.isFullscreen,
    required this.onToggleFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    final palette = MeetingTheme.of(context);
    return Tooltip(
      message: isFullscreen ? '退出全屏' : '放大$panelLabel',
      child: TextButton.icon(
        onPressed: onToggleFullscreen,
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: palette.primary,
          backgroundColor: palette.primarySoft,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: BorderSide(color: palette.primaryBorder),
          ),
        ),
        icon: Icon(isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
        label: Text(isFullscreen ? '退出全屏' : '放大$panelLabel'),
      ),
    );
  }
}

class ParticipantAudioLevelBar extends StatelessWidget {
  final double level;
  final bool isActive;
  final double width;
  final double height;

  const ParticipantAudioLevelBar({
    super.key,
    required this.level,
    required this.isActive,
    this.width = 44,
    this.height = 6,
  });

  @override
  Widget build(BuildContext context) {
    final palette = MeetingTheme.of(context);
    final normalized = level.clamp(0.0, 1.0);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: palette.panelBorder,
        borderRadius: BorderRadius.circular(999),
      ),
      clipBehavior: Clip.antiAlias,
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: normalized,
        child: AnimatedContainer(
          key: ValueKey(
            'participant-audio-bar-${normalized.toStringAsFixed(2)}',
          ),
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          height: height,
          decoration: BoxDecoration(
            color: isActive ? palette.success : palette.panelBorder,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }
}
