import 'package:flutter/material.dart';

import '../device_profile.dart';
import 'routing/app_route_parser.dart';

typedef MeetingRoomPageBuilder = Widget Function(
  AppRoute route,
  bool preferMobileLayout,
);

typedef AppPageBuilder = Widget Function(bool preferMobileLayout);

class AppEntry extends StatelessWidget {
  const AppEntry({
    super.key,
    required this.dashboardBuilder,
    required this.billingBuilder,
    required this.meetingRoomBuilder,
    this.uri,
  });

  final AppPageBuilder dashboardBuilder;
  final AppPageBuilder billingBuilder;
  final MeetingRoomPageBuilder meetingRoomBuilder;
  final Uri? uri;

  @override
  Widget build(BuildContext context) {
    final currentUri = uri ?? Uri.base;
    final preferMobileLayout =
        DeviceProfile.isLikelyMobileBrowser(uri: currentUri);
    final route = resolveAppRoute(currentUri);
    switch (route.kind) {
      case AppRouteKind.meetingRoom:
        return meetingRoomBuilder(route, preferMobileLayout);
      case AppRouteKind.billingAdmin:
        return billingBuilder(preferMobileLayout);
      case AppRouteKind.dashboard:
        return dashboardBuilder(preferMobileLayout);
    }
  }
}
