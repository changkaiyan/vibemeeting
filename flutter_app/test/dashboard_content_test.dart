import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/app/widgets/scrollable_panels.dart';

void main() {
  testWidgets('open settings reflect refreshed data from the page',
      (tester) async {
    final data = ValueNotifier('保存前');
    addTearDown(data.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ValueListenableBuilder(
      valueListenable: data,
      builder: (context, value, _) => ScrollablePanels(
        status: const Text('状态'),
        primary: const Placeholder(),
        secondary: const Placeholder(),
        details: {'设置': Text(value)},
      ),
    ))));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    data.value = '保存成功';
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: find.byType(Dialog), matching: find.text('保存成功')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('billing lists and expanded settings remain reachable on a phone',
      (tester) async {
    tester.view.physicalSize = const Size(390, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
      child: Scaffold(
          body: ScrollablePanels(
        status: const Text('计费管理'),
        primary: const Column(
            children: [Text('套餐管理'), Expanded(child: Placeholder())]),
        secondary: const Column(
            children: [Text('用户使用量'), Expanded(child: Placeholder())]),
        details: {
          '登录与注册设置': const SizedBox(
              height: 600,
              child: Align(
                  alignment: Alignment.bottomCenter, child: Text('保存登录设置')))
        },
      )),
    )));
    expect(find.text('套餐管理').hitTestable(), findsOneWidget);
    expect(find.text('登录与注册设置').hitTestable(), findsOneWidget);
    expect(find.text('保存登录设置'), findsNothing);
    await tester.tap(find.text('登录与注册设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('保存登录设置'), 200,
        scrollable: find
            .descendant(
                of: find.byType(Dialog), matching: find.byType(Scrollable))
            .first);
    expect(find.text('保存登录设置').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final size in [const Size(1280, 560), const Size(900, 600)]) {
    testWidgets('meetings stay usable and settings scroll at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ScrollablePanels(
        status: const SizedBox(height: 40, child: Text('状态')),
        actions: const SizedBox(height: 60, child: Text('创建会议')),
        primary: Column(key: const ValueKey('meetings'), children: [
          const Text('会议列表'),
          Expanded(
              child: ListView(
                  children: List.generate(
                      30, (i) => SizedBox(height: 60, child: Text('会议 $i'))))),
        ]),
        secondary: const Column(
            children: [Text('录像'), Expanded(child: Placeholder())]),
        details: {
          '个人资料': const SizedBox(height: 300, child: Text('个人资料内容')),
          '录制存储设置': const SizedBox(
              height: 600,
              child: Align(
                  alignment: Alignment.bottomCenter, child: Text('存储设置底部')))
        },
      ))));
      expect(tester.takeException(), isNull);
      expect(find.text('会议列表').hitTestable(), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('meetings'))).height,
          greaterThanOrEqualTo(420));
      expect(find.text('个人资料内容'), findsNothing);
      expect(find.text('存储设置底部'), findsNothing);
      expect(find.text('录制存储设置').hitTestable(), findsOneWidget);
      final before = tester.getTopLeft(find.byKey(const ValueKey('meetings')));
      await tester.drag(find.text('会议 0'), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(find.text('会议 0').hitTestable(), findsNothing);
      await tester.tap(find.text('录制存储设置'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('存储设置底部'), 250,
          scrollable: find
              .descendant(
                  of: find.byType(Dialog), matching: find.byType(Scrollable))
              .first);
      expect(find.text('存储设置底部').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭设置'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(const ValueKey('meetings'))), before);
    });
  }
}
