import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/app/app.dart';
import 'package:smart_meeting_app/app/theme/meeting_theme.dart';
import 'package:smart_meeting_app/meeting_room/debug/debug_flags.dart';
import 'package:smart_meeting_app/meeting_room/widgets/media_test_widgets.dart';
import 'package:smart_meeting_app/meeting_room/widgets/panel_widgets.dart';
import 'package:smart_meeting_app/meeting_room/widgets/selectable_region.dart';

void main() {
  testWidgets('panel fullscreen button toggles label and icon', (tester) async {
    await tester.pumpWidget(
      SmartMeetingApp(
        home: Scaffold(
          body: Wrap(
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

  testWidgets('panel action bar follows meeting theme palette', (tester) async {
    await tester.pumpWidget(
      SmartMeetingApp(
        themePreset: MeetingThemePreset.graphite,
        home: Scaffold(
          body: MeetingPanelHeaderActionBar(
            panelLabel: '聊天',
            isFullscreen: false,
            onToggleFullscreen: () {},
          ),
        ),
      ),
    );

    final button = tester.widget<TextButton>(find.byType(TextButton));
    final foreground = button.style!.foregroundColor!.resolve({});
    final background = button.style!.backgroundColor!.resolve({});
    final shape = button.style!.shape!.resolve({})! as RoundedRectangleBorder;

    expect(foreground, const Color(0xFF2F6FED));
    expect(background, const Color(0xFFE9F0FF));
    expect(shape.side.color, const Color(0xFFC4D2F7));
  });

  testWidgets('participant audio level bar clamps and highlights activity', (
    tester,
  ) async {
    await tester.pumpWidget(
      const SmartMeetingApp(
        home: Scaffold(
          body: Wrap(
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
      (idleBar.decoration! as BoxDecoration).color,
      const Color(0xFFDDE6FF),
    );
  });

  testWidgets('device test card renders status and preview placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      const SmartMeetingApp(
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

  testWidgets('device test card follows meeting theme palette', (tester) async {
    await tester.pumpWidget(
      SmartMeetingApp(
        themePreset: MeetingThemePreset.graphite,
        home: const Scaffold(
          body: DeviceTestCard(
            title: '扬声器测试',
            description: '检查播放设备是否可用',
            icon: Icons.volume_up_outlined,
            isRunning: true,
            statusText: '正在播放测试音',
            primaryActionLabel: '重新播放',
            secondaryActionLabel: '停止测试',
            onPrimaryAction: null,
            onSecondaryAction: null,
          ),
        ),
      ),
    );

    final card = tester.widget<Container>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Container &&
                widget.decoration is BoxDecoration &&
                (widget.decoration! as BoxDecoration).border != null,
          )
          .first,
    );
    final decoration = card.decoration! as BoxDecoration;
    expect((decoration.border! as Border).top.color, const Color(0xFFC4D2F7));

    final statusText = tester.widget<Text>(find.text('测试中'));
    expect(statusText.style!.color, const Color(0xFF0F9F6E));
  });

  testWidgets('device test card renders selectable error status',
      (tester) async {
    await tester.pumpWidget(
      const SmartMeetingApp(
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

  test('realtime bot debug follows superuser visibility from kaiyan', () {
    expect(
      shouldShowRealtimeBotDebugPanel(
        projectDebugUiEnabled: false,
        isSuperAdminUser: true,
        debugPanelVisible: true,
      ),
      isTrue,
    );
    expect(
      shouldShowWorkspaceSttDebug(projectDebugUiEnabled: false),
      isFalse,
    );
    expect(
      shouldShowRealtimeBotDebugPanel(
        projectDebugUiEnabled: true,
        isSuperAdminUser: false,
        debugPanelVisible: true,
      ),
      isFalse,
    );
    expect(
      shouldShowRealtimeBotDebugPanel(
        projectDebugUiEnabled: true,
        isSuperAdminUser: true,
        debugPanelVisible: false,
      ),
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
