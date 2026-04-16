import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/windows_launcher/native_meeting_room_logic.dart';

void main() {
  group('meetingRoleLabelZh', () {
    test('maps known roles to chinese labels', () {
      expect(meetingRoleLabelZh('host'), '\u4e3b\u6301\u4eba');
      expect(meetingRoleLabelZh('cohost'), '\u8054\u5e2d\u4e3b\u6301');
      expect(meetingRoleLabelZh('participant'), '\u53c2\u4f1a\u6210\u5458');
    });

    test('falls back for unknown role', () {
      expect(meetingRoleLabelZh('guest'), '\u6210\u5458');
    });
  });

  group('canRaiseHandForRole', () {
    test('moderators cannot raise hand', () {
      expect(canRaiseHandForRole('host'), isFalse);
      expect(canRaiseHandForRole('cohost'), isFalse);
    });

    test('participants can raise hand', () {
      expect(canRaiseHandForRole('participant'), isTrue);
      expect(canRaiseHandForRole(''), isTrue);
    });
  });

  group('isModeratorRole', () {
    test('host and cohost are moderators', () {
      expect(isModeratorRole('host'), isTrue);
      expect(isModeratorRole('cohost'), isTrue);
    });

    test('participant is not moderator', () {
      expect(isModeratorRole('participant'), isFalse);
      expect(isModeratorRole(''), isFalse);
    });
  });

  group('sortMembersForDisplay', () {
    test('places host/cohost before participants', () {
      final sorted = sortMembersForDisplay(
        const <Map<String, dynamic>>[
          <String, dynamic>{'username': 'u3', 'role': 'participant'},
          <String, dynamic>{'username': 'u1', 'role': 'host'},
          <String, dynamic>{'username': 'u2', 'role': 'cohost'},
        ],
      );

      expect(sorted[0]['role'], 'host');
      expect(sorted[1]['role'], 'cohost');
      expect(sorted[2]['role'], 'participant');
    });
  });

  group('buildNativeMeetingShareText', () {
    test('includes title room ref and url when provided', () {
      final text = buildNativeMeetingShareText(
        meetingTitle: '\u7814\u53d1\u5468\u4f1a',
        roomName: 'ROOM-123',
        meetingRef: 'mref-001',
        shareUrl: 'https://example.com/m/mref-001',
      );

      expect(text, contains('ROOM-123'));
      expect(text, contains('mref-001'));
      expect(text, contains('https://example.com/m/mref-001'));
    });

    test('omits optional lines when ref and url are empty', () {
      final text = buildNativeMeetingShareText(
        meetingTitle: '\u4ea7\u54c1\u8bc4\u5ba1',
        roomName: 'ROOM-456',
        meetingRef: '',
        shareUrl: '',
      );

      expect(text, contains('ROOM-456'));
      expect(text, isNot(contains('https://')));
    });
  });

  group('screen share helpers', () {
    test('desktop source picker is enabled on native windows', () {
      expect(
        shouldUseDesktopSourcePicker(isWeb: false, platform: 'windows'),
        isTrue,
      );
      expect(
        shouldUseDesktopSourcePicker(isWeb: false, platform: 'android'),
        isFalse,
      );
      expect(
        shouldUseDesktopSourcePicker(isWeb: true, platform: 'windows'),
        isFalse,
      );
    });

    test('maps cancelled and permission errors to friendly chinese', () {
      expect(
        mapScreenShareErrorToStatus('AbortError: user canceled picker'),
        contains('\u53d6\u6d88'),
      );
      expect(
        mapScreenShareErrorToStatus('NotAllowedError: Permission denied'),
        contains('\u6743\u9650'),
      );
      expect(
        mapScreenShareErrorToStatus(
          'unable to get displaymedia: source not found!',
        ),
        contains('\u5171\u4eab\u6e90'),
      );
    });

    test('detects source not found errors for retry', () {
      expect(
        isScreenShareSourceNotFoundError(
          'unable to get displaymedia: source not found!',
        ),
        isTrue,
      );
      expect(
        isScreenShareSourceNotFoundError(
          'NotAllowedError: Permission denied by system',
        ),
        isFalse,
      );
    });

    test('detects no local media track error for join fallback', () {
      expect(
        isJoinWithoutMediaTrackError(
          'livekit exception: failed to create stream, at least 1 video or audio track should exist.',
        ),
        isTrue,
      );
      expect(
        isJoinWithoutMediaTrackError('permission denied'),
        isFalse,
      );
    });
  });

  group('web parity helpers', () {
    test('uses system window fullscreen only on native windows', () {
      expect(
        shouldUseSystemWindowFullscreen(isWeb: false, platform: 'windows'),
        isTrue,
      );
      expect(
        shouldUseSystemWindowFullscreen(isWeb: true, platform: 'windows'),
        isFalse,
      );
      expect(
        shouldUseSystemWindowFullscreen(isWeb: false, platform: 'linux'),
        isFalse,
      );
    });

    test('stage grid columns follow web breakpoints', () {
      expect(stageGridColumnsForWidth(650), 1);
      expect(stageGridColumnsForWidth(700), 2);
      expect(stageGridColumnsForWidth(1099), 2);
      expect(stageGridColumnsForWidth(1100), 3);
    });

    test('tile zoom controls only appear for spotlight/fullscreen video', () {
      expect(
        shouldShowTileZoomControls(
          hasVideoTrack: true,
          isSpotlight: true,
          isFullscreen: false,
        ),
        isTrue,
      );
      expect(
        shouldShowTileZoomControls(
          hasVideoTrack: true,
          isSpotlight: false,
          isFullscreen: true,
        ),
        isTrue,
      );
      expect(
        shouldShowTileZoomControls(
          hasVideoTrack: true,
          isSpotlight: false,
          isFullscreen: false,
        ),
        isFalse,
      );
      expect(
        shouldShowTileZoomControls(
          hasVideoTrack: false,
          isSpotlight: true,
          isFullscreen: true,
        ),
        isFalse,
      );
    });

    test('dock button labels follow web semantics', () {
      expect(micButtonLabelZh(micEnabled: true), '\u9759\u97f3');
      expect(
        micButtonLabelZh(micEnabled: false),
        '\u53d6\u6d88\u9759\u97f3',
      );
      expect(
        cameraButtonLabelZh(cameraEnabled: true),
        '\u5173\u95ed\u6444\u50cf\u5934',
      );
      expect(
        cameraButtonLabelZh(cameraEnabled: false),
        '\u5f00\u542f\u6444\u50cf\u5934',
      );
      expect(
        screenShareButtonLabelZh(
          canShareScreen: true,
          screenShareEnabled: false,
        ),
        '\u5171\u4eab\u5c4f\u5e55',
      );
      expect(
        screenShareButtonLabelZh(
          canShareScreen: true,
          screenShareEnabled: true,
        ),
        '\u505c\u6b62\u5171\u4eab',
      );
      expect(
        screenShareButtonLabelZh(
          canShareScreen: false,
          screenShareEnabled: false,
        ),
        '\u5171\u4eab\u5df2\u7981\u7528',
      );
    });

    test('dock button enabled state follows web rules', () {
      expect(
        canToggleMicButton(
          connected: true,
          micEnabled: false,
          canSelfUnmute: true,
        ),
        isTrue,
      );
      expect(
        canToggleMicButton(
          connected: false,
          micEnabled: true,
          canSelfUnmute: true,
        ),
        isFalse,
      );
      expect(
        canToggleCameraButton(
          connected: true,
          cameraEnabled: false,
          canOpenVideo: true,
        ),
        isTrue,
      );
      expect(
        canToggleCameraButton(
          connected: true,
          cameraEnabled: false,
          canOpenVideo: false,
        ),
        isFalse,
      );
    });
  });

  group('remote control helpers', () {
    test('enables hover pointer move on native desktop', () {
      expect(
        shouldSendRemoteHoverPointerMoves(isWeb: false, platform: 'windows'),
        isTrue,
      );
      expect(
        shouldSendRemoteHoverPointerMoves(isWeb: false, platform: 'linux'),
        isTrue,
      );
      expect(
        shouldSendRemoteHoverPointerMoves(isWeb: false, platform: 'macos'),
        isTrue,
      );
      expect(
        shouldSendRemoteHoverPointerMoves(isWeb: true, platform: 'windows'),
        isFalse,
      );
      expect(
        shouldSendRemoteHoverPointerMoves(isWeb: false, platform: 'android'),
        isFalse,
      );
    });

    test('requires target screen share before approving remote control', () {
      expect(
        shouldStartRemoteControlScreenShare(
          screenShareEnabled: false,
          canScreenShare: true,
        ),
        isTrue,
      );
      expect(
        shouldStartRemoteControlScreenShare(
          screenShareEnabled: true,
          canScreenShare: true,
        ),
        isFalse,
      );
      expect(
        shouldStartRemoteControlScreenShare(
          screenShareEnabled: false,
          canScreenShare: false,
        ),
        isFalse,
      );
    });

    test('returns chinese status when target cannot share screen', () {
      expect(
          remoteControlScreenShareRequiredStatusZh(), contains('\u5c4f\u5e55'));
      expect(
          remoteControlScreenShareRequiredStatusZh(), contains('\u5171\u4eab'));
      expect(
        remoteControlTargetScreenNotReadyStatusZh(),
        contains('\u753b\u9762'),
      );
    });

    test('periodically forces reliable pointer move packets', () {
      expect(shouldForceReliableRemotePointerMove(0), isTrue);
      expect(shouldForceReliableRemotePointerMove(1), isFalse);
      expect(shouldForceReliableRemotePointerMove(4), isFalse);
      expect(shouldForceReliableRemotePointerMove(5), isTrue);
    });

    test('uses screen-only picker for remote control auto start', () {
      expect(
        shouldIncludeWindowSourcesInDesktopPicker(
          forRemoteControlAutoStart: true,
        ),
        isFalse,
      );
      expect(
        shouldIncludeWindowSourcesInDesktopPicker(
          forRemoteControlAutoStart: false,
        ),
        isTrue,
      );
    });

    test('forces reliability for pointer down/up and periodic move', () {
      expect(
        shouldSendRemotePointerReliably(event: 'down', moveSequence: 1),
        isTrue,
      );
      expect(
        shouldSendRemotePointerReliably(event: 'up', moveSequence: 2),
        isTrue,
      );
      expect(
        shouldSendRemotePointerReliably(event: 'move', moveSequence: 1),
        isFalse,
      );
      expect(
        shouldSendRemotePointerReliably(event: 'move', moveSequence: 5),
        isTrue,
      );
    });

    test('disables system fullscreen for active remote-control tile', () {
      expect(
        shouldUseSystemWindowFullscreenForTile(
          isWeb: false,
          platform: 'windows',
          isRemoteControlTileActive: false,
        ),
        isTrue,
      );
      expect(
        shouldUseSystemWindowFullscreenForTile(
          isWeb: false,
          platform: 'windows',
          isRemoteControlTileActive: true,
        ),
        isFalse,
      );
    });

    test('stops auto-started screen share when controlled session ends', () {
      expect(
        shouldStopAutoStartedRemoteControlScreenShare(
          autoStartedByRemoteControl: true,
          sessionWasBeingControlled: true,
        ),
        isTrue,
      );
      expect(
        shouldStopAutoStartedRemoteControlScreenShare(
          autoStartedByRemoteControl: false,
          sessionWasBeingControlled: true,
        ),
        isFalse,
      );
      expect(
        shouldStopAutoStartedRemoteControlScreenShare(
          autoStartedByRemoteControl: true,
          sessionWasBeingControlled: false,
        ),
        isFalse,
      );
    });
  });
}
