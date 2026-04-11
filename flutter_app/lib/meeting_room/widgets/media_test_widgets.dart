import 'package:flutter/material.dart';
import '../../app/theme/meeting_theme.dart';
import 'selectable_region.dart';

class DeviceTestCard extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final bool isRunning;
  final String statusText;
  final bool statusIsError;
  final String primaryActionLabel;
  final String secondaryActionLabel;
  final VoidCallback? onPrimaryAction;
  final VoidCallback? onSecondaryAction;
  final Widget? preview;
  final Widget? footer;

  const DeviceTestCard({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.isRunning,
    required this.statusText,
    this.statusIsError = false,
    required this.primaryActionLabel,
    required this.secondaryActionLabel,
    required this.onPrimaryAction,
    required this.onSecondaryAction,
    this.preview,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final palette = MeetingTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isRunning ? palette.primaryBorder : palette.panelBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isRunning ? palette.primarySoft : palette.surfaceMuted,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: isRunning ? palette.primaryStrong : palette.textMuted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: TextStyle(
                        color: palette.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isRunning
                      ? Color.alphaBlend(
                          palette.success.withValues(alpha: 0.12),
                          palette.surface,
                        )
                      : palette.surfaceMuted,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  isRunning ? '测试中' : '空闲',
                  style: TextStyle(
                    color: isRunning ? palette.success : palette.textMuted,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          statusIsError
              ? MeetingErrorText(
                  statusText,
                  style: TextStyle(
                    color: palette.danger,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                )
              : MeetingStatusText(
                  statusText,
                  style: TextStyle(
                    color: palette.textSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
          if (preview != null) ...[
            const SizedBox(height: 10),
            preview!,
          ],
          if (footer != null) ...[
            const SizedBox(height: 10),
            footer!,
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onPrimaryAction,
                icon: Icon(isRunning ? Icons.restart_alt : Icons.play_arrow),
                label: Text(primaryActionLabel),
              ),
              FilledButton.icon(
                onPressed: onSecondaryAction,
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(secondaryActionLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
