import 'package:flutter/material.dart';

import 'meeting_theme.dart';

class MeetingThemeController extends ChangeNotifier {
  MeetingThemeController({
    MeetingThemePreset initialPreset = MeetingThemePreset.classicBlue,
  }) : _preset = initialPreset;

  MeetingThemePreset _preset;

  MeetingThemePreset get preset => _preset;

  void updatePreset(MeetingThemePreset preset) {
    if (_preset == preset) {
      return;
    }
    _preset = preset;
    notifyListeners();
  }
}

class MeetingThemeControllerScope
    extends InheritedNotifier<MeetingThemeController> {
  const MeetingThemeControllerScope({
    super.key,
    required MeetingThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static MeetingThemeController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<MeetingThemeControllerScope>();
    assert(scope != null, 'MeetingThemeControllerScope is missing');
    return scope!.notifier!;
  }
}
