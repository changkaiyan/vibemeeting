import 'package:flutter/material.dart';

enum MeetingThemePreset {
  classicBlue,
  graphite,
}

@immutable
class MeetingThemePalette extends ThemeExtension<MeetingThemePalette> {
  const MeetingThemePalette({
    required this.primary,
    required this.primaryStrong,
    required this.primarySoft,
    required this.primarySoftAlt,
    required this.primaryBorder,
    required this.pageBackground,
    required this.surface,
    required this.surfaceMuted,
    required this.surfaceRaised,
    required this.panelBorder,
    required this.textPrimary,
    required this.textStrong,
    required this.textSecondary,
    required this.textMuted,
    required this.danger,
    required this.dangerSoft,
    required this.dangerSurface,
    required this.dangerBorder,
    required this.warning,
    required this.warningSurface,
    required this.warningBorder,
    required this.success,
    required this.heroGradientStart,
    required this.heroGradientEnd,
    required this.heroText,
    required this.heroMutedText,
    required this.heroBorder,
  });

  final Color primary;
  final Color primaryStrong;
  final Color primarySoft;
  final Color primarySoftAlt;
  final Color primaryBorder;
  final Color pageBackground;
  final Color surface;
  final Color surfaceMuted;
  final Color surfaceRaised;
  final Color panelBorder;
  final Color textPrimary;
  final Color textStrong;
  final Color textSecondary;
  final Color textMuted;
  final Color danger;
  final Color dangerSoft;
  final Color dangerSurface;
  final Color dangerBorder;
  final Color warning;
  final Color warningSurface;
  final Color warningBorder;
  final Color success;
  final Color heroGradientStart;
  final Color heroGradientEnd;
  final Color heroText;
  final Color heroMutedText;
  final Color heroBorder;

  @override
  MeetingThemePalette copyWith({
    Color? primary,
    Color? primaryStrong,
    Color? primarySoft,
    Color? primarySoftAlt,
    Color? primaryBorder,
    Color? pageBackground,
    Color? surface,
    Color? surfaceMuted,
    Color? surfaceRaised,
    Color? panelBorder,
    Color? textPrimary,
    Color? textStrong,
    Color? textSecondary,
    Color? textMuted,
    Color? danger,
    Color? dangerSoft,
    Color? dangerSurface,
    Color? dangerBorder,
    Color? warning,
    Color? warningSurface,
    Color? warningBorder,
    Color? success,
    Color? heroGradientStart,
    Color? heroGradientEnd,
    Color? heroText,
    Color? heroMutedText,
    Color? heroBorder,
  }) {
    return MeetingThemePalette(
      primary: primary ?? this.primary,
      primaryStrong: primaryStrong ?? this.primaryStrong,
      primarySoft: primarySoft ?? this.primarySoft,
      primarySoftAlt: primarySoftAlt ?? this.primarySoftAlt,
      primaryBorder: primaryBorder ?? this.primaryBorder,
      pageBackground: pageBackground ?? this.pageBackground,
      surface: surface ?? this.surface,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      panelBorder: panelBorder ?? this.panelBorder,
      textPrimary: textPrimary ?? this.textPrimary,
      textStrong: textStrong ?? this.textStrong,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      danger: danger ?? this.danger,
      dangerSoft: dangerSoft ?? this.dangerSoft,
      dangerSurface: dangerSurface ?? this.dangerSurface,
      dangerBorder: dangerBorder ?? this.dangerBorder,
      warning: warning ?? this.warning,
      warningSurface: warningSurface ?? this.warningSurface,
      warningBorder: warningBorder ?? this.warningBorder,
      success: success ?? this.success,
      heroGradientStart: heroGradientStart ?? this.heroGradientStart,
      heroGradientEnd: heroGradientEnd ?? this.heroGradientEnd,
      heroText: heroText ?? this.heroText,
      heroMutedText: heroMutedText ?? this.heroMutedText,
      heroBorder: heroBorder ?? this.heroBorder,
    );
  }

  @override
  MeetingThemePalette lerp(
    covariant ThemeExtension<MeetingThemePalette>? other,
    double t,
  ) {
    if (other is! MeetingThemePalette) {
      return this;
    }
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return MeetingThemePalette(
      primary: c(primary, other.primary),
      primaryStrong: c(primaryStrong, other.primaryStrong),
      primarySoft: c(primarySoft, other.primarySoft),
      primarySoftAlt: c(primarySoftAlt, other.primarySoftAlt),
      primaryBorder: c(primaryBorder, other.primaryBorder),
      pageBackground: c(pageBackground, other.pageBackground),
      surface: c(surface, other.surface),
      surfaceMuted: c(surfaceMuted, other.surfaceMuted),
      surfaceRaised: c(surfaceRaised, other.surfaceRaised),
      panelBorder: c(panelBorder, other.panelBorder),
      textPrimary: c(textPrimary, other.textPrimary),
      textStrong: c(textStrong, other.textStrong),
      textSecondary: c(textSecondary, other.textSecondary),
      textMuted: c(textMuted, other.textMuted),
      danger: c(danger, other.danger),
      dangerSoft: c(dangerSoft, other.dangerSoft),
      dangerSurface: c(dangerSurface, other.dangerSurface),
      dangerBorder: c(dangerBorder, other.dangerBorder),
      warning: c(warning, other.warning),
      warningSurface: c(warningSurface, other.warningSurface),
      warningBorder: c(warningBorder, other.warningBorder),
      success: c(success, other.success),
      heroGradientStart: c(heroGradientStart, other.heroGradientStart),
      heroGradientEnd: c(heroGradientEnd, other.heroGradientEnd),
      heroText: c(heroText, other.heroText),
      heroMutedText: c(heroMutedText, other.heroMutedText),
      heroBorder: c(heroBorder, other.heroBorder),
    );
  }
}

class MeetingTheme {
  const MeetingTheme._();

  static MeetingThemePalette of(BuildContext context) {
    final palette = Theme.of(context).extension<MeetingThemePalette>();
    assert(palette != null, 'MeetingThemePalette is missing from ThemeData');
    return palette!;
  }
}

ThemeData buildMeetingTheme(MeetingThemePreset preset) {
  final palette = switch (preset) {
    MeetingThemePreset.classicBlue => _classicBluePalette,
    MeetingThemePreset.graphite => _graphitePalette,
  };
  const cjkFontFallback = <String>[
    'PingFang SC',
    'Hiragino Sans GB',
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'Source Han Sans SC',
    'WenQuanYi Micro Hei',
    'sans-serif',
  ];
  final colorScheme = ColorScheme.fromSeed(
    seedColor: palette.primary,
    brightness: Brightness.light,
    surface: palette.surface,
  );
  final baseTheme = ThemeData(
    colorScheme: colorScheme,
    useMaterial3: true,
    extensions: <ThemeExtension<dynamic>>[palette],
  );
  return baseTheme.copyWith(
    textTheme: baseTheme.textTheme.apply(fontFamilyFallback: cjkFontFallback),
    primaryTextTheme:
        baseTheme.primaryTextTheme.apply(fontFamilyFallback: cjkFontFallback),
    scaffoldBackgroundColor: palette.pageBackground,
    appBarTheme: AppBarTheme(
      foregroundColor: palette.heroText,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: palette.panelBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surfaceMuted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.primaryBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.primaryBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.primary, width: 1.6),
      ),
      labelStyle: TextStyle(color: palette.textSecondary),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.primary,
        foregroundColor: palette.heroText,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.primaryStrong,
        side: BorderSide(color: palette.primaryBorder),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.primaryStrong,
      ),
    ),
  );
}

const _classicBluePalette = MeetingThemePalette(
  primary: Color(0xFF155EEF),
  primaryStrong: Color(0xFF175CD3),
  primarySoft: Color(0xFFEFF4FF),
  primarySoftAlt: Color(0xFFD9E6FF),
  primaryBorder: Color(0xFFCCDBFF),
  pageBackground: Color(0xFFF4F7FF),
  surface: Colors.white,
  surfaceMuted: Color(0xFFF8FAFF),
  surfaceRaised: Color(0xFFFCFDFF),
  panelBorder: Color(0xFFDDE6FF),
  textPrimary: Color(0xFF101828),
  textStrong: Color(0xFF0F172A),
  textSecondary: Color(0xFF344054),
  textMuted: Color(0xFF667085),
  danger: Color(0xFFB42318),
  dangerSoft: Color(0xFFFDA29B),
  dangerSurface: Color(0xFFFEE4E2),
  dangerBorder: Color(0xFFFECACA),
  warning: Color(0xFFB54708),
  warningSurface: Color(0xFFFFF4ED),
  warningBorder: Color(0xFFFDDCAB),
  success: Color(0xFF12B76A),
  heroGradientStart: Color(0xFF155EEF),
  heroGradientEnd: Color(0xFF175CD3),
  heroText: Colors.white,
  heroMutedText: Color(0xFFD1E0FF),
  heroBorder: Color(0xFF9BB8FF),
);

const _graphitePalette = MeetingThemePalette(
  primary: Color(0xFF2F6FED),
  primaryStrong: Color(0xFF275FD2),
  primarySoft: Color(0xFFE9F0FF),
  primarySoftAlt: Color(0xFFD9E3FF),
  primaryBorder: Color(0xFFC4D2F7),
  pageBackground: Color(0xFFF3F5F8),
  surface: Color(0xFFFEFEFF),
  surfaceMuted: Color(0xFFF7F8FA),
  surfaceRaised: Color(0xFFF9FAFB),
  panelBorder: Color(0xFFD6DBE3),
  textPrimary: Color(0xFF111827),
  textStrong: Color(0xFF0B1220),
  textSecondary: Color(0xFF374151),
  textMuted: Color(0xFF6B7280),
  danger: Color(0xFFB42318),
  dangerSoft: Color(0xFFFDA29B),
  dangerSurface: Color(0xFFFEE4E2),
  dangerBorder: Color(0xFFFECACA),
  warning: Color(0xFFB45309),
  warningSurface: Color(0xFFFFF7E8),
  warningBorder: Color(0xFFF2D08F),
  success: Color(0xFF0F9F6E),
  heroGradientStart: Color(0xFF223B63),
  heroGradientEnd: Color(0xFF2B5FA8),
  heroText: Colors.white,
  heroMutedText: Color(0xFFD6E4FF),
  heroBorder: Color(0xFF8CA7D7),
);
