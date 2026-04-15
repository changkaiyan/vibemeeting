import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

class NativeShareSourcePickerDialog extends StatefulWidget {
  const NativeShareSourcePickerDialog({
    super.key,
    required this.sources,
    this.title = '选择共享内容',
    this.cancelText = '取消',
    this.confirmText = '开始共享',
  });

  final List<rtc.DesktopCapturerSource> sources;
  final String title;
  final String cancelText;
  final String confirmText;

  @override
  State<NativeShareSourcePickerDialog> createState() =>
      _NativeShareSourcePickerDialogState();
}

class _NativeShareSourcePickerDialogState
    extends State<NativeShareSourcePickerDialog> {
  late rtc.SourceType _activeType;
  rtc.DesktopCapturerSource? _selected;

  List<rtc.DesktopCapturerSource> get _activeSources {
    return widget.sources
        .where((source) => source.type == _activeType)
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    _activeType = widget.sources.any((s) => s.type == rtc.SourceType.Screen)
        ? rtc.SourceType.Screen
        : rtc.SourceType.Window;
  }

  void _switchType(rtc.SourceType type) {
    if (_activeType == type) return;
    setState(() {
      _activeType = type;
      if (_selected?.type != type) {
        _selected = null;
      }
    });
  }

  String _displayName(rtc.DesktopCapturerSource source, int index) {
    final name = source.name.trim();
    if (name.isNotEmpty) return name;
    if (source.type == rtc.SourceType.Window) {
      return '窗口 ${index + 1}';
    }
    return '屏幕 ${index + 1}';
  }

  String _typeLabel(rtc.SourceType type) {
    return type == rtc.SourceType.Screen ? '屏幕' : '窗口';
  }

  Widget _buildTypeSwitcher() {
    final canSwitchToScreen =
        widget.sources.any((s) => s.type == rtc.SourceType.Screen);
    final canSwitchToWindow =
        widget.sources.any((s) => s.type == rtc.SourceType.Window);
    return Wrap(
      spacing: 8,
      children: [
        _TypeChip(
          label: '屏幕',
          selected: _activeType == rtc.SourceType.Screen,
          enabled: canSwitchToScreen,
          onTap: () => _switchType(rtc.SourceType.Screen),
        ),
        _TypeChip(
          label: '窗口',
          selected: _activeType == rtc.SourceType.Window,
          enabled: canSwitchToWindow,
          onTap: () => _switchType(rtc.SourceType.Window),
        ),
      ],
    );
  }

  Widget _buildGrid() {
    final sources = _activeSources;
    if (sources.isEmpty) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFFF8FAFC),
          border: Border.all(color: const Color(0xFFE4E7EC)),
        ),
        child: Text(
          '暂无可共享的${_typeLabel(_activeType)}',
          style: const TextStyle(
            color: Color(0xFF667085),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width >= 980
            ? 3
            : width >= 680
                ? 2
                : 1;
        return GridView.builder(
          itemCount: sources.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.26,
          ),
          itemBuilder: (context, index) {
            final source = sources[index];
            final selected = _selected?.id == source.id;
            final name = _displayName(source, index);
            return InkWell(
              key: Key('native_share_source_card_${source.id}'),
              borderRadius: BorderRadius.circular(14),
              onTap: () => setState(() => _selected = source),
              onDoubleTap: () => Navigator.of(context).pop(source),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: selected
                        ? const Color(0xFF175CD3)
                        : const Color(0xFFD0D5DD),
                    width: selected ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF101828).withValues(alpha: 0.08),
                      blurRadius: selected ? 16 : 10,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: _SourceThumbnail(
                          key: Key('native_share_source_thumb_${source.id}'),
                          source: source,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF4FF),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              _typeLabel(source.type),
                              style: const TextStyle(
                                color: Color(0xFF175CD3),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 560,
          maxWidth: 1120,
          minHeight: 440,
          maxHeight: 760,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF101828),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '请选择要共享的窗口或整个屏幕',
                style: const TextStyle(
                  color: Color(0xFF667085),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              _buildTypeSwitcher(),
              const SizedBox(height: 12),
              Expanded(child: _buildGrid()),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(widget.cancelText),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const Key('native_share_source_confirm_button'),
                    onPressed: _selected == null
                        ? null
                        : () => Navigator.of(context).pop(_selected),
                    child: Text(widget.confirmText),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFFEEF4FF) : const Color(0xFFF9FAFB),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              color:
                  selected ? const Color(0xFF175CD3) : const Color(0xFF475467),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceThumbnail extends StatelessWidget {
  const _SourceThumbnail({
    super.key,
    required this.source,
  });

  final rtc.DesktopCapturerSource source;

  IconData get _placeholderIcon {
    return source.type == rtc.SourceType.Window
        ? Icons.web_asset_outlined
        : Icons.desktop_windows_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? thumb = source.thumbnail;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: thumb != null && thumb.isNotEmpty
              ? Image.memory(
                  thumb,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) {
                    return Center(
                      child: Icon(
                        _placeholderIcon,
                        color: Colors.white70,
                        size: 36,
                      ),
                    );
                  },
                )
              : Center(
                  child: Icon(
                    _placeholderIcon,
                    color: Colors.white70,
                    size: 36,
                  ),
                ),
        ),
      ),
    );
  }
}
