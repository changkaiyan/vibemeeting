import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/app/app.dart';
import 'package:smart_meeting_app/windows_launcher/page.dart';

void main() {
  testWidgets('renders mobile login layout on narrow viewport', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const SmartMeetingApp(
        home: WindowsLauncherPage(),
      ),
    );

    expect(find.text('手机端登录'), findsOneWidget);
    expect(find.text('Windows 原生客户端'), findsNothing);
  });

  testWidgets('renders desktop login layout on wide viewport', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const SmartMeetingApp(
        home: WindowsLauncherPage(),
      ),
    );

    expect(find.text('Windows 原生客户端'), findsOneWidget);
  });

  testWidgets('renders livekit public url input on login view', (tester) async {
    await tester.pumpWidget(
      const SmartMeetingApp(
        home: WindowsLauncherPage(),
      ),
    );

    expect(find.text('LiveKit 公网地址（可选）'), findsOneWidget);
  });
}
