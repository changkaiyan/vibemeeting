import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Gives independently scrolling lists useful space even in short windows.
/// Settings stay discoverable in a compact toolbar and open in a scrollable dialog.
class ScrollablePanels extends StatefulWidget {
  const ScrollablePanels({
    super.key,
    required this.status,
    this.actions,
    required this.primary,
    required this.secondary,
    this.details = const {},
    this.stackPanels = false,
  });

  final Widget status;
  final Widget? actions;
  final Widget primary;
  final Widget secondary;
  final Map<String, Widget> details;
  final bool stackPanels;

  @override
  State<ScrollablePanels> createState() => _ScrollablePanelsState();
}

class _ScrollablePanelsState extends State<ScrollablePanels> {
  final _settingsRevision = ValueNotifier(0);

  @override
  void didUpdateWidget(covariant ScrollablePanels oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A saved/refreshed setting rebuilds the owning page, including an open dialog.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _settingsRevision.value++;
    });
  }

  @override
  void dispose() {
    _settingsRevision.dispose();
    super.dispose();
  }

  void _openSettings(String title) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                child: Row(children: [
                  Expanded(
                      child: Text(title,
                          style: Theme.of(context).textTheme.titleMedium)),
                  IconButton(
                      tooltip: '关闭设置',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close)),
                ]),
              ),
              Flexible(
                  child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: ValueListenableBuilder(
                  valueListenable: _settingsRevision,
                  builder: (_, __, ___) =>
                      widget.details[title] ?? const SizedBox.shrink(),
                ),
              )),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final height = math.max(420.0, constraints.maxHeight - 140);
          final stacked = widget.stackPanels || constraints.maxWidth < 980;
          return SingleChildScrollView(
            key: const ValueKey('dashboard-scroll'),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.details.isNotEmpty)
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    children: [
                      for (final title in widget.details.keys)
                        TextButton.icon(
                          onPressed: () => _openSettings(title),
                          icon: const Icon(Icons.tune_outlined, size: 18),
                          label: Text(title),
                        ),
                    ],
                  ),
                widget.status,
                if (widget.actions != null) ...[
                  const SizedBox(height: 8),
                  widget.actions!,
                ],
                const SizedBox(height: 12),
                if (stacked) ...[
                  SizedBox(height: height, child: widget.primary),
                  const SizedBox(height: 12),
                  SizedBox(height: height, child: widget.secondary),
                ] else
                  SizedBox(
                    height: height,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 6, child: widget.primary),
                        const SizedBox(width: 12),
                        Expanded(flex: 5, child: widget.secondary),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      );
}
