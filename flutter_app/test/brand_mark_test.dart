import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/app/app.dart';
import 'package:smart_meeting_app/app/widgets/brand_mark.dart';

void main() {
  testWidgets('web app and header identify the product as VibeMeeting',
      (tester) async {
    await tester
        .pumpWidget(const SmartMeetingApp(home: Scaffold(body: BrandMark())));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
        'VibeMeeting');
    expect(find.text('VibeMeeting'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
