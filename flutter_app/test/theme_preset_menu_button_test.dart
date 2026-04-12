import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/app/theme/meeting_theme.dart';
import 'package:smart_meeting_app/app/widgets/theme_preset_menu_button.dart';

void main() {
  testWidgets('ThemePresetMenuButton renders presets and emits selection', (
    tester,
  ) async {
    MeetingThemePreset? selectedPreset;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildMeetingTheme(MeetingThemePreset.classicBlue),
        home: Scaffold(
          body: ThemePresetMenuButton(
            currentPreset: MeetingThemePreset.classicBlue,
            onSelected: (preset) => selectedPreset = preset,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('切换主题'));
    await tester.pumpAndSettle();

    expect(find.text('经典蓝'), findsOneWidget);
    expect(find.text('石墨灰'), findsOneWidget);

    await tester.tap(find.text('石墨灰').last);
    await tester.pumpAndSettle();

    expect(selectedPreset, MeetingThemePreset.graphite);
  });
}
