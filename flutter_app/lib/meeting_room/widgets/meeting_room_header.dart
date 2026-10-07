import 'package:flutter/material.dart';

import '../../app/theme/meeting_theme.dart';

class MeetingRoomHeader extends StatefulWidget {
  const MeetingRoomHeader({
    super.key,
    required this.title,
    required this.summary,
    required this.status,
    required this.actions,
    required this.details,
    this.statusColor,
    this.recordingLabel,
  });

  final String title;
  final String summary;
  final String status;
  final Color? statusColor;
  final String? recordingLabel;
  final List<Widget> actions;
  final Widget details;

  @override
  State<MeetingRoomHeader> createState() => _MeetingRoomHeaderState();
}

class _MeetingRoomHeaderState extends State<MeetingRoomHeader> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final palette = MeetingTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.heroBorder),
        gradient: LinearGradient(
          colors: [palette.heroGradientStart, palette.heroGradientEnd],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              height: 44,
              child: Row(
                children: [
                  Tooltip(
                    message: widget.status,
                    child: Icon(Icons.circle,
                        size: 8,
                        color: widget.statusColor ?? palette.heroMutedText),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (constraints.maxWidth >= 560) ...[
                    const SizedBox(width: 12),
                    Text(widget.summary,
                        style: TextStyle(
                            color: palette.heroMutedText, fontSize: 12)),
                    const SizedBox(width: 8),
                  ],
                  if (widget.recordingLabel != null)
                    Tooltip(
                      message: widget.recordingLabel!,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.fiber_manual_record,
                            color: Color(0xFFFF8A80), size: 14),
                      ),
                    ),
                  IconButtonTheme(
                    data: IconButtonThemeData(
                        style: IconButton.styleFrom(
                      foregroundColor: Colors.white,
                      minimumSize: const Size(44, 44),
                      maximumSize: const Size(44, 44),
                      padding: EdgeInsets.zero,
                      iconSize: 19,
                    )),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      ...widget.actions,
                      IconButton(
                        tooltip: _expanded ? '收起会议信息' : '展开会议信息',
                        onPressed: () => setState(() => _expanded = !_expanded),
                        icon: Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more),
                      ),
                    ]),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 6),
            widget.details,
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}
