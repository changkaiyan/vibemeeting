import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/app/widgets/copyright_notice.dart';

void main() {
  testWidgets(
      'copyright stays readable without overflow on narrow scaled pages',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(body: CopyrightNotice()),
        ),
      ));
      expect(find.text('© 2026 VibeMeeting contributors'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final text =
          tester.widget<Text>(find.text('© 2026 VibeMeeting contributors'));
      expect(text.style!.fontSize, lessThanOrEqualTo(12));
    }
  });
}
