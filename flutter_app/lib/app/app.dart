import 'package:flutter/material.dart';

import 'theme/meeting_theme.dart';
import 'theme/theme_controller.dart';

class SmartMeetingApp extends StatefulWidget {
  const SmartMeetingApp({
    super.key,
    required this.home,
    this.themePreset = MeetingThemePreset.classicBlue,
  });

  final Widget home;
  final MeetingThemePreset themePreset;

  @override
  State<SmartMeetingApp> createState() => _SmartMeetingAppState();
}

class _SmartMeetingAppState extends State<SmartMeetingApp> {
  late final MeetingThemeController _themeController;

  @override
  void initState() {
    super.initState();
    _themeController = MeetingThemeController(
      initialPreset: widget.themePreset,
    );
  }

  @override
  void dispose() {
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _themeController,
      builder: (context, _) {
        return MeetingThemeControllerScope(
          controller: _themeController,
          child: MaterialApp(
            title: '智能会议控制台',
            debugShowCheckedModeBanner: false,
            theme: buildMeetingTheme(_themeController.preset),
            home: widget.home,
          ),
        );
      },
    );
  }
}
