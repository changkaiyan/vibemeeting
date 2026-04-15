import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:smart_meeting_app/windows_launcher/native_share_source_picker_dialog.dart';

const List<int> _kTransparentPngBytes = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

class _FakeDesktopSource implements rtc.DesktopCapturerSource {
  _FakeDesktopSource({
    required this.rawId,
    required this.rawName,
    required this.rawType,
    this.rawThumbnail,
  });

  final String rawId;
  final String rawName;
  final rtc.SourceType rawType;
  final Uint8List? rawThumbnail;

  final StreamController<String> _onNameChanged =
      StreamController<String>.broadcast(sync: true);
  final StreamController<Uint8List> _onThumbnailChanged =
      StreamController<Uint8List>.broadcast(sync: true);

  @override
  String get id => rawId;

  @override
  String get name => rawName;

  @override
  Uint8List? get thumbnail => rawThumbnail;

  @override
  rtc.ThumbnailSize get thumbnailSize => rtc.ThumbnailSize(320, 180);

  @override
  rtc.SourceType get type => rawType;

  @override
  StreamController<String> get onNameChanged => _onNameChanged;

  @override
  StreamController<Uint8List> get onThumbnailChanged => _onThumbnailChanged;
}

Future<void> _openPickerDialog(
  WidgetTester tester, {
  required List<rtc.DesktopCapturerSource> sources,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return ElevatedButton(
              onPressed: () {
                showDialog<rtc.DesktopCapturerSource>(
                  context: context,
                  builder: (_) => NativeShareSourcePickerDialog(
                    sources: sources,
                    title: '\u9009\u62e9\u5171\u4eab\u5185\u5bb9',
                    cancelText: '\u53d6\u6d88',
                    confirmText: '\u5f00\u59cb\u5171\u4eab',
                  ),
                );
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders source thumbnails and enables confirm after selecting',
      (tester) async {
    await _openPickerDialog(
      tester,
      sources: [
        _FakeDesktopSource(
          rawId: 'screen-1',
          rawName: '\u6574\u4e2a\u5c4f\u5e55',
          rawType: rtc.SourceType.Screen,
          rawThumbnail: Uint8List.fromList(_kTransparentPngBytes),
        ),
      ],
    );

    final confirmButtonFinder =
        find.byKey(const Key('native_share_source_confirm_button'));
    final confirmButtonBefore =
        tester.widget<FilledButton>(confirmButtonFinder);
    expect(confirmButtonBefore.onPressed, isNull);
    expect(find.byKey(const Key('native_share_source_thumb_screen-1')),
        findsOneWidget);

    final cardFinder = find.byKey(const Key('native_share_source_card_screen-1'));
    final card = tester.widget<InkWell>(cardFinder);
    card.onTap!.call();
    await tester.pumpAndSettle();

    final confirmButtonAfter = tester.widget<FilledButton>(confirmButtonFinder);
    expect(confirmButtonAfter.onPressed, isNotNull);
  });

  testWidgets('supports switching between screen and window tabs',
      (tester) async {
    await _openPickerDialog(
      tester,
      sources: [
        _FakeDesktopSource(
          rawId: 'screen-1',
          rawName: '\u5c4f\u5e55 1',
          rawType: rtc.SourceType.Screen,
        ),
        _FakeDesktopSource(
          rawId: 'window-1',
          rawName: 'Chrome',
          rawType: rtc.SourceType.Window,
        ),
      ],
    );

    expect(find.byKey(const Key('native_share_source_card_screen-1')),
        findsOneWidget);
    expect(find.byKey(const Key('native_share_source_card_window-1')),
        findsNothing);

    await tester.tap(find.text('\u7a97\u53e3'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('native_share_source_card_screen-1')),
        findsNothing);
    expect(find.byKey(const Key('native_share_source_card_window-1')),
        findsOneWidget);
  });
}
