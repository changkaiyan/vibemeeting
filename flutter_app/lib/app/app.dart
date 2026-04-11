import 'package:flutter/material.dart';

import 'theme/meeting_theme.dart';

class SmartMeetingApp extends StatelessWidget {
  const SmartMeetingApp({
    super.key,
    required this.home,
    this.themePreset = MeetingThemePreset.classicBlue,
  });

  final Widget home;
  final MeetingThemePreset themePreset;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '智能会议控制台',
      debugShowCheckedModeBanner: false,
      theme: buildMeetingTheme(themePreset),
      home: home,
    );
  }
}
