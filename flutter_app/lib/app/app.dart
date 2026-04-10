import 'package:flutter/material.dart';

class SmartMeetingApp extends StatelessWidget {
  const SmartMeetingApp({
    super.key,
    required this.home,
  });

  final Widget home;

  @override
  Widget build(BuildContext context) {
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
      seedColor: const Color(0xFF155EEF),
      brightness: Brightness.light,
    );
    final baseTheme = ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
    );
    return MaterialApp(
      title: '智能会议控制台',
      debugShowCheckedModeBanner: false,
      theme: baseTheme.copyWith(
        textTheme: baseTheme.textTheme.apply(
          fontFamilyFallback: cjkFontFallback,
        ),
        primaryTextTheme: baseTheme.primaryTextTheme.apply(
          fontFamilyFallback: cjkFontFallback,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F7FF),
        appBarTheme: const AppBarTheme(
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFFDDE6FF)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF8FAFF),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFC8D8FF)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFC8D8FF)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF155EEF), width: 1.6),
          ),
          labelStyle: const TextStyle(color: Color(0xFF344054)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF155EEF),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF175CD3),
            side: const BorderSide(color: Color(0xFFB2CCFF)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF175CD3),
          ),
        ),
      ),
      home: home,
    );
  }
}
