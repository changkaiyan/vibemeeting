import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/entry.dart';
import 'features/billing/page.dart';
import 'features/dashboard/page.dart';
import 'meeting_room/page.dart';

void main() {
  runApp(
    SmartMeetingApp(
      home: AppEntry(
        meetingRoomBuilder: (route, preferMobileLayout) => MeetingRoomPage(
          meetingRef: route.meetingRef,
          meetingId: route.meetingId,
          shareCode: route.shareCode,
          autoJoin: route.autoJoin,
          preferMobileLayout: preferMobileLayout,
        ),
        billingBuilder: (preferMobileLayout) =>
            BillingAdminPage(preferMobileLayout: preferMobileLayout),
        dashboardBuilder: (preferMobileLayout) =>
            DashboardPage(preferMobileLayout: preferMobileLayout),
      ),
    ),
  );
}
