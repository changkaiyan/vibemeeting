import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/app/app.dart';
import 'package:smart_meeting_app/meeting_room/widgets/meeting_room_header.dart';

Widget _page({String title = '测试会议', bool recording = false}) {
  return SmartMeetingApp(
    home: Scaffold(
      body: Column(
        children: [
          MeetingRoomHeader(
            title: title,
            summary: '3 人 · 00:12:34',
            status: '网络：良好',
            recordingLabel: recording ? '正在录制' : null,
            actions: [
              IconButton(
                  tooltip: '会议分享',
                  onPressed: () {},
                  icon: const Icon(Icons.share))
            ],
            details: const SizedBox(height: 140, child: Text('会议详细信息')),
          ),
          const SizedBox(height: 44, child: Text('舞台 成员 聊天')),
          const Expanded(
              child: ColoredBox(key: ValueKey('stage'), color: Colors.black)),
          const SizedBox(height: 44),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('header starts compact and expanding details uses stage space',
      (tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_page());

    expect(find.text('会议详细信息'), findsNothing);
    expect(tester.getSize(find.byType(MeetingRoomHeader)).height,
        lessThanOrEqualTo(56));
    final compactStage =
        tester.getSize(find.byKey(const ValueKey('stage'))).height;
    await tester.tap(find.byTooltip('展开会议信息'));
    await tester.pumpAndSettle();
    expect(find.text('会议详细信息'), findsOneWidget);
    final expandedStage =
        tester.getSize(find.byKey(const ValueKey('stage'))).height;
    expect(compactStage - expandedStage, greaterThanOrEqualTo(140));
    expect(find.byTooltip('会议分享'), findsOneWidget);

    await tester.tap(find.byTooltip('收起会议信息'));
    await tester.pumpAndSettle();
    expect(find.text('会议详细信息'), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('stage'))).height,
        compactStage);
  });

  testWidgets('long title and recording indicator fit a narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_page(title: '这是一个非常长的会议标题' * 8, recording: true));
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('正在录制'), findsOneWidget);
    expect(find.byTooltip('网络：良好'), findsOneWidget);
    expect(find.byTooltip('展开会议信息'), findsOneWidget);
  });

  testWidgets('desktop header retains summary and expanded state on rebuild',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_page());
    expect(find.text('3 人 · 00:12:34'), findsOneWidget);
    await tester.tap(find.byTooltip('展开会议信息'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_page(title: '更新后的会议标题'));
    expect(find.text('会议详细信息'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
