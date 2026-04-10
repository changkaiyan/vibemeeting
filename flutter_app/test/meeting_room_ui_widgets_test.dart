import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/debug/debug_flags.dart';
import 'package:smart_meeting_app/meeting_room/widgets/media_test_widgets.dart';
import 'package:smart_meeting_app/meeting_room/widgets/panel_widgets.dart';
import 'package:smart_meeting_app/meeting_room/widgets/selectable_region.dart';

void main() {
  testWidgets('panel fullscreen button toggles label and icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              MeetingPanelHeaderActionBar(
                panelLabel: '聊天',
                isFullscreen: false,
                onToggleFullscreen: () {},
              ),
              MeetingPanelHeaderActionBar(
                panelLabel: '工作区',
                isFullscreen: true,
                onToggleFullscreen: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    expect(find.text('放大聊天'), findsOneWidget);
    expect(find.text('退出全屏'), findsOneWidget);
  });

  testWidgets('participant audio level bar clamps and highlights activity', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ParticipantAudioLevelBar(level: 0.18, isActive: true),
              ParticipantAudioLevelBar(level: 3.0, isActive: false),
            ],
          ),
        ),
      ),
    );

    final activeBar = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('participant-audio-bar-0.18')),
    );
    final idleBar = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('participant-audio-bar-1.00')),
    );

    expect((activeBar.decoration! as BoxDecoration).color,
        const Color(0xFF12B76A));
    expect(
        (idleBar.decoration! as BoxDecoration).color, const Color(0xFFD0D5DD));
  });

  testWidgets('device test card renders status and preview placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DeviceTestCard(
            title: '摄像头测试',
            description: '检查画面和角度',
            icon: Icons.videocam_outlined,
            isRunning: true,
            statusText: '摄像头预览中',
            primaryActionLabel: '开始测试',
            secondaryActionLabel: '停止测试',
            onPrimaryAction: null,
            onSecondaryAction: null,
            preview: SizedBox(
              key: ValueKey('camera-preview'),
              width: 160,
              height: 90,
            ),
          ),
        ),
      ),
    );

    expect(find.text('摄像头测试'), findsOneWidget);
    expect(find.text('摄像头预览中'), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-preview')), findsOneWidget);
    expect(find.text('停止测试'), findsOneWidget);
  });

  testWidgets('device test card renders selectable error status',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DeviceTestCard(
            title: '麦克风测试',
            description: '检查输入设备是否可用',
            icon: Icons.mic_none_rounded,
            isRunning: false,
            statusText: '麦克风测试失败：示例错误',
            statusIsError: true,
            primaryActionLabel: '开始测试',
            secondaryActionLabel: '停止测试',
            onPrimaryAction: null,
            onSecondaryAction: null,
          ),
        ),
      ),
    );

    expect(find.byType(SelectableText), findsAtLeastNWidgets(1));
    expect(find.text('麦克风测试失败：示例错误'), findsOneWidget);
  });

  testWidgets('meeting selectable region wraps content in SelectionArea', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MeetingSelectableRegion(
            child: Text('这段文本应该可选'),
          ),
        ),
      ),
    );

    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.text('这段文本应该可选'), findsOneWidget);
  });

  testWidgets('meeting body text renders SelectableText', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MeetingBodyText('聊天内容可以直接选中复制'),
        ),
      ),
    );

    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('聊天内容可以直接选中复制'), findsOneWidget);
  });

  test('debug panels stay hidden unless project debug is enabled', () {
    expect(
      shouldShowRealtimeBotDebugPanel(
        projectDebugUiEnabled: false,
        isSuperAdminUser: true,
        debugPanelVisible: true,
      ),
      isFalse,
    );
    expect(
      shouldShowWorkspaceSttDebug(projectDebugUiEnabled: false),
      isFalse,
    );
    expect(
      shouldShowRealtimeBotDebugPanel(
        projectDebugUiEnabled: true,
        isSuperAdminUser: true,
        debugPanelVisible: true,
      ),
      isTrue,
    );
  });
}
