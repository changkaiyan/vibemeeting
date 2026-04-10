import 'package:flutter/material.dart';
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isRunning ? const Color(0xFF84CAFF) : const Color(0xFFDDE6FF),
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
                  color: isRunning
                      ? const Color(0xFFE0F2FE)
                      : const Color(0xFFF2F4F7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: isRunning
                      ? const Color(0xFF175CD3)
                      : const Color(0xFF667085),
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
                      style: const TextStyle(
                        color: Color(0xFF667085),
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
                      ? const Color(0xFFECFDF3)
                      : const Color(0xFFF2F4F7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  isRunning ? '测试中' : '空闲',
                  style: TextStyle(
                    color: isRunning
                        ? const Color(0xFF067647)
                        : const Color(0xFF667085),
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
                  style: const TextStyle(
                    color: Color(0xFFB42318),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                )
              : MeetingStatusText(
                  statusText,
                  style: const TextStyle(
                    color: Color(0xFF344054),
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
