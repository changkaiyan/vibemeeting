import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/app/entry.dart';

void main() {
  testWidgets('AppEntry routes billing uri to billing builder', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppEntry(
          uri: Uri.parse('https://example.com/billing'),
          dashboardBuilder: (_) => const Placeholder(),
          billingBuilder: (_) => const Text('billing'),
          meetingRoomBuilder: (_, __) => const Text('meeting'),
        ),
      ),
    );

    expect(find.text('billing'), findsOneWidget);
    expect(find.text('meeting'), findsNothing);
  });

  testWidgets('AppEntry routes meeting uri to meeting builder', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppEntry(
          uri: Uri.parse('https://example.com/m/demo?autojoin=0'),
          dashboardBuilder: (_) => const Placeholder(),
          billingBuilder: (_) => const Text('billing'),
          meetingRoomBuilder: (route, _) => Text(
            'meeting:${route.shareCode}:${route.autoJoin}',
          ),
        ),
      ),
    );

    expect(find.text('meeting:demo:false'), findsOneWidget);
  });

  testWidgets('AppEntry falls back to dashboard builder', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppEntry(
          uri: Uri.parse('https://example.com/'),
          dashboardBuilder: (_) => const Text('dashboard'),
          billingBuilder: (_) => const Text('billing'),
          meetingRoomBuilder: (_, __) => const Text('meeting'),
        ),
      ),
    );

    expect(find.text('dashboard'), findsOneWidget);
  });
}
