import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/app/app.dart';
import 'package:smart_meeting_app/meeting_room/models.dart';
import 'package:smart_meeting_app/windows_launcher/native_meeting_page.dart';

JoinTokenPayload _joinPayload({bool allowRecording = true}) {
  return JoinTokenPayload(
    meetingId: 1,
    meetingRef: '',
    roomName: 'native-room',
    livekitUrl: '',
    token: '',
    waitingRoomEnabled: false,
    maxParticipants: 100,
    actualStartedAt: null,
    muteOnEntry: false,
    allowGuestLinkJoin: true,
    allowRecording: allowRecording,
    allowScreenShare: true,
    allowChat: true,
    allowSelfUnmute: true,
    allowMemberVideo: true,
    canPublish: true,
  );
}

MeetingMemberProfile _member({
  required int userId,
  required String username,
  required String displayName,
  required String role,
}) {
  return MeetingMemberProfile(
    userId: userId,
    username: username,
    displayName: displayName,
    displayNameVersion: 1,
    avatarUrl: '',
    role: role,
    mutedByHost: false,
    videoBlockedByHost: false,
    allowSelfUnmute: true,
    allowMemberVideo: true,
    allowChat: true,
    allowScreenShare: true,
    micRequestPending: false,
    videoRequestPending: false,
  );
}

ChatMessage _chatMessage({
  required int id,
  required int senderUserId,
  required String senderUsername,
  required String senderDisplayName,
  required String content,
  DateTime? createdAt,
}) {
  return ChatMessage(
    id: id,
    senderUserId: senderUserId,
    senderUsername: senderUsername,
    senderDisplayName: senderDisplayName,
    isRealtimeBot: false,
    audioMimeType: '',
    audioBase64: '',
    content: content,
    createdAt: createdAt,
  );
}

void main() {
  testWidgets('renders mobile meeting scaffold on narrow viewport',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      SmartMeetingApp(
        home: NativeMeetingPage(
          joinPayload: _joinPayload(),
          meetingTitle: '\u79fb\u52a8\u7aef\u4f1a\u8bae',
          baseUri: Uri.parse('https://example.com'),
          accessToken: 'token',
          currentUsername: 'alice',
          autoConnect: false,
        ),
      ),
    );

    expect(find.text('\u624b\u673a\u4f1a\u8bae\u6a21\u5f0f'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('nativeMeetingMobileDock')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('nativeMeetingTopActions')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('nativeMeetingBottomControls')),
      findsNothing,
    );
  });

  testWidgets('renders meeting room controls and right panel tabs in Chinese',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      SmartMeetingApp(
        home: NativeMeetingPage(
          joinPayload: _joinPayload(),
          meetingTitle: '\u7814\u53d1\u5468\u4f1a',
          baseUri: Uri.parse('https://example.com'),
          accessToken: 'token',
          currentUsername: 'alice',
          autoConnect: false,
        ),
      ),
    );

    expect(find.text('\u6210\u5458\u5217\u8868'), findsAtLeastNWidgets(1));
    expect(find.text('\u4f1a\u8bae\u804a\u5929'), findsAtLeastNWidgets(1));
    expect(find.text('\u79bb\u5f00\u4f1a\u8bae'), findsOneWidget);
    expect(find.text('\u5f00\u59cb\u5f55\u5236'), findsOneWidget);
    expect(find.text('\u5171\u4eab\u5c4f\u5e55'), findsOneWidget);
    expect(find.text('\u4f1a\u8bae\u4fe1\u606f'), findsOneWidget);
    expect(find.text('\u52a0\u5165\u4f1a\u8bae'), findsOneWidget);
    expect(find.text('\u9759\u97f3'), findsOneWidget);
    expect(find.text('\u5173\u95ed\u6444\u50cf\u5934'), findsOneWidget);
    expect(find.textContaining('\u5728\u7ebf'), findsOneWidget);
    expect(
        find.text(
            '\u53cc\u51fb\u6210\u5458\u53ef\u653e\u5927\u5bf9\u5e94\u753b\u9762'),
        findsOneWidget);

    await tester.tap(find.text('\u4f1a\u8bae\u804a\u5929').last);
    await tester.pumpAndSettle();
    expect(
      find.text(
          '\u6210\u5458\u53ef\u64a4\u56de 3 \u5206\u949f\u5185\u6d88\u606f\uff0c\u4e3b\u6301\u4eba\u4e0e\u8054\u5e2d\u4e3b\u6301\u4eba\u53ef\u64a4\u56de\u4efb\u610f\u6d88\u606f'),
      findsOneWidget,
    );
    expect(find.text('\u8f93\u5165\u6d88\u606f\uff0c\u652f\u6301\u8868\u60c5'),
        findsOneWidget);

    final topActions =
        find.byKey(const ValueKey<String>('nativeMeetingTopActions'));
    final bottomControls =
        find.byKey(const ValueKey<String>('nativeMeetingBottomControls'));
    expect(topActions, findsOneWidget);
    expect(bottomControls, findsOneWidget);
    expect(
      find.descendant(
          of: topActions, matching: find.text('\u4f1a\u8bae\u4fe1\u606f')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: topActions,
          matching: find.text('\u72b6\u6001\uff1a\u672a\u8fde\u63a5')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: topActions,
          matching: find.text('\u53c2\u4f1a/\u4e0a\u9650\uff1a0/100')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: topActions,
          matching: find.text('\u9000\u56de\u63a7\u5236\u53f0')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bottomControls,
        matching: find.text('\u4f1a\u8bae\u4fe1\u606f'),
      ),
      findsNothing,
    );
  });

  testWidgets(
      'shows disabled recording and screen-share actions when disallowed',
      (tester) async {
    await tester.pumpWidget(
      SmartMeetingApp(
        home: NativeMeetingPage(
          joinPayload: const JoinTokenPayload(
            meetingId: 1,
            meetingRef: '',
            roomName: 'native-room',
            livekitUrl: '',
            token: '',
            waitingRoomEnabled: false,
            maxParticipants: 100,
            actualStartedAt: null,
            muteOnEntry: false,
            allowGuestLinkJoin: true,
            allowRecording: false,
            allowScreenShare: false,
            allowChat: true,
            allowSelfUnmute: true,
            allowMemberVideo: true,
            canPublish: true,
          ),
          meetingTitle: '\u4ea7\u54c1\u8bc4\u5ba1',
          baseUri: Uri.parse('https://example.com'),
          accessToken: 'token',
          currentUsername: 'alice',
          autoConnect: false,
        ),
      ),
    );

    expect(find.text('\u5f55\u5236\u5df2\u7981\u7528'), findsOneWidget);
    expect(find.text('\u5171\u4eab\u5df2\u7981\u7528'), findsOneWidget);
  });

  testWidgets('shows pre-join setup dialog before connecting', (tester) async {
    await tester.pumpWidget(
      SmartMeetingApp(
        home: NativeMeetingPage(
          joinPayload: _joinPayload(),
          meetingTitle: '\u5165\u4f1a\u524d\u6d4b\u8bd5',
          baseUri: Uri.parse('https://example.com'),
          accessToken: 'token',
          currentUsername: 'alice',
          autoConnect: false,
        ),
      ),
    );

    await tester.tap(find.text('\u52a0\u5165\u4f1a\u8bae').first);
    await tester.pumpAndSettle();

    expect(find.text('\u5165\u4f1a\u524d\u786e\u8ba4'), findsOneWidget);
    expect(
        find.text(
            '\u8fdb\u5165\u4f1a\u8bae\u65f6\u5f00\u542f\u9ea6\u514b\u98ce'),
        findsOneWidget);
    expect(
        find.text(
            '\u8fdb\u5165\u4f1a\u8bae\u65f6\u5f00\u542f\u6444\u50cf\u5934'),
        findsOneWidget);
    expect(find.text('\u7a0d\u540e\u52a0\u5165'), findsOneWidget);
    expect(find.text('\u786e\u8ba4\u5165\u4f1a'), findsOneWidget);
  });

  testWidgets('shows moderator control entry for host role', (tester) async {
    await tester.pumpWidget(
      SmartMeetingApp(
        home: NativeMeetingPage(
          joinPayload: const JoinTokenPayload(
            meetingId: 1,
            meetingRef: 'ref-001',
            roomName: 'native-room',
            livekitUrl: '',
            token: '',
            waitingRoomEnabled: true,
            maxParticipants: 100,
            actualStartedAt: null,
            muteOnEntry: false,
            allowGuestLinkJoin: true,
            allowRecording: true,
            allowScreenShare: true,
            allowChat: true,
            allowSelfUnmute: true,
            allowMemberVideo: true,
            canPublish: true,
          ),
          meetingTitle: '\u4e3b\u6301\u4eba\u6d4b\u8bd5\u4f1a',
          baseUri: Uri.parse('https://example.com'),
          accessToken: 'token',
          currentUsername: 'host_user',
          autoConnect: false,
          initialMemberProfiles: [
            _member(
              userId: 10,
              username: 'host_user',
              displayName: '\u4e3b\u6301\u4eba',
              role: 'host',
            ),
          ],
        ),
      ),
    );

    expect(find.text('\u4e3b\u6301\u7ba1\u63a7'), findsOneWidget);
    expect(find.text('\u7ed3\u675f\u4f1a\u8bae'), findsOneWidget);
    await tester.tap(find.text('\u4e3b\u6301\u7ba1\u63a7'));
    await tester.pumpAndSettle();

    expect(find.text('\u5f00\u542f\u7b49\u5019\u5ba4'), findsOneWidget);
    expect(
        find.text(
            '\u5141\u8bb8\u8bbf\u5ba2\u901a\u8fc7\u94fe\u63a5\u52a0\u5165'),
        findsOneWidget);
    expect(find.text('\u5141\u8bb8\u804a\u5929'), findsOneWidget);
    expect(find.text('\u5141\u8bb8\u5c4f\u5e55\u5171\u4eab'), findsOneWidget);
    expect(
        find.text(
            '\u5141\u8bb8\u6210\u5458\u81ea\u6211\u89e3\u9664\u9759\u97f3'),
        findsOneWidget);
    expect(find.text('\u5141\u8bb8\u6210\u5458\u5f00\u542f\u89c6\u9891'),
        findsOneWidget);
  });

  testWidgets('shows member management menu for host role', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      SmartMeetingApp(
        home: NativeMeetingPage(
          joinPayload: const JoinTokenPayload(
            meetingId: 2,
            meetingRef: 'ref-002',
            roomName: 'native-room',
            livekitUrl: '',
            token: '',
            waitingRoomEnabled: true,
            maxParticipants: 100,
            actualStartedAt: null,
            muteOnEntry: false,
            allowGuestLinkJoin: true,
            allowRecording: true,
            allowScreenShare: true,
            allowChat: true,
            allowSelfUnmute: true,
            allowMemberVideo: true,
            canPublish: true,
          ),
          meetingTitle: '\u6210\u5458\u7ba1\u7406\u6d4b\u8bd5\u4f1a',
          baseUri: Uri.parse('https://example.com'),
          accessToken: 'token',
          currentUsername: 'host_user',
          autoConnect: false,
          initialMemberProfiles: [
            _member(
              userId: 10,
              username: 'host_user',
              displayName: '\u4e3b\u6301\u4eba',
              role: 'host',
            ),
            _member(
              userId: 11,
              username: 'member_1',
              displayName: '\u6210\u5458A',
              role: 'participant',
            ),
          ],
        ),
      ),
    );

    expect(find.text('\u7ba1\u7406'), findsOneWidget);
    await tester.tap(find.text('\u7ba1\u7406'));
    await tester.pumpAndSettle();

    expect(find.text('\u9759\u97f3\u6210\u5458'), findsOneWidget);
    expect(find.text('\u8bbe\u4e3a\u8054\u5e2d\u4e3b\u6301\u4eba'),
        findsOneWidget);
    expect(find.text('\u79fb\u51fa\u6210\u5458\uff08\u53ef\u91cd\u8fdb\uff09'),
        findsOneWidget);
  });

  testWidgets('shows member row menu and rename entries', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      SmartMeetingApp(
        home: NativeMeetingPage(
          joinPayload: const JoinTokenPayload(
            meetingId: 4,
            meetingRef: 'ref-004',
            roomName: 'native-room',
            livekitUrl: '',
            token: '',
            waitingRoomEnabled: true,
            maxParticipants: 100,
            actualStartedAt: null,
            muteOnEntry: false,
            allowGuestLinkJoin: true,
            allowRecording: true,
            allowScreenShare: true,
            allowChat: true,
            allowSelfUnmute: true,
            allowMemberVideo: true,
            canPublish: true,
          ),
          meetingTitle: '\u6210\u5458\u83dc\u5355\u6d4b\u8bd5',
          baseUri: Uri.parse('https://example.com'),
          accessToken: 'token',
          currentUsername: 'host_user',
          autoConnect: false,
          initialMemberProfiles: [
            _member(
              userId: 10,
              username: 'host_user',
              displayName: '\u4e3b\u6301\u4eba',
              role: 'host',
            ),
            _member(
              userId: 11,
              username: 'member_1',
              displayName: '\u6210\u5458A',
              role: 'participant',
            ),
          ],
        ),
      ),
    );

    expect(find.byTooltip('\u6210\u5458\u83dc\u5355'), findsNWidgets(2));
    await tester.tap(find.byTooltip('\u6210\u5458\u83dc\u5355').first);
    await tester.pumpAndSettle();
    expect(find.text('\u4fee\u6539\u672c\u6b21\u663e\u793a\u540d'),
        findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('\u6210\u5458\u83dc\u5355').last);
    await tester.pumpAndSettle();
    expect(find.text('\u6210\u5458\u6539\u540d'), findsOneWidget);
  });

  testWidgets('shows chat message actions for copy and recall', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      SmartMeetingApp(
        home: NativeMeetingPage(
          joinPayload: const JoinTokenPayload(
            meetingId: 3,
            meetingRef: 'ref-003',
            roomName: 'native-room',
            livekitUrl: '',
            token: '',
            waitingRoomEnabled: true,
            maxParticipants: 100,
            actualStartedAt: null,
            muteOnEntry: false,
            allowGuestLinkJoin: true,
            allowRecording: true,
            allowScreenShare: true,
            allowChat: true,
            allowSelfUnmute: true,
            allowMemberVideo: true,
            canPublish: true,
          ),
          meetingTitle: '\u804a\u5929\u529f\u80fd\u6d4b\u8bd5\u4f1a',
          baseUri: Uri.parse('https://example.com'),
          accessToken: 'token',
          currentUsername: 'host_user',
          autoConnect: false,
          initialMemberProfiles: [
            _member(
              userId: 10,
              username: 'host_user',
              displayName: '\u4e3b\u6301\u4eba',
              role: 'host',
            ),
          ],
          initialMessages: [
            _chatMessage(
              id: 101,
              senderUserId: 11,
              senderUsername: 'member_1',
              senderDisplayName: '\u6210\u5458A',
              content: '\u5927\u5bb6\u597d',
              createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('\u4f1a\u8bae\u804a\u5929').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('\u6d88\u606f\u64cd\u4f5c').first);
    await tester.pumpAndSettle();

    expect(find.text('\u590d\u5236\u6d88\u606f'), findsOneWidget);
    expect(find.text('\u64a4\u56de\u6d88\u606f'), findsOneWidget);
  });
}
