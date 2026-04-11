import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/app/app.dart';
import 'package:smart_meeting_app/app/theme/meeting_theme.dart';

void main() {
  test('buildMeetingTheme returns different palettes for presets', () {
    final classic = buildMeetingTheme(MeetingThemePreset.classicBlue);
    final graphite = buildMeetingTheme(MeetingThemePreset.graphite);

    final classicPalette = classic.extension<MeetingThemePalette>();
    final graphitePalette = graphite.extension<MeetingThemePalette>();

    expect(classicPalette, isNotNull);
    expect(graphitePalette, isNotNull);
    expect(classicPalette!.primary, isNot(graphitePalette!.primary));
    expect(
        classicPalette.pageBackground, isNot(graphitePalette.pageBackground));
    expect(classic.cardTheme.color, isNot(graphite.cardTheme.color));
  });

  testWidgets('MeetingTheme.of reads palette from context', (tester) async {
    late MeetingThemePalette palette;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildMeetingTheme(MeetingThemePreset.graphite),
        home: Builder(
          builder: (context) {
            palette = MeetingTheme.of(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(palette.primary, const Color(0xFF2F6FED));
    expect(palette.pageBackground, const Color(0xFFF3F5F8));
    expect(palette.panelBorder, const Color(0xFFD6DBE3));
  });

  testWidgets('SmartMeetingApp applies the requested theme preset', (
    tester,
  ) async {
    late MeetingThemePalette palette;

    await tester.pumpWidget(
      SmartMeetingApp(
        themePreset: MeetingThemePreset.graphite,
        home: Builder(
          builder: (context) {
            palette = MeetingTheme.of(context);
            return const Scaffold();
          },
        ),
      ),
    );

    expect(palette.heroGradientStart, const Color(0xFF223B63));
    expect(palette.primarySoft, const Color(0xFFE9F0FF));
  });
}
