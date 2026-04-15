import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import '../app/theme/meeting_theme.dart';
import '../meeting_room/chat_menu/chat_message_menu_builder.dart';
import '../meeting_room/models.dart';
import '../meeting_room/remote_control_protocol.dart';
import 'native_api_client.dart';
import 'native_meeting_recording_logic.dart';
import 'native_meeting_room_logic.dart';
import 'native_share_source_picker_dialog.dart';
import 'windows_remote_input_injector.dart';

class NativeMeetingPage extends StatefulWidget {
  const NativeMeetingPage({
    super.key,
    required this.joinPayload,
    required this.meetingTitle,
    required this.baseUri,
    required this.accessToken,
    required this.currentUsername,
    this.autoConnect = true,
    this.initialMemberProfiles = const <MeetingMemberProfile>[],
    this.initialMessages = const <ChatMessage>[],
  });

  final JoinTokenPayload joinPayload;
  final String meetingTitle;
  final Uri baseUri;
  final String accessToken;
  final String currentUsername;
  final bool autoConnect;
  final List<MeetingMemberProfile> initialMemberProfiles;
  final List<ChatMessage> initialMessages;

  @override
  State<NativeMeetingPage> createState() => _NativeMeetingPageState();
}

class _NativeMeetingPageState extends State<NativeMeetingPage> {
  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _roomListener;
  Timer? _recordingStatusTimer;
  Timer? _memberPollTimer;
  Timer? _messagePollTimer;
  final TextEditingController _chatInputController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();

  String _status = '正在连接...';
  bool _connecting = true;
  bool _connected = false;
  bool _micEnabled = true;
  bool _cameraEnabled = true;
  bool _screenShareEnabled = false;
  bool _leaving = false;
  bool _recordingBusy = false;
  bool _moderationBusy = false;
  bool _loadingMembers = false;
  bool _loadingMessages = false;
  bool _sendingMessage = false;
  bool _raisingHand = false;
  String? _spotlightIdentity;
  String? _fullscreenIdentity;
  final Map<String, TransformationController> _tileZoomControllers =
      <String, TransformationController>{};
  final FocusNode _remoteControlFocusNode = FocusNode();
  final WindowsRemoteInputInjector _remoteInputInjector =
      const WindowsRemoteInputInjector();
  String? _remoteControlSessionId;
  String? _remoteControlTargetIdentity;
  String? _remoteControlControlledByIdentity;
  String? _remoteControlPendingTargetIdentity;
  String? _remoteControlPendingRequestId;
  DateTime? _remoteControlLastPointerMoveAt;
  String _remoteControlLastPointerButton = 'left';
  late bool _waitingRoomEnabled;
  late bool _allowGuestLinkJoin;
  late bool _allowChat;
  late bool _allowScreenShare;
  late bool _allowSelfUnmute;
  late bool _allowMemberVideo;
  static const double _minTileZoomScale = 1.0;
  static const double _maxTileZoomScale = 5.0;

  DesktopMeetingRecordingState _recordingState =
      const DesktopMeetingRecordingState();
  List<MeetingMemberProfile> _memberProfiles = const <MeetingMemberProfile>[];
  List<ChatMessage> _messages = const <ChatMessage>[];
  List<WaitingRoomEntry> _waitingRoomEntries = const <WaitingRoomEntry>[];
  final Set<int> _recallingMessageIds = <int>{};

  MeetingThemePalette get _palette => MeetingTheme.of(context);
  String get _meetingRef => widget.joinPayload.meetingRef.trim();
  bool get _hasMeetingRef => _meetingRef.isNotEmpty;
  bool get _canRecordMeeting => widget.joinPayload.allowRecording;
  bool get _recordingActive => _recordingState.active;
  bool get _chatAllowedByMeeting => _allowChat;
  bool get _isModerator => isModeratorRole(_myRole);
  bool get _isHost => _myRole == 'host';
  bool get _canUseModeratorControls => _isModerator && _hasMeetingRef;
  bool get _canSelfUnmute {
    if (!_allowSelfUnmute) return false;
    final self = _selfMember;
    if (self == null) return _allowSelfUnmute;
    return self.allowSelfUnmute;
  }

  bool get _canOpenVideo {
    if (!_allowMemberVideo) return false;
    final self = _selfMember;
    if (self == null) return _allowMemberVideo;
    return self.allowMemberVideo;
  }

  bool get _canScreenShare {
    if (!_allowScreenShare) {
      return false;
    }
    final self = _selfMember;
    if (self == null) {
      return true;
    }
    return self.allowScreenShare;
  }

  String? get _localIdentity {
    final identity = _room?.localParticipant?.identity.trim() ?? '';
    return identity.isEmpty ? null : identity;
  }

  bool get _canPublishRemoteControlData {
    final local = _room?.localParticipant;
    if (local == null) return false;
    final permissions = local.permissions;
    return permissions.canPublishData || permissions.canPublish;
  }

  bool get _isBeingRemoteControlled =>
      _remoteControlSessionId != null &&
      _remoteControlControlledByIdentity != null &&
      _remoteControlControlledByIdentity!.trim().isNotEmpty;

  bool _isRemoteControlActiveForIdentity(String identity) {
    return _remoteControlSessionId != null &&
        _remoteControlTargetIdentity != null &&
        _remoteControlTargetIdentity == identity;
  }

  bool _isRemoteControlPendingForIdentity(String identity) {
    return _remoteControlPendingTargetIdentity != null &&
        _remoteControlPendingTargetIdentity == identity;
  }

  DesktopMeetingApiClient get _client => DesktopMeetingApiClient(
        baseUri: widget.baseUri,
        accessToken: widget.accessToken,
      );

  MeetingMemberProfile? get _selfMember {
    final username = widget.currentUsername.trim();
    if (username.isEmpty) return null;
    for (final member in _memberProfiles) {
      if (member.username.trim() == username) {
        return member;
      }
    }
    return null;
  }

  String get _myRole => (_selfMember?.role ?? '').trim().toLowerCase();
  bool get _canRaiseHand => canRaiseHandForRole(_myRole);
  bool get _canSendChat {
    if (!_chatAllowedByMeeting) return false;
    final self = _selfMember;
    if (self == null) return true;
    return self.allowChat;
  }

  @override
  void initState() {
    super.initState();
    _waitingRoomEnabled = widget.joinPayload.waitingRoomEnabled;
    _allowGuestLinkJoin = widget.joinPayload.allowGuestLinkJoin;
    _allowChat = widget.joinPayload.allowChat;
    _allowScreenShare = widget.joinPayload.allowScreenShare;
    _allowSelfUnmute = widget.joinPayload.allowSelfUnmute;
    _allowMemberVideo = widget.joinPayload.allowMemberVideo;
    if (widget.initialMemberProfiles.isNotEmpty) {
      _memberProfiles = List<MeetingMemberProfile>.from(
        widget.initialMemberProfiles,
      );
    }
    if (widget.initialMessages.isNotEmpty) {
      _messages = List<ChatMessage>.from(widget.initialMessages);
    }
    if (widget.autoConnect) {
      _connect();
    } else {
      _connecting = false;
      _status = '会议界面已就绪';
    }
    if (widget.autoConnect && _hasMeetingRef) {
      unawaited(_bootstrapPanels());
    }
  }

  @override
  void dispose() {
    _stopPolling();
    _disposeAllZoomControllers();
    _remoteControlFocusNode.dispose();
    _chatInputController.dispose();
    _chatScrollController.dispose();
    unawaited(_disposeRoom());
    super.dispose();
  }

  void _startPolling() {
    if (!_hasMeetingRef) return;
    _memberPollTimer ??= Timer.periodic(
      const Duration(seconds: 6),
      (_) => unawaited(_loadMembers(silent: true)),
    );
    _messagePollTimer ??= Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_loadMessages(silent: true)),
    );
  }

  void _stopPolling() {
    _recordingStatusTimer?.cancel();
    _recordingStatusTimer = null;
    _memberPollTimer?.cancel();
    _memberPollTimer = null;
    _messagePollTimer?.cancel();
    _messagePollTimer = null;
  }

  Future<void> _bootstrapPanels() async {
    await _loadMembers(silent: true);
    await _loadMessages(silent: true);
    await _syncRecordingStatus(silent: true);
    await _loadWaitingRoomEntries(silent: true);
    _startPolling();
  }

  void _startRecordingStatusPolling() {
    if (_recordingStatusTimer != null || !_hasMeetingRef) return;
    _recordingStatusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_recordingActive || _leaving) return;
      unawaited(_syncRecordingStatus(silent: true));
    });
  }

  Future<void> _joinMeeting() async {
    if (_connected || _connecting || _leaving) return;
    await _connect();
    if (!mounted || !_connected) return;
    if (_hasMeetingRef) {
      unawaited(_bootstrapPanels());
    }
  }

  Future<void> _connect() async {
    if (_connected) return;
    if (_connecting && _room != null) return;
    await _disposeRoom();
    if (!mounted) return;
    final room = lk.Room();
    final listener = room.createListener()
      ..on<lk.RoomConnectedEvent>((_) {
        if (!mounted) return;
        setState(() {
          _status = '已连接';
          _connecting = false;
          _connected = true;
        });
      })
      ..on<lk.RoomDisconnectedEvent>((event) {
        if (!mounted) return;
        setState(() {
          _status = event.reason == null ? '连接已断开' : '连接断开：${event.reason}';
          _connecting = false;
          _connected = false;
          _fullscreenIdentity = null;
          _spotlightIdentity = null;
          _remoteControlSessionId = null;
          _remoteControlTargetIdentity = null;
          _remoteControlControlledByIdentity = null;
          _remoteControlPendingTargetIdentity = null;
          _remoteControlPendingRequestId = null;
          _remoteControlLastPointerMoveAt = null;
          _remoteControlLastPointerButton = 'left';
        });
      })
      ..on<lk.ParticipantEvent>((_) {
        if (mounted) setState(() {});
      })
      ..on<lk.DataReceivedEvent>((event) {
        unawaited(_handleRemoteControlDataReceived(event));
      });

    room.addListener(() {
      if (mounted) setState(() {});
    });

    setState(() {
      _room = room;
      _roomListener = listener;
      _status = '正在连接会议 ${widget.joinPayload.roomName}...';
      _connecting = true;
      _connected = false;
    });

    try {
      await room.connect(
          widget.joinPayload.livekitUrl, widget.joinPayload.token);
      await room.localParticipant?.setMicrophoneEnabled(_micEnabled);
      await room.localParticipant?.setCameraEnabled(_cameraEnabled);
      if (!mounted) return;
      setState(() {
        _status = '已连接';
        _connecting = false;
        _connected = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = '连接失败：$error';
        _connecting = false;
        _connected = false;
      });
    }
  }

  Future<void> _disposeRoom() async {
    final listener = _roomListener;
    final room = _room;
    _roomListener = null;
    _room = null;
    _connected = false;
    _fullscreenIdentity = null;
    _spotlightIdentity = null;
    _remoteControlSessionId = null;
    _remoteControlTargetIdentity = null;
    _remoteControlControlledByIdentity = null;
    _remoteControlPendingTargetIdentity = null;
    _remoteControlPendingRequestId = null;
    _remoteControlLastPointerMoveAt = null;
    _remoteControlLastPointerButton = 'left';
    await listener?.dispose();
    if (room != null) {
      try {
        await room.disconnect();
      } catch (_) {}
      await room.dispose();
    }
  }

  Future<void> _leaveRoom() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    await _stopRemoteControlSession(
      notifyPeer: true,
      reason: 'controller_leave',
      silent: true,
    );
    _stopPolling();
    await _disposeRoom();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _toggleMic() async {
    final room = _room;
    if (room == null) return;
    final next = !_micEnabled;
    await room.localParticipant?.setMicrophoneEnabled(next);
    if (!mounted) return;
    setState(() => _micEnabled = next);
  }

  Future<void> _toggleCamera() async {
    final room = _room;
    if (room == null) return;
    final next = !_cameraEnabled;
    await room.localParticipant?.setCameraEnabled(next);
    if (!mounted) return;
    setState(() => _cameraEnabled = next);
  }

  Future<void> _toggleScreenShare() async {
    final room = _room;
    if (room == null) {
      if (mounted) {
        setState(() => _status = '当前未连接会议，无法共享屏幕');
      }
      return;
    }
    if (!_canScreenShare) {
      if (mounted) {
        setState(() => _status = '当前无屏幕共享权限');
      }
      return;
    }
    final local = room.localParticipant;
    if (local == null) {
      return;
    }
    final next = !_screenShareEnabled;
    final useDesktopPicker = shouldUseDesktopSourcePicker(
      isWeb: kIsWeb,
      platform: defaultTargetPlatform.name,
    );
    try {
      if (next) {
        String? sourceId;
        if (useDesktopPicker) {
          final picked = await _pickDesktopShareSource();
          if (picked == null) {
            if (mounted) {
              setState(() => _status = '已取消屏幕共享选择');
            }
            return;
          }
          sourceId = picked.id;
        }
        try {
          await _enableScreenShare(local: local, sourceId: sourceId);
        } catch (error) {
          if (!useDesktopPicker || !isScreenShareSourceNotFoundError(error)) {
            rethrow;
          }
          final retryPicked = await _pickDesktopShareSource();
          if (retryPicked == null) {
            if (mounted) {
              setState(() => _status = '已取消屏幕共享选择');
            }
            return;
          }
          await _enableScreenShare(local: local, sourceId: retryPicked.id);
        }
      } else {
        await local.setScreenShareEnabled(false);
      }
      if (!mounted) return;
      setState(() {
        _screenShareEnabled = next;
        _status = next ? '已开始屏幕共享' : '已停止屏幕共享';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = mapScreenShareErrorToStatus(error));
    }
  }

  Future<void> _enableScreenShare({
    required lk.LocalParticipant local,
    String? sourceId,
  }) {
    return local.setScreenShareEnabled(
      true,
      screenShareCaptureOptions: lk.ScreenShareCaptureOptions(
        sourceId: sourceId,
        maxFrameRate: 15.0,
        captureScreenAudio: false,
        params: lk.VideoParametersPresets.screenShareH1080FPS15,
      ),
    );
  }

  Future<rtc.DesktopCapturerSource?> _pickDesktopShareSource() async {
    final sources = await rtc.desktopCapturer.getSources(
      types: const [rtc.SourceType.Screen, rtc.SourceType.Window],
      thumbnailSize: rtc.ThumbnailSize(640, 360),
    );
    if (sources.isEmpty) {
      return null;
    }
    if (!mounted) {
      return null;
    }
    final sorted = List<rtc.DesktopCapturerSource>.from(sources)
      ..sort((a, b) {
        final typeOrderA = a.type == rtc.SourceType.Screen ? 0 : 1;
        final typeOrderB = b.type == rtc.SourceType.Screen ? 0 : 1;
        if (typeOrderA != typeOrderB) {
          return typeOrderA.compareTo(typeOrderB);
        }
        return a.name
            .trim()
            .toLowerCase()
            .compareTo(b.name.trim().toLowerCase());
      });
    return showDialog<rtc.DesktopCapturerSource>(
      context: context,
      builder: (_) => NativeShareSourcePickerDialog(sources: sorted),
    );
  }

  String _resolvedShareUrl() {
    if (!_hasMeetingRef) {
      return '';
    }
    final uri =
        widget.baseUri.resolve('/m/${Uri.encodeComponent(_meetingRef)}');
    return uri.toString();
  }

  String _meetingShareText() {
    return buildNativeMeetingShareText(
      meetingTitle: widget.meetingTitle,
      roomName: widget.joinPayload.roomName,
      meetingRef: _meetingRef,
      shareUrl: _resolvedShareUrl(),
    );
  }

  Future<void> _copyText(String text, String successText) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _status = successText);
  }

  Future<void> _sendRemoteControlMessage({
    required RemoteControlMessageKind kind,
    required Map<String, dynamic> payload,
    required List<String> destinationIdentities,
  }) async {
    final local = _room?.localParticipant;
    if (!_connected || local == null) return;
    await local.publishData(
      utf8.encode(jsonEncode(payload)),
      reliable: shouldSendRemoteControlReliably(kind),
      destinationIdentities: destinationIdentities,
      topic: remoteControlDataTopic,
    );
  }

  Future<void> _requestRemoteControlForMember(
      MeetingMemberProfile member) async {
    final localIdentity = _localIdentity;
    final targetIdentity = _identityForMember(member);
    if (localIdentity == null || targetIdentity == null) {
      if (mounted) {
        setState(() => _status = '该成员当前不在线，无法发起远程控制');
      }
      return;
    }
    if (targetIdentity == localIdentity) {
      if (mounted) {
        setState(() => _status = '不能控制自己的设备');
      }
      return;
    }
    if (_isRemoteControlActiveForIdentity(targetIdentity)) {
      if (mounted) {
        setState(() => _status = '已在控制该成员');
      }
      return;
    }
    if (_isBeingRemoteControlled) {
      if (mounted) {
        setState(() => _status = '你正在被远程控制，请先结束当前会话');
      }
      return;
    }
    if (_isRemoteControlPendingForIdentity(targetIdentity)) {
      if (mounted) {
        setState(() => _status = '请求已发送，等待对方确认');
      }
      return;
    }
    if (!_canPublishRemoteControlData) {
      if (mounted) {
        setState(() => _status = '当前权限不允许发起远程控制');
      }
      return;
    }
    if (_remoteControlSessionId != null) {
      await _stopRemoteControlSession(
        notifyPeer: true,
        reason: 'controller_switch',
        silent: true,
      );
    }
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 20)}';
    if (mounted) {
      setState(() {
        _remoteControlPendingTargetIdentity = targetIdentity;
        _remoteControlPendingRequestId = requestId;
      });
    }
    try {
      await _sendRemoteControlMessage(
        kind: RemoteControlMessageKind.request,
        payload: buildRemoteControlRequestMessage(
          requestId: requestId,
          controllerIdentity: localIdentity,
          targetIdentity: targetIdentity,
        ),
        destinationIdentities: <String>[targetIdentity],
      );
      if (mounted) {
        final targetName = member.displayName.trim().isNotEmpty
            ? member.displayName.trim()
            : member.username.trim();
        setState(() => _status = '已向 $targetName 发送远程控制请求');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _remoteControlPendingTargetIdentity = null;
        _remoteControlPendingRequestId = null;
        _status = '远程控制请求失败：$error';
      });
    }
  }

  Future<void> _stopRemoteControlSession({
    bool notifyPeer = true,
    String reason = '',
    bool silent = false,
  }) async {
    final localIdentity = _localIdentity;
    final sessionId = _remoteControlSessionId;
    final targetIdentity = _remoteControlTargetIdentity;
    final controlledBy = _remoteControlControlledByIdentity;
    if (notifyPeer && localIdentity != null && sessionId != null) {
      String? peerIdentity;
      if (targetIdentity != null) {
        peerIdentity = targetIdentity;
      } else if (controlledBy != null && controlledBy.trim().isNotEmpty) {
        peerIdentity = controlledBy;
      }
      if (peerIdentity != null) {
        try {
          await _sendRemoteControlMessage(
            kind: RemoteControlMessageKind.stop,
            payload: buildRemoteControlStopMessage(
              requestId: sessionId,
              controllerIdentity: targetIdentity != null
                  ? localIdentity
                  : (controlledBy ?? localIdentity),
              targetIdentity: targetIdentity ?? localIdentity,
              reason: reason,
            ),
            destinationIdentities: <String>[peerIdentity],
          );
        } catch (_) {}
      }
    }
    if (!mounted) return;
    setState(() {
      _remoteControlSessionId = null;
      _remoteControlTargetIdentity = null;
      _remoteControlControlledByIdentity = null;
      _remoteControlPendingTargetIdentity = null;
      _remoteControlPendingRequestId = null;
      _remoteControlLastPointerMoveAt = null;
      _remoteControlLastPointerButton = 'left';
    });
    if (!silent) {
      setState(() => _status = '远程控制已结束');
    }
  }

  Future<void> _handleRemoteControlDataReceived(
      lk.DataReceivedEvent event) async {
    if (event.topic != remoteControlDataTopic) return;
    final senderIdentity = event.participant?.identity.trim() ?? '';
    if (senderIdentity.isEmpty) return;
    final parsed = parseRemoteControlMessage(utf8.decode(event.data));
    if (parsed == null) return;
    final localIdentity = _localIdentity;
    if (localIdentity == null) return;

    switch (parsed.kind) {
      case RemoteControlMessageKind.request:
        if (parsed.targetIdentity != localIdentity ||
            parsed.controllerIdentity != senderIdentity) {
          return;
        }
        await _handleIncomingRemoteControlRequest(parsed, senderIdentity);
        return;
      case RemoteControlMessageKind.response:
        if (parsed.controllerIdentity != localIdentity ||
            parsed.targetIdentity != senderIdentity) {
          return;
        }
        if (_remoteControlPendingRequestId != parsed.requestId ||
            _remoteControlPendingTargetIdentity != parsed.targetIdentity) {
          return;
        }
        if (!mounted) return;
        setState(() {
          _remoteControlPendingRequestId = null;
          _remoteControlPendingTargetIdentity = null;
        });
        if (parsed.approved == true) {
          if (!mounted) return;
          setState(() {
            _remoteControlSessionId = parsed.requestId;
            _remoteControlTargetIdentity = parsed.targetIdentity;
            _remoteControlControlledByIdentity = null;
            _remoteControlLastPointerMoveAt = null;
            _remoteControlLastPointerButton = 'left';
            _status =
                '远程控制已连接：${_displayNameForIdentity(parsed.targetIdentity)}';
          });
          _focusParticipantTile(parsed.targetIdentity, allowToggle: false);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _remoteControlFocusNode.requestFocus();
          });
        } else {
          final reason = parsed.reason?.trim() ?? '';
          if (!mounted) return;
          setState(() {
            _status = reason.isEmpty ? '对方已拒绝远程控制' : '对方已拒绝远程控制：$reason';
          });
        }
        return;
      case RemoteControlMessageKind.stop:
        final sessionId = _remoteControlSessionId;
        if (sessionId == null || sessionId != parsed.requestId) {
          return;
        }
        final isControllerSide = _remoteControlTargetIdentity != null &&
            parsed.controllerIdentity == _localIdentity &&
            parsed.targetIdentity == senderIdentity;
        final isTargetSide = _remoteControlControlledByIdentity != null &&
            parsed.controllerIdentity == senderIdentity &&
            parsed.targetIdentity == _localIdentity;
        if (!isControllerSide && !isTargetSide) return;
        await _stopRemoteControlSession(notifyPeer: false, silent: true);
        if (mounted) {
          setState(() => _status = '远程控制会话已结束');
        }
        return;
      case RemoteControlMessageKind.pointer:
      case RemoteControlMessageKind.wheel:
      case RemoteControlMessageKind.key:
        final allowAsTarget = parsed.targetIdentity == localIdentity &&
            parsed.controllerIdentity == senderIdentity &&
            _remoteControlSessionId == parsed.requestId &&
            _remoteControlControlledByIdentity == senderIdentity;
        if (!allowAsTarget) return;
        _remoteInputInjector.apply(parsed);
        return;
    }
  }

  Future<void> _handleIncomingRemoteControlRequest(
    RemoteControlMessage message,
    String senderIdentity,
  ) async {
    if (_remoteControlSessionId != null &&
        _remoteControlControlledByIdentity != senderIdentity) {
      await _sendRemoteControlMessage(
        kind: RemoteControlMessageKind.response,
        payload: buildRemoteControlResponseMessage(
          requestId: message.requestId,
          controllerIdentity: message.controllerIdentity,
          targetIdentity: message.targetIdentity,
          approved: false,
          reason: 'target_busy',
        ),
        destinationIdentities: <String>[message.controllerIdentity],
      );
      return;
    }
    if (!mounted) return;
    final senderName = _displayNameForIdentity(senderIdentity);
    final approvedByUser = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('远程控制请求'),
            content: Text('$senderName 请求控制你的键盘和鼠标，是否允许？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('允许'),
              ),
            ],
          ),
        ) ??
        false;
    if (!mounted) return;
    var approved = approvedByUser;
    if (approvedByUser) {
      final screenReady = await _ensureRemoteControlTargetScreenShareReady();
      if (!screenReady) {
        approved = false;
      } else {
        setState(() {
          _remoteControlSessionId = message.requestId;
          _remoteControlTargetIdentity = null;
          _remoteControlControlledByIdentity = senderIdentity;
          _remoteControlPendingTargetIdentity = null;
          _remoteControlPendingRequestId = null;
          _status = '已允许 $senderName 远程控制';
        });
      }
    }
    await _sendRemoteControlMessage(
      kind: RemoteControlMessageKind.response,
      payload: buildRemoteControlResponseMessage(
        requestId: message.requestId,
        controllerIdentity: message.controllerIdentity,
        targetIdentity: message.targetIdentity,
        approved: approved,
        reason: approved
            ? ''
            : (approvedByUser
                ? 'target_screen_share_unavailable'
                : 'target_rejected'),
      ),
      destinationIdentities: <String>[message.controllerIdentity],
    );
  }

  Future<bool> _ensureRemoteControlTargetScreenShareReady() async {
    if (!shouldStartRemoteControlScreenShare(
      screenShareEnabled: _screenShareEnabled,
      canScreenShare: _canScreenShare,
    )) {
      if (_screenShareEnabled) return true;
      if (mounted) {
        setState(() => _status = remoteControlScreenShareRequiredStatusZh());
      }
      return false;
    }
    final room = _room;
    final local = room?.localParticipant;
    if (local == null) {
      if (mounted) {
        setState(() => _status = '当前未连接会议，无法开启屏幕共享');
      }
      return false;
    }
    try {
      final picked = await _pickDesktopShareSource();
      if (picked == null) {
        if (mounted) {
          setState(() => _status = '已取消屏幕共享选择，远程控制未开启');
        }
        return false;
      }
      try {
        await _enableScreenShare(local: local, sourceId: picked.id);
      } catch (error) {
        if (!isScreenShareSourceNotFoundError(error)) rethrow;
        final retryPicked = await _pickDesktopShareSource();
        if (retryPicked == null) {
          if (mounted) {
            setState(() => _status = '已取消屏幕共享选择，远程控制未开启');
          }
          return false;
        }
        await _enableScreenShare(local: local, sourceId: retryPicked.id);
      }
      if (mounted) {
        setState(() {
          _screenShareEnabled = true;
          _status = '已开启屏幕共享，可进行远程控制';
        });
      }
      return true;
    } catch (error) {
      if (mounted) {
        setState(() => _status = mapScreenShareErrorToStatus(error));
      }
      return false;
    }
  }

  Future<void> _sendRemotePointerEvent({
    required String event,
    required Offset localPosition,
    required Size size,
    String button = '',
  }) async {
    final requestId = _remoteControlSessionId;
    final targetIdentity = _remoteControlTargetIdentity;
    final localIdentity = _localIdentity;
    if (requestId == null || targetIdentity == null || localIdentity == null) {
      return;
    }
    if (size.width <= 1 || size.height <= 1) return;
    if (event == 'move') {
      final now = DateTime.now();
      final last = _remoteControlLastPointerMoveAt;
      if (last != null && now.difference(last).inMilliseconds < 12) {
        return;
      }
      _remoteControlLastPointerMoveAt = now;
    }
    final normalizedX = (localPosition.dx / size.width).clamp(0.0, 1.0);
    final normalizedY = (localPosition.dy / size.height).clamp(0.0, 1.0);
    final finalButton =
        button.trim().isEmpty ? _remoteControlLastPointerButton : button.trim();
    if (button.trim().isNotEmpty) {
      _remoteControlLastPointerButton = button.trim();
    }
    await _sendRemoteControlMessage(
      kind: RemoteControlMessageKind.pointer,
      payload: buildRemoteControlPointerMessage(
        requestId: requestId,
        controllerIdentity: localIdentity,
        targetIdentity: targetIdentity,
        event: event,
        x: normalizedX,
        y: normalizedY,
        button: finalButton,
      ),
      destinationIdentities: <String>[targetIdentity],
    );
  }

  Future<void> _sendRemoteWheelEvent(Offset scrollDelta) async {
    final requestId = _remoteControlSessionId;
    final targetIdentity = _remoteControlTargetIdentity;
    final localIdentity = _localIdentity;
    if (requestId == null || targetIdentity == null || localIdentity == null) {
      return;
    }
    final dx = scrollDelta.dx.round();
    final dy = scrollDelta.dy.round();
    if (dx == 0 && dy == 0) return;
    await _sendRemoteControlMessage(
      kind: RemoteControlMessageKind.wheel,
      payload: buildRemoteControlWheelMessage(
        requestId: requestId,
        controllerIdentity: localIdentity,
        targetIdentity: targetIdentity,
        deltaX: dx,
        deltaY: dy,
      ),
      destinationIdentities: <String>[targetIdentity],
    );
  }

  Future<void> _sendRemoteKeyEvent(KeyEvent event) async {
    final requestId = _remoteControlSessionId;
    final targetIdentity = _remoteControlTargetIdentity;
    final localIdentity = _localIdentity;
    if (requestId == null || targetIdentity == null || localIdentity == null) {
      return;
    }
    final phase = event is KeyUpEvent ? 'up' : 'down';
    final hidUsage = event.physicalKey.usbHidUsage;
    if (hidUsage == 0) return;
    await _sendRemoteControlMessage(
      kind: RemoteControlMessageKind.key,
      payload: buildRemoteControlKeyMessage(
        requestId: requestId,
        controllerIdentity: localIdentity,
        targetIdentity: targetIdentity,
        phase: phase,
        hidUsage: hidUsage,
        keyLabel: event.logicalKey.keyLabel,
      ),
      destinationIdentities: <String>[targetIdentity],
    );
  }

  String _pointerButtonFromButtons(int buttons) {
    if ((buttons & 1) == 1) return 'left';
    if ((buttons & 2) == 2) return 'right';
    if ((buttons & 4) == 4) return 'middle';
    return _remoteControlLastPointerButton;
  }

  Future<void> _openMeetingInfoDialog() async {
    final infoText = _meetingShareText();
    final roomName = widget.joinPayload.roomName.trim();
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('会议信息'),
          content: SelectableText(infoText),
          actions: [
            TextButton.icon(
              onPressed: roomName.isEmpty
                  ? null
                  : () {
                      unawaited(_copyText(roomName, '会议号已复制'));
                    },
              icon: const Icon(Icons.pin_outlined, size: 18),
              label: const Text('复制会议号'),
            ),
            TextButton.icon(
              onPressed: () {
                unawaited(_copyText(infoText, '会议信息已复制'));
              },
              icon: const Icon(Icons.content_copy_outlined, size: 18),
              label: const Text('复制会议信息'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadWaitingRoomEntries({bool silent = false}) async {
    if (!_canUseModeratorControls) {
      if (mounted && _waitingRoomEntries.isNotEmpty) {
        setState(() => _waitingRoomEntries = const <WaitingRoomEntry>[]);
      }
      return;
    }
    try {
      final rows = await _client.fetchWaitingRoomEntriesByRef(
        meetingRef: _meetingRef,
      );
      if (!mounted) return;
      setState(() => _waitingRoomEntries = rows);
    } catch (error) {
      if (!silent && mounted) {
        setState(() => _status = '读取等候室失败：$error');
      }
    }
  }

  bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }

  void _applyControlFlags(Map<String, dynamic> payload) {
    _waitingRoomEnabled =
        _asBool(payload['waiting_room_enabled'], _waitingRoomEnabled);
    _allowGuestLinkJoin =
        _asBool(payload['allow_guest_link_join'], _allowGuestLinkJoin);
    _allowChat = _asBool(payload['allow_chat'], _allowChat);
    _allowScreenShare =
        _asBool(payload['allow_screen_share'], _allowScreenShare);
    _allowSelfUnmute = _asBool(payload['allow_self_unmute'], _allowSelfUnmute);
    _allowMemberVideo =
        _asBool(payload['allow_member_video'], _allowMemberVideo);
  }

  Future<void> _patchMeetingControls(Map<String, dynamic> payload) async {
    if (!_canUseModeratorControls || payload.isEmpty) return;
    final response = await _client.patchMeetingControlsByRef(
      meetingRef: _meetingRef,
      payload: payload,
    );
    if (!mounted) return;
    setState(() {
      _applyControlFlags(response.isEmpty ? payload : response);
      if (!_allowChat) {
        _messages = const <ChatMessage>[];
      }
      if (!_waitingRoomEnabled) {
        _waitingRoomEntries = const <WaitingRoomEntry>[];
      }
    });
    await _loadMembers(silent: true);
    if (_allowChat) {
      await _loadMessages(silent: true);
    }
    if (_waitingRoomEnabled) {
      await _loadWaitingRoomEntries(silent: true);
    }
  }

  Future<void> _muteAllMembers() async {
    if (!_canUseModeratorControls || _moderationBusy) return;
    setState(() => _moderationBusy = true);
    try {
      final payload =
          await _client.muteAllMembersByRef(meetingRef: _meetingRef);
      final mutedCount = (payload['muted_count'] ?? 0).toString();
      if (!mounted) return;
      setState(() => _status = '已执行全员静音：$mutedCount 人');
      await _loadMembers(silent: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '全员静音失败：$error');
    } finally {
      if (mounted) {
        setState(() => _moderationBusy = false);
      }
    }
  }

  List<({String value, String label, bool danger})> _memberManagementMenuItems(
    MeetingMemberProfile member,
  ) {
    final roleKey = member.role.trim().toLowerCase();
    if (roleKey == 'host') {
      return const <({String value, String label, bool danger})>[];
    }
    final items = <({String value, String label, bool danger})>[
      (
        value: member.mutedByHost ? 'unmute' : 'mute',
        label: member.mutedByHost ? '允许开麦' : '静音成员',
        danger: false,
      ),
      (
        value: member.videoBlockedByHost ? 'video_on' : 'video_off',
        label: member.videoBlockedByHost ? '允许开视频' : '关闭成员视频',
        danger: false,
      ),
      (
        value: member.allowSelfUnmute
            ? 'mic_permission_block'
            : 'mic_permission_allow',
        label: member.allowSelfUnmute ? '禁止开麦（权限）' : '允许开麦（权限）',
        danger: false,
      ),
      (
        value: member.allowMemberVideo
            ? 'video_permission_block'
            : 'video_permission_allow',
        label: member.allowMemberVideo ? '禁止开视频（权限）' : '允许开视频（权限）',
        danger: false,
      ),
      (
        value: member.allowChat
            ? 'chat_permission_block'
            : 'chat_permission_allow',
        label: member.allowChat ? '禁止聊天（权限）' : '允许聊天（权限）',
        danger: false,
      ),
      (
        value: member.allowScreenShare
            ? 'share_permission_block'
            : 'share_permission_allow',
        label: member.allowScreenShare ? '禁止共享（权限）' : '允许共享（权限）',
        danger: false,
      ),
      if (roleKey == 'participant')
        (value: 'set_cohost', label: '设为联席主持人', danger: false),
      if (roleKey == 'cohost')
        (value: 'set_participant', label: '取消联席主持人', danger: false),
      (value: 'remove', label: '移出成员（可重进）', danger: true),
      (value: 'remove_ban', label: '移出并封禁', danger: true),
    ];
    return items;
  }

  List<({String value, String label, bool danger})> _memberRowMenuItems({
    required MeetingMemberProfile member,
    required bool isSelf,
  }) {
    if (isSelf) {
      return const <({String value, String label, bool danger})>[
        (value: 'rename_self', label: '修改本次显示名', danger: false),
      ];
    }
    final items = <({String value, String label, bool danger})>[];
    final memberIdentity = _identityForMember(member);
    final remoteControlAvailable =
        memberIdentity != null && _connected && _canPublishRemoteControlData;
    if (remoteControlAvailable) {
      if (_isRemoteControlActiveForIdentity(memberIdentity)) {
        items.add(
          (
            value: 'stop_remote_control',
            label: '结束远程控制',
            danger: false,
          ),
        );
      } else {
        items.add(
          (
            value: 'request_remote_control',
            label: _isRemoteControlPendingForIdentity(memberIdentity)
                ? '远程请求已发送'
                : '请求远程控制',
            danger: false,
          ),
        );
      }
    }
    if (!_canUseModeratorControls) {
      return items;
    }
    final roleKey = member.role.trim().toLowerCase();
    if (roleKey == 'host') {
      return items;
    }
    items.add((value: 'rename_member', label: '成员改名', danger: false));
    items.addAll(_memberManagementMenuItems(member));
    return items;
  }

  Future<void> _openRenameMemberDialog({
    required MeetingMemberProfile member,
    required bool isSelf,
  }) async {
    if (!_hasMeetingRef) {
      if (!mounted) return;
      setState(() => _status = '当前会议缺少标识，无法修改显示名');
      return;
    }
    final userId = member.userId;
    if (userId <= 0) {
      if (!mounted) return;
      setState(() => _status = '当前成员不支持改名');
      return;
    }
    final initialName = member.displayName.trim().isNotEmpty
        ? member.displayName.trim()
        : member.username.trim();
    final controller = TextEditingController(text: initialName);
    final saved = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(isSelf ? '修改本次显示名' : '成员改名'),
            content: TextField(
              controller: controller,
              maxLength: 80,
              decoration: const InputDecoration(labelText: '显示名'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('保存'),
              ),
            ],
          ),
        ) ??
        false;
    final nextName = controller.text.trim();
    controller.dispose();
    if (!saved) return;
    if (nextName.isEmpty) {
      if (!mounted) return;
      setState(() => _status = '显示名不能为空');
      return;
    }
    if (nextName == initialName) {
      return;
    }
    if (!isSelf && !_canUseModeratorControls) {
      return;
    }
    try {
      await _client.patchMeetingMemberActionByRef(
        meetingRef: _meetingRef,
        userId: userId,
        action: 'display-name',
        payload: <String, dynamic>{'display_name': nextName},
      );
      if (!mounted) return;
      setState(() => _status = isSelf ? '显示名已更新' : '成员显示名已更新');
      await _loadMembers(silent: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = isSelf ? '修改显示名失败：$error' : '成员改名失败：$error');
    }
  }

  Future<void> _handleMemberRowMenuAction({
    required MeetingMemberProfile member,
    required bool isSelf,
    required String action,
  }) async {
    switch (action) {
      case 'rename_self':
        await _openRenameMemberDialog(member: member, isSelf: true);
        return;
      case 'rename_member':
        await _openRenameMemberDialog(member: member, isSelf: false);
        return;
      case 'request_remote_control':
        await _requestRemoteControlForMember(member);
        return;
      case 'stop_remote_control':
        await _stopRemoteControlSession(reason: 'controller_stop');
        return;
      default:
        await _handleMemberManagementAction(member: member, action: action);
    }
  }

  Future<bool> _confirmMemberActionDialog({
    required String title,
    required String content,
    required String confirmText,
  }) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(confirmText),
              ),
            ],
          ),
        ) ??
        false;
    return confirmed;
  }

  Future<void> _handleMemberManagementAction({
    required MeetingMemberProfile member,
    required String action,
  }) async {
    if (!_canUseModeratorControls || _moderationBusy) return;
    final userId = member.userId;
    if (userId <= 0) {
      setState(() => _status = '当前成员不支持此操作');
      return;
    }
    if (action == 'remove') {
      final confirmed = await _confirmMemberActionDialog(
        title: '移出成员',
        content: '确认移出 ${member.displayName} 吗？移出后该成员可重新入会。',
        confirmText: '确认移出',
      );
      if (!confirmed) return;
    }
    if (action == 'remove_ban') {
      final confirmed = await _confirmMemberActionDialog(
        title: '移出并封禁成员',
        content: '确认移出并封禁 ${member.displayName} 吗？封禁后该成员无法再次入会。',
        confirmText: '确认封禁',
      );
      if (!confirmed) return;
    }

    setState(() => _moderationBusy = true);
    try {
      var successText = '成员管理已完成';
      switch (action) {
        case 'mute':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'mute',
            payload: const <String, dynamic>{'muted': true},
          );
          successText = '已将成员静音';
          break;
        case 'unmute':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'mute',
            payload: const <String, dynamic>{'muted': false},
          );
          successText = '已允许成员开麦';
          break;
        case 'video_off':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'video',
            payload: const <String, dynamic>{'disabled': true},
          );
          successText = '已关闭成员视频';
          break;
        case 'video_on':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'video',
            payload: const <String, dynamic>{'disabled': false},
          );
          successText = '已允许成员开视频';
          break;
        case 'mic_permission_allow':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'mic-permission',
            payload: const <String, dynamic>{'allowed': true},
          );
          successText = '已允许该成员开麦';
          break;
        case 'mic_permission_block':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'mic-permission',
            payload: const <String, dynamic>{'allowed': false},
          );
          successText = '已禁止该成员开麦';
          break;
        case 'video_permission_allow':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'video-permission',
            payload: const <String, dynamic>{'allowed': true},
          );
          successText = '已允许该成员开视频';
          break;
        case 'video_permission_block':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'video-permission',
            payload: const <String, dynamic>{'allowed': false},
          );
          successText = '已禁止该成员开视频';
          break;
        case 'chat_permission_allow':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'chat-permission',
            payload: const <String, dynamic>{'allowed': true},
          );
          successText = '已允许该成员聊天';
          break;
        case 'chat_permission_block':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'chat-permission',
            payload: const <String, dynamic>{'allowed': false},
          );
          successText = '已禁止该成员聊天';
          break;
        case 'share_permission_allow':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'screen-share-permission',
            payload: const <String, dynamic>{'allowed': true},
          );
          successText = '已允许该成员屏幕共享';
          break;
        case 'share_permission_block':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'screen-share-permission',
            payload: const <String, dynamic>{'allowed': false},
          );
          successText = '已禁止该成员屏幕共享';
          break;
        case 'set_cohost':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'role',
            payload: const <String, dynamic>{'role': 'cohost'},
          );
          successText = '已设为联席主持人';
          break;
        case 'set_participant':
          await _client.patchMeetingMemberActionByRef(
            meetingRef: _meetingRef,
            userId: userId,
            action: 'role',
            payload: const <String, dynamic>{'role': 'participant'},
          );
          successText = '已取消联席主持人';
          break;
        case 'remove':
          await _client.deleteMeetingMemberByRef(
            meetingRef: _meetingRef,
            userId: userId,
            banAfterRemove: false,
          );
          successText = '已移出成员，可重新入会';
          break;
        case 'remove_ban':
          await _client.deleteMeetingMemberByRef(
            meetingRef: _meetingRef,
            userId: userId,
            banAfterRemove: true,
          );
          successText = '已移出成员并禁止再次入会';
          break;
        default:
          successText = '暂不支持该成员操作';
          break;
      }
      await _loadMembers(silent: true);
      if (!mounted) return;
      setState(() => _status = successText);
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '成员管理失败：$error');
    } finally {
      if (mounted) {
        setState(() => _moderationBusy = false);
      }
    }
  }

  Future<void> _reviewWaitingRoomEntry({
    required int userId,
    required String status,
    required String displayName,
  }) async {
    if (!_canUseModeratorControls || _moderationBusy) return;
    setState(() => _moderationBusy = true);
    try {
      await _client.reviewWaitingRoomEntryByRef(
        meetingRef: _meetingRef,
        userId: userId,
        status: status,
      );
      if (!mounted) return;
      setState(
        () => _status = status == 'approved'
            ? '已通过 $displayName 的入会申请'
            : '已拒绝 $displayName 的入会申请',
      );
      await _loadWaitingRoomEntries(silent: true);
      await _loadMembers(silent: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '等候室审核失败：$error');
    } finally {
      if (mounted) {
        setState(() => _moderationBusy = false);
      }
    }
  }

  List<MeetingMemberProfile> _hostTransferCandidates() {
    final selfUserId = _selfMember?.userId;
    final rows = _memberProfiles
        .where((member) => member.userId != selfUserId && member.role != 'host')
        .toList();
    int roleWeight(String role) {
      if (role == 'cohost') return 0;
      if (role == 'participant') return 1;
      return 2;
    }

    rows.sort((a, b) {
      final roleOrder = roleWeight(a.role).compareTo(roleWeight(b.role));
      if (roleOrder != 0) return roleOrder;
      return a.displayName.compareTo(b.displayName);
    });
    return rows;
  }

  Future<void> _openModeratorControlDialog() async {
    if (!_canUseModeratorControls || _moderationBusy) return;
    await _loadMembers(silent: true);
    await _loadWaitingRoomEntries(silent: true);
    if (!mounted) return;

    var busy = false;
    var errorText = '';
    var waitingRoomEnabled = _waitingRoomEnabled;
    var allowGuestLinkJoin = _allowGuestLinkJoin;
    var allowChat = _allowChat;
    var allowScreenShare = _allowScreenShare;
    var allowSelfUnmute = _allowSelfUnmute;
    var allowMemberVideo = _allowMemberVideo;
    var waitingEntries = List<WaitingRoomEntry>.from(_waitingRoomEntries);
    var transferCandidates = _hostTransferCandidates();
    int? transferUserId =
        transferCandidates.isEmpty ? null : transferCandidates.first.userId;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> updateControl(
              String key,
              bool value,
              void Function(bool value) assignLocal,
            ) async {
              if (busy) return;
              setDialogState(() {
                busy = true;
                errorText = '';
                assignLocal(value);
              });
              try {
                await _patchMeetingControls(<String, dynamic>{key: value});
                if (!mounted) return;
                setDialogState(() {
                  waitingRoomEnabled = _waitingRoomEnabled;
                  allowGuestLinkJoin = _allowGuestLinkJoin;
                  allowChat = _allowChat;
                  allowScreenShare = _allowScreenShare;
                  allowSelfUnmute = _allowSelfUnmute;
                  allowMemberVideo = _allowMemberVideo;
                  waitingEntries =
                      List<WaitingRoomEntry>.from(_waitingRoomEntries);
                  busy = false;
                  errorText = '';
                });
              } catch (error) {
                if (!mounted) return;
                setDialogState(() {
                  waitingRoomEnabled = _waitingRoomEnabled;
                  allowGuestLinkJoin = _allowGuestLinkJoin;
                  allowChat = _allowChat;
                  allowScreenShare = _allowScreenShare;
                  allowSelfUnmute = _allowSelfUnmute;
                  allowMemberVideo = _allowMemberVideo;
                  waitingEntries =
                      List<WaitingRoomEntry>.from(_waitingRoomEntries);
                  busy = false;
                  errorText = '$error';
                });
              }
            }

            Future<void> refreshWaitingEntries() async {
              if (!waitingRoomEnabled) {
                setDialogState(() {
                  waitingEntries = const <WaitingRoomEntry>[];
                  errorText = '';
                });
                return;
              }
              if (busy) return;
              setDialogState(() {
                busy = true;
                errorText = '';
              });
              try {
                final rows = await _client.fetchWaitingRoomEntriesByRef(
                    meetingRef: _meetingRef);
                if (!mounted) return;
                setState(() => _waitingRoomEntries = rows);
                waitingEntries = rows;
                transferCandidates = _hostTransferCandidates();
                if (transferCandidates.isNotEmpty) {
                  transferUserId ??= transferCandidates.first.userId;
                } else {
                  transferUserId = null;
                }
              } catch (error) {
                errorText = '$error';
              } finally {
                setDialogState(() => busy = false);
              }
            }

            Future<void> muteAll() async {
              if (busy) return;
              setDialogState(() {
                busy = true;
                errorText = '';
              });
              try {
                await _muteAllMembers();
                await refreshWaitingEntries();
              } catch (error) {
                errorText = '$error';
              } finally {
                setDialogState(() => busy = false);
              }
            }

            Future<void> review(WaitingRoomEntry entry, String status) async {
              if (busy) return;
              setDialogState(() {
                busy = true;
                errorText = '';
              });
              try {
                await _reviewWaitingRoomEntry(
                  userId: entry.userId,
                  status: status,
                  displayName: entry.displayName,
                );
                await refreshWaitingEntries();
              } catch (error) {
                errorText = '$error';
              } finally {
                setDialogState(() => busy = false);
              }
            }

            Future<void> transferAndLeave() async {
              if (busy || transferUserId == null) return;
              setDialogState(() {
                busy = true;
                errorText = '';
              });
              try {
                await _client.hostLeaveWithTransferByRef(
                  meetingRef: _meetingRef,
                  transferUserId: transferUserId!,
                );
                if (!mounted) return;
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
                setState(() => _status = '已转交主持人并离开会议');
                await _leaveRoom();
              } catch (error) {
                setDialogState(() {
                  busy = false;
                  errorText = '$error';
                });
              }
            }

            Future<void> endMeetingForAll() async {
              if (busy) return;
              setDialogState(() {
                busy = true;
                errorText = '';
              });
              try {
                await _client.endMeetingForAllByRef(meetingRef: _meetingRef);
                if (!mounted) return;
                if (!dialogContext.mounted) return;
                Navigator.of(dialogContext).pop();
                setState(() => _status = '会议已结束，所有成员已退会');
                await _leaveRoom();
              } catch (error) {
                setDialogState(() {
                  busy = false;
                  errorText = '$error';
                });
              }
            }

            return AlertDialog(
              title: const Text('主持管控'),
              content: SizedBox(
                width: 720,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile.adaptive(
                        value: waitingRoomEnabled,
                        onChanged: busy
                            ? null
                            : (value) => unawaited(updateControl(
                                  'waiting_room_enabled',
                                  value,
                                  (next) => waitingRoomEnabled = next,
                                )),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('开启等候室'),
                      ),
                      SwitchListTile.adaptive(
                        value: allowGuestLinkJoin,
                        onChanged: busy
                            ? null
                            : (value) => unawaited(updateControl(
                                  'allow_guest_link_join',
                                  value,
                                  (next) => allowGuestLinkJoin = next,
                                )),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('允许访客通过链接加入'),
                      ),
                      SwitchListTile.adaptive(
                        value: allowChat,
                        onChanged: busy
                            ? null
                            : (value) => unawaited(updateControl(
                                  'allow_chat',
                                  value,
                                  (next) => allowChat = next,
                                )),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('允许聊天'),
                      ),
                      SwitchListTile.adaptive(
                        value: allowScreenShare,
                        onChanged: busy
                            ? null
                            : (value) => unawaited(updateControl(
                                  'allow_screen_share',
                                  value,
                                  (next) => allowScreenShare = next,
                                )),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('允许屏幕共享'),
                      ),
                      SwitchListTile.adaptive(
                        value: allowSelfUnmute,
                        onChanged: busy
                            ? null
                            : (value) => unawaited(updateControl(
                                  'allow_self_unmute',
                                  value,
                                  (next) => allowSelfUnmute = next,
                                )),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('允许成员自我解除静音'),
                      ),
                      SwitchListTile.adaptive(
                        value: allowMemberVideo,
                        onChanged: busy
                            ? null
                            : (value) => unawaited(updateControl(
                                  'allow_member_video',
                                  value,
                                  (next) => allowMemberVideo = next,
                                )),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('允许成员开启视频'),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: busy ? null : () => unawaited(muteAll()),
                            icon: const Icon(Icons.mic_off),
                            label: const Text('全员静音'),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => unawaited(refreshWaitingEntries()),
                            icon: const Icon(Icons.refresh),
                            label: const Text('刷新等候室'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '等候室待审核',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      if (waitingEntries.isEmpty)
                        const Text('暂无待审核成员')
                      else
                        ...waitingEntries.map(
                          (entry) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(entry.displayName),
                            subtitle: Text(entry.username),
                            trailing: Wrap(
                              spacing: 6,
                              children: [
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () =>
                                          unawaited(review(entry, 'rejected')),
                                  child: const Text('拒绝'),
                                ),
                                FilledButton(
                                  onPressed: busy
                                      ? null
                                      : () =>
                                          unawaited(review(entry, 'approved')),
                                  child: const Text('通过'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (_isHost) ...[
                        const Divider(height: 24),
                        const Text(
                          '结束会议',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        if (transferCandidates.isEmpty)
                          const Text('当前无可转交主持人的在会成员')
                        else
                          DropdownButtonFormField<int>(
                            initialValue: transferUserId,
                            decoration:
                                const InputDecoration(labelText: '新主持人'),
                            items: transferCandidates
                                .map(
                                  (row) => DropdownMenuItem<int>(
                                    value: row.userId,
                                    child: Text(
                                        '${row.displayName}（${meetingRoleLabelZh(row.role)}）'),
                                  ),
                                )
                                .toList(),
                            onChanged: busy
                                ? null
                                : (value) => setDialogState(() {
                                      transferUserId = value;
                                    }),
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton(
                              onPressed: busy || transferUserId == null
                                  ? null
                                  : () => unawaited(transferAndLeave()),
                              child: const Text('转交主持并离会'),
                            ),
                            OutlinedButton(
                              onPressed: busy
                                  ? null
                                  : () => unawaited(endMeetingForAll()),
                              child: const Text('结束全部会议'),
                            ),
                          ],
                        ),
                      ],
                      if (errorText.trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          errorText,
                          style: TextStyle(color: _palette.danger),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      busy ? null : () => Navigator.of(dialogContext).pop(),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _syncRecordingStatus(
      {bool silent = false, int waitSeconds = 0}) async {
    if (!_hasMeetingRef) return;
    try {
      final payload = await _client.fetchRecordingEgressStatusByRef(
        meetingRef: _meetingRef,
        waitSeconds: waitSeconds,
      );
      _applyRecordingPayload(payload, silent: silent);
    } catch (_) {
      if (!silent && mounted) {
        setState(() => _status = '获取录制状态失败');
      }
    }
  }

  void _applyRecordingPayload(Map<String, dynamic> payload,
      {bool silent = true}) {
    final next = DesktopMeetingRecordingState.fromPayload(payload);
    if (!mounted) {
      _recordingState = next;
      return;
    }
    setState(() => _recordingState = next);
    if (next.active) {
      _startRecordingStatusPolling();
    } else {
      _recordingStatusTimer?.cancel();
      _recordingStatusTimer = null;
    }
    if (!silent) {
      setState(() {
        _status =
            describeRecordingStatus(state: next, uploading: _recordingBusy);
      });
    }
  }

  Future<void> _startRecording() async {
    if (_recordingBusy || _recordingActive) return;
    if (!_hasMeetingRef) {
      setState(() => _status = '当前会议缺少标识，无法发起录制');
      return;
    }
    if (!_canRecordMeeting) {
      setState(() => _status = '当前会议未开启录制权限');
      return;
    }
    setState(() {
      _recordingBusy = true;
      _status = '正在启动录制...';
    });
    try {
      final payload =
          await _client.startRecordingEgressByRef(meetingRef: _meetingRef);
      _applyRecordingPayload(payload, silent: false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '启动录制失败：$error');
    } finally {
      if (mounted) {
        setState(() => _recordingBusy = false);
      }
    }
  }

  Future<void> _stopRecording() async {
    if (_recordingBusy) return;
    if (!_hasMeetingRef) {
      setState(() => _status = '当前会议缺少标识，无法停止录制');
      return;
    }
    if (!_recordingActive && _recordingState.egressId.trim().isEmpty) {
      await _syncRecordingStatus(silent: true);
      if (!_recordingActive && _recordingState.egressId.trim().isEmpty) {
        if (mounted) setState(() => _status = '当前没有进行中的录制');
        return;
      }
    }
    setState(() {
      _recordingBusy = true;
      _status = '正在停止录制...';
    });
    try {
      final payload =
          await _client.stopRecordingEgressByRef(meetingRef: _meetingRef);
      _applyRecordingPayload(payload, silent: false);
      if (_recordingState.active) {
        await _syncRecordingStatus(silent: false, waitSeconds: 20);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '停止录制失败：$error');
    } finally {
      if (mounted) {
        setState(() => _recordingBusy = false);
      }
    }
  }

  Future<void> _loadMembers({bool silent = false}) async {
    if (!_hasMeetingRef) return;
    if (!silent && mounted) {
      setState(() => _loadingMembers = true);
    }
    try {
      final members =
          await _client.fetchMeetingMembersByRef(meetingRef: _meetingRef);
      if (!mounted) return;
      setState(() {
        _memberProfiles = members;
        if (!_canUseModeratorControls) {
          _waitingRoomEntries = const <WaitingRoomEntry>[];
        }
      });
    } catch (_) {
      if (!silent && mounted) {
        setState(() => _status = '加载成员失败');
      }
    } finally {
      if (!silent && mounted) {
        setState(() => _loadingMembers = false);
      }
    }
  }

  Future<void> _loadMessages({bool silent = false}) async {
    if (!_hasMeetingRef) return;
    if (!silent && mounted) {
      setState(() => _loadingMessages = true);
    }
    try {
      final messages = await _client.fetchMeetingMessagesByRef(
          meetingRef: _meetingRef, limit: 120);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        final ids = _messages.map((row) => row.id).toSet();
        _recallingMessageIds.removeWhere((id) => !ids.contains(id));
      });
      _scrollChatToBottom();
    } catch (_) {
      if (!silent && mounted) {
        setState(() => _status = '加载聊天失败');
      }
    } finally {
      if (!silent && mounted) {
        setState(() => _loadingMessages = false);
      }
    }
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScrollController.hasClients) return;
      _chatScrollController
          .jumpTo(_chatScrollController.position.maxScrollExtent);
    });
  }

  Future<void> _sendMessage() async {
    if (_sendingMessage || !_canSendChat || !_hasMeetingRef) return;
    final content = _chatInputController.text.trim();
    if (content.isEmpty) return;
    setState(() => _sendingMessage = true);
    try {
      final message = await _client.sendMeetingMessageByRef(
        meetingRef: _meetingRef,
        content: content,
      );
      if (!mounted) return;
      setState(() {
        _messages = <ChatMessage>[..._messages, message];
        _chatInputController.clear();
        _status = '消息已发送';
      });
      _scrollChatToBottom();
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '发送消息失败：$error');
    } finally {
      if (mounted) {
        setState(() => _sendingMessage = false);
      }
    }
  }

  Future<void> _raiseHand(String rawRequestType) async {
    if (_raisingHand || !_canRaiseHand || !_hasMeetingRef) return;
    final requestType = normalizedRaiseHandRequestType(rawRequestType);
    setState(() {
      _raisingHand = true;
      _status = requestType == 'video' ? '正在申请视频权限...' : '正在申请麦克风权限...';
    });
    try {
      await _client.raiseHandByRef(
        meetingRef: _meetingRef,
        requestType: requestType,
      );
      if (!mounted) return;
      setState(() {
        _status = requestType == 'video' ? '已发送视频权限申请' : '已发送麦克风权限申请';
      });
      await _loadMembers(silent: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '举手失败：$error');
    } finally {
      if (mounted) {
        setState(() => _raisingHand = false);
      }
    }
  }

  List<MeetingMemberProfile> _sortedMemberProfiles() {
    final payloadRows = _memberProfiles
        .map(
          (member) => <String, dynamic>{
            'role': member.role,
            'display_name': member.displayName,
            'username': member.username,
            'raw': member,
          },
        )
        .toList();
    final sortedRows = sortMembersForDisplay(payloadRows);
    return sortedRows
        .map((row) => row['raw'])
        .whereType<MeetingMemberProfile>()
        .toList();
  }

  String _formatMessageTime(DateTime? value) {
    if (value == null) return '--:--';
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${twoDigits(value.hour)}:${twoDigits(value.minute)}';
  }

  String _chatSenderDisplayName(ChatMessage message) {
    final display = message.senderDisplayName.trim();
    if (display.isNotEmpty) {
      return display;
    }
    final username = message.senderUsername.trim();
    return username.isEmpty ? '成员' : username;
  }

  bool _isMyMessage(ChatMessage message) {
    final current = widget.currentUsername.trim();
    if (current.isEmpty) return false;
    return current == message.senderUsername.trim();
  }

  bool _canRecallMessage(ChatMessage message) {
    if (_isModerator) return true;
    if (!_isMyMessage(message)) return false;
    final createdAt = message.createdAt;
    if (createdAt == null) return false;
    return DateTime.now().difference(createdAt) <= const Duration(minutes: 3);
  }

  Future<void> _copyChatMessage(ChatMessage message) async {
    final content = message.content.trim();
    if (content.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    setState(() => _status = '消息已复制');
  }

  Future<void> _confirmRecallMessage(ChatMessage message) async {
    if (!_canRecallMessage(message)) return;
    if (_recallingMessageIds.contains(message.id)) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('撤回消息'),
            content: const Text('确定要撤回这条消息吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('撤回'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _recallMessage(message);
  }

  Future<void> _recallMessage(ChatMessage message) async {
    if (_recallingMessageIds.contains(message.id)) return;
    if (!_hasMeetingRef) {
      if (mounted) {
        setState(() => _status = '当前会议缺少标识，无法撤回消息');
      }
      return;
    }
    if (mounted) {
      setState(() => _recallingMessageIds.add(message.id));
    }
    try {
      await _client.deleteMeetingMessageByRef(
        meetingRef: _meetingRef,
        messageId: message.id,
      );
      if (!mounted) return;
      setState(() {
        _messages = _messages.where((row) => row.id != message.id).toList();
        _recallingMessageIds.remove(message.id);
        _status = '消息已撤回';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _recallingMessageIds.remove(message.id);
        _status = '撤回消息失败：$error';
      });
    }
  }

  IconData _chatMessageMenuIconData(ChatMessageMenuIcon icon) {
    switch (icon) {
      case ChatMessageMenuIcon.copy:
        return Icons.content_copy_outlined;
      case ChatMessageMenuIcon.recall:
        return Icons.undo_rounded;
    }
  }

  String _displayInitial(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) return '会';
    return String.fromCharCode(normalized.runes.first).toUpperCase();
  }

  void _appendEmoji(String emoji) {
    if (!_canSendChat) return;
    final old = _chatInputController.text;
    final next = old.isEmpty ? emoji : '$old $emoji';
    _chatInputController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  List<PopupMenuEntry<String>> _chatEmojiMenuItems() {
    const emojis = <String>[
      '👍',
      '👏',
      '🙏',
      '✅',
      '🎉',
      '🙂',
      '😄',
      '🤝',
    ];
    return emojis
        .map(
          (emoji) => PopupMenuItem<String>(
            value: emoji,
            child: Text(emoji, style: const TextStyle(fontSize: 18)),
          ),
        )
        .toList(growable: false);
  }

  List<lk.Participant> _livekitParticipants() {
    final room = _room;
    if (room == null) return const <lk.Participant>[];
    final participants = <lk.Participant>[];
    final local = room.localParticipant;
    if (local != null) participants.add(local);
    participants.addAll(room.remoteParticipants.values);
    return participants;
  }

  lk.VideoTrack? _preferredVideoTrack(lk.Participant participant) {
    final identity = _participantIdentity(participant);
    final remoteControlSessionActive = _remoteControlSessionId != null &&
        _remoteControlTargetIdentity == identity;
    if (remoteControlSessionActive) {
      for (final publication in participant.videoTrackPublications) {
        if (!publication.isScreenShare) continue;
        final track = publication.track;
        if (track != null && track is lk.VideoTrack && !track.muted) {
          return track;
        }
      }
    }
    for (final publication in participant.videoTrackPublications) {
      if (publication.isScreenShare) continue;
      final track = publication.track;
      if (track != null && track is lk.VideoTrack && !track.muted) {
        return track;
      }
    }
    for (final publication in participant.videoTrackPublications) {
      final track = publication.track;
      if (track != null && track is lk.VideoTrack && !track.muted) {
        return track;
      }
    }
    return null;
  }

  String _participantLabel(lk.Participant participant) {
    final name = participant.name.trim();
    if (name.isNotEmpty) return name;
    final identity = participant.identity.trim();
    return identity.isEmpty ? '参会者' : identity;
  }

  String _participantIdentity(lk.Participant participant) {
    final identity = participant.identity.trim();
    if (identity.isNotEmpty) {
      return identity;
    }
    final name = participant.name.trim();
    if (name.isNotEmpty) {
      return 'name:$name';
    }
    return 'participant:${participant.hashCode}';
  }

  lk.Participant? _participantByIdentity(String identity) {
    for (final participant in _livekitParticipants()) {
      if (_participantIdentity(participant) == identity) {
        return participant;
      }
    }
    return null;
  }

  int? _userIdFromIdentity(String identity) {
    final normalized = identity.trim();
    if (!normalized.startsWith('u')) return null;
    final marker = normalized.indexOf('_');
    final numeric =
        marker > 1 ? normalized.substring(1, marker) : normalized.substring(1);
    return int.tryParse(numeric);
  }

  String _usernameFromIdentity(String identity) {
    final normalized = identity.trim();
    final marker = normalized.indexOf('_');
    if (marker <= 0 || marker + 1 >= normalized.length) {
      return '';
    }
    return normalized.substring(marker + 1).trim();
  }

  String? _identityForMember(MeetingMemberProfile member) {
    final room = _room;
    if (room == null) return null;
    final expectedUserId = member.userId;
    final expectedUsername = member.username.trim().toLowerCase();
    for (final participant in _livekitParticipants()) {
      final identity = participant.identity.trim();
      if (identity.isEmpty) continue;
      if (expectedUserId > 0) {
        final parsedUserId = _userIdFromIdentity(identity);
        if (parsedUserId != null && parsedUserId == expectedUserId) {
          return identity;
        }
      }
      if (expectedUsername.isNotEmpty) {
        final parsedUsername = _usernameFromIdentity(identity).toLowerCase();
        if (parsedUsername.isNotEmpty && parsedUsername == expectedUsername) {
          return identity;
        }
      }
    }
    return null;
  }

  String _displayNameForIdentity(String identity) {
    final participant = _participantByIdentity(identity);
    if (participant != null) {
      final label = _participantLabel(participant).trim();
      if (label.isNotEmpty) return label;
    }
    final parsedUserId = _userIdFromIdentity(identity);
    if (parsedUserId != null) {
      for (final member in _memberProfiles) {
        if (member.userId == parsedUserId) {
          final displayName = member.displayName.trim();
          if (displayName.isNotEmpty) return displayName;
          final username = member.username.trim();
          if (username.isNotEmpty) return username;
        }
      }
    }
    final fallback = _usernameFromIdentity(identity);
    if (fallback.isNotEmpty) return fallback;
    return identity.trim();
  }

  void _focusParticipantTile(String identity, {bool allowToggle = true}) {
    if (!mounted) return;
    final previousIdentity = _spotlightIdentity;
    setState(() {
      if (allowToggle && _spotlightIdentity == identity) {
        _spotlightIdentity = null;
        _resetTileZoom(identity, rebuild: false);
      } else {
        _spotlightIdentity = identity;
        _resetTileZoom(identity, rebuild: false);
      }
    });
    if (previousIdentity != null && previousIdentity != _spotlightIdentity) {
      _resetTileZoom(previousIdentity, rebuild: false);
    }
  }

  void _toggleSpotlight(String identity) =>
      _focusParticipantTile(identity, allowToggle: true);

  TransformationController _zoomControllerFor(String identity) {
    return _tileZoomControllers.putIfAbsent(
      identity,
      () => TransformationController(),
    );
  }

  double _matrixScale(Matrix4 matrix) {
    final sx = matrix.storage[0].abs();
    final sy = matrix.storage[5].abs();
    final avg = (sx + sy) / 2;
    if (!avg.isFinite || avg <= 0) return 1;
    return avg;
  }

  double _zoomScaleOf(String identity) {
    final controller = _tileZoomControllers[identity];
    if (controller == null) return 1;
    return _matrixScale(controller.value);
  }

  void _setTileZoom(String identity, double targetScale) {
    final controller = _zoomControllerFor(identity);
    final current = _matrixScale(controller.value);
    final clamped =
        targetScale.clamp(_minTileZoomScale, _maxTileZoomScale).toDouble();
    if ((clamped - current).abs() < 0.01) {
      return;
    }
    final ratio = clamped / current;
    controller.value = controller.value.clone()
      ..scaleByDouble(ratio, ratio, 1, 1);
    if (mounted) {
      setState(() {});
    }
  }

  void _stepTileZoom(String identity, double factor) {
    final current = _zoomScaleOf(identity);
    _setTileZoom(identity, current * factor);
  }

  void _resetTileZoom(String identity, {bool rebuild = true}) {
    final controller = _tileZoomControllers[identity];
    if (controller == null) {
      return;
    }
    controller.value = Matrix4.identity();
    if (rebuild && mounted) {
      setState(() {});
    }
  }

  void _disposeAllZoomControllers() {
    for (final controller in _tileZoomControllers.values) {
      controller.dispose();
    }
    _tileZoomControllers.clear();
  }

  void _toggleTileFullscreen(String identity) {
    final isSameTile = _fullscreenIdentity == identity;
    if (isSameTile) {
      _resetTileZoom(identity, rebuild: false);
      if (mounted) {
        setState(() {
          _fullscreenIdentity = null;
        });
      }
      return;
    }
    final previousIdentity = _fullscreenIdentity;
    if (previousIdentity != null && previousIdentity != identity) {
      _resetTileZoom(previousIdentity, rebuild: false);
    }
    _resetTileZoom(identity, rebuild: false);
    if (mounted) {
      setState(() {
        _fullscreenIdentity = identity;
      });
    }
  }

  bool get _isTileFullscreenActive => _fullscreenIdentity != null;

  lk.Participant? _fullscreenParticipant() {
    final identity = _fullscreenIdentity;
    if (identity == null) return null;
    return _participantByIdentity(identity);
  }

  String _recordingDurationText() {
    final started = _recordingState.startedAt;
    if (!_recordingActive || started == null) return '';
    final seconds =
        DateTime.now().difference(started).inSeconds.clamp(0, 86400);
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remain = seconds % 60;
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    if (hours > 0) {
      return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(remain)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(remain)}';
  }

  Widget _buildRecordingChip() {
    final text =
        recordingBadgeText(state: _recordingState, uploading: _recordingBusy);
    final duration = _recordingDurationText();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _recordingActive
            ? const Color(0xFFFEE4E2)
            : const Color(0xFFEFF4FF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: _recordingActive
              ? const Color(0xFFFDA29B)
              : const Color(0xFFD1E0FF),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _recordingActive
                ? Icons.fiber_manual_record
                : Icons.radio_button_unchecked,
            size: 14,
            color: _recordingActive
                ? const Color(0xFFB42318)
                : const Color(0xFF175CD3),
          ),
          const SizedBox(width: 6),
          Text(
            duration.isEmpty ? text : '$text  $duration',
            style: TextStyle(
              color: _recordingActive
                  ? const Color(0xFFB42318)
                  : const Color(0xFF175CD3),
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMembersTab() {
    final sortedMembers = _sortedMemberProfiles();
    final onlineCount = sortedMembers.length;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '成员列表',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新成员',
                    onPressed: _loadingMembers ? null : () => _loadMembers(),
                    icon: const Icon(Icons.refresh),
                  ),
                  if (_canRaiseHand)
                    PopupMenuButton<String>(
                      tooltip: '举手申请',
                      enabled: !_raisingHand,
                      onSelected: (value) => unawaited(_raiseHand(value)),
                      itemBuilder: (context) => const [
                        PopupMenuItem<String>(
                          value: 'mic',
                          child: Text('申请麦克风权限'),
                        ),
                        PopupMenuItem<String>(
                          value: 'video',
                          child: Text('申请视频权限'),
                        ),
                      ],
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.pan_tool_alt_outlined),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '$onlineCount 人在线',
                style: const TextStyle(
                  color: Color(0xFF475467),
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                '双击成员可放大对应画面',
                style: TextStyle(
                  color: Color(0xFF667085),
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
            decoration: BoxDecoration(
              color: _palette.surfaceMuted,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _palette.panelBorder),
            ),
            child: _loadingMembers && sortedMembers.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : sortedMembers.isEmpty
                    ? const Center(child: Text('暂无成员数据'))
                    : ListView.separated(
                        itemCount: sortedMembers.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final member = sortedMembers[index];
                          final displayName = member.displayName.trim().isEmpty
                              ? member.username.trim()
                              : member.displayName.trim();
                          final roleLabel = meetingRoleLabelZh(member.role);
                          final isSelf =
                              widget.currentUsername.trim().isNotEmpty &&
                                  widget.currentUsername.trim() ==
                                      member.username.trim();
                          final permissionTags = <String>[];
                          if (!member.allowChat) {
                            permissionTags.add('禁聊');
                          }
                          if (!member.allowSelfUnmute) {
                            permissionTags.add('禁麦');
                          }
                          if (!member.allowMemberVideo) {
                            permissionTags.add('禁视频');
                          }
                          if (!member.allowScreenShare) {
                            permissionTags.add('禁共享');
                          }
                          if (member.micRequestPending) {
                            permissionTags.add('麦克风申请中');
                          }
                          if (member.videoRequestPending) {
                            permissionTags.add('视频申请中');
                          }
                          if (permissionTags.isEmpty) {
                            permissionTags.add('权限正常');
                          }
                          final roleKey = member.role.trim().toLowerCase();
                          final menuItems = _memberRowMenuItems(
                            member: member,
                            isSelf: isSelf,
                          );
                          final canShowMenu = menuItems.isNotEmpty;
                          final roleStyle = switch (roleKey) {
                            'host' => const (
                                Color(0xFFFEE4E2),
                                Color(0xFFB42318),
                              ),
                            'cohost' => const (
                                Color(0xFFEFF4FF),
                                Color(0xFF175CD3),
                              ),
                            _ => const (Color(0xFFF2F4F7), Color(0xFF344054)),
                          };
                          return Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border:
                                  Border.all(color: const Color(0xFFE4E7EC)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 16,
                                  backgroundColor: const Color(0xFFEFF4FF),
                                  child: Text(
                                    _displayInitial(displayName),
                                    style: const TextStyle(
                                      color: Color(0xFF175CD3),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              isSelf
                                                  ? '$displayName（我）'
                                                  : displayName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Color(0xFF101828),
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: roleStyle.$1,
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              roleLabel,
                                              style: TextStyle(
                                                color: roleStyle.$2,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (member.username
                                          .trim()
                                          .isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          '@${member.username.trim()}',
                                          style: const TextStyle(
                                            color: Color(0xFF667085),
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: permissionTags.map((tag) {
                                          final warning = tag != '权限正常';
                                          return Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: warning
                                                  ? const Color(0xFFFFF4ED)
                                                  : const Color(0xFFECFDF3),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                              border: Border.all(
                                                color: warning
                                                    ? const Color(0xFFFEDF89)
                                                    : const Color(0xFFA6F4C5),
                                              ),
                                            ),
                                            child: Text(
                                              tag,
                                              style: TextStyle(
                                                color: warning
                                                    ? const Color(0xFFB54708)
                                                    : const Color(0xFF067647),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          );
                                        }).toList(growable: false),
                                      ),
                                    ],
                                  ),
                                ),
                                if (canShowMenu) ...[
                                  const SizedBox(width: 8),
                                  PopupMenuButton<String>(
                                    tooltip: '成员菜单',
                                    enabled: isSelf ? true : !_moderationBusy,
                                    onSelected: (value) => unawaited(
                                      _handleMemberRowMenuAction(
                                        member: member,
                                        isSelf: isSelf,
                                        action: value,
                                      ),
                                    ),
                                    itemBuilder: (context) => menuItems
                                        .map(
                                          (item) => PopupMenuItem<String>(
                                            value: item.value,
                                            child: Text(
                                              item.label,
                                              style: TextStyle(
                                                color: item.danger
                                                    ? const Color(0xFFB42318)
                                                    : const Color(0xFF101828),
                                                fontWeight: item.danger
                                                    ? FontWeight.w600
                                                    : FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        )
                                        .toList(growable: false),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _palette.surfaceRaised,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: _palette.panelBorder,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            isSelf
                                                ? Icons.more_horiz
                                                : Icons
                                                    .manage_accounts_outlined,
                                            size: 16,
                                            color: Color(0xFF344054),
                                          ),
                                          if (!isSelf) ...const [
                                            SizedBox(width: 4),
                                            Text(
                                              '管理',
                                              style: TextStyle(
                                                color: Color(0xFF344054),
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ),
      ],
    );
  }

  Widget _buildChatTab() {
    final chatDisabledReason =
        !_chatAllowedByMeeting ? '本会议已关闭聊天' : (!_canSendChat ? '你当前无聊天权限' : '');
    final chatEnabled = _canSendChat && !_sendingMessage;

    Widget buildChatBubble(ChatMessage item) {
      final isMine = _isMyMessage(item);
      final sender = _chatSenderDisplayName(item);
      final canRecall = _canRecallMessage(item);
      final isRecalling = _recallingMessageIds.contains(item.id);
      final messageMenuItems = buildChatMessageMenuSpecs(
        ChatMessageMenuBuilderInput(
          canRecall: canRecall,
          isRecalling: isRecalling,
        ),
      );
      final bubbleColor =
          isMine ? const Color(0xFFEFF4FF) : const Color(0xFFFFFFFF);
      final borderColor =
          isMine ? const Color(0xFFD1E0FF) : const Color(0xFFE4E7EC);
      final timeLabel = _formatMessageTime(item.createdAt);
      final crossAxis =
          isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
      final avatar = CircleAvatar(
        radius: 14,
        backgroundColor: item.isRealtimeBot
            ? const Color(0xFFFEE4E2)
            : const Color(0xFFEFF4FF),
        child: Text(
          _displayInitial(sender),
          style: TextStyle(
            color: item.isRealtimeBot
                ? const Color(0xFFB42318)
                : const Color(0xFF175CD3),
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment:
              isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            if (!isMine) ...[
              avatar,
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Column(
                crossAxisAlignment: crossAxis,
                children: [
                  Align(
                    alignment:
                        isMine ? Alignment.centerRight : Alignment.centerLeft,
                    child: PopupMenuButton<String>(
                      tooltip: '消息操作',
                      onSelected: (value) {
                        if (value == 'copy') {
                          unawaited(_copyChatMessage(item));
                          return;
                        }
                        if (value == 'recall') {
                          unawaited(_confirmRecallMessage(item));
                        }
                      },
                      itemBuilder: (context) => messageMenuItems
                          .map(
                            (spec) => PopupMenuItem<String>(
                              value: spec.value,
                              enabled: spec.enabled,
                              child: Row(
                                children: [
                                  Icon(
                                    _chatMessageMenuIconData(spec.icon),
                                    size: 16,
                                    color: spec.danger
                                        ? const Color(0xFFB42318)
                                        : const Color(0xFF344054),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    spec.title,
                                    style: TextStyle(
                                      color: spec.danger
                                          ? const Color(0xFFB42318)
                                          : const Color(0xFF101828),
                                      fontWeight: spec.danger
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(growable: false),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Icon(
                          Icons.more_horiz,
                          size: 18,
                          color: isRecalling
                              ? const Color(0xFF98A2B3)
                              : const Color(0xFF667085),
                        ),
                      ),
                    ),
                  ),
                  if (!isMine)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        sender,
                        style: const TextStyle(
                          color: Color(0xFF344054),
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  Container(
                    constraints: const BoxConstraints(maxWidth: 290),
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(14),
                        topRight: const Radius.circular(14),
                        bottomLeft: Radius.circular(isMine ? 14 : 4),
                        bottomRight: Radius.circular(isMine ? 4 : 14),
                      ),
                      border: Border.all(color: borderColor),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Text(
                      item.content,
                      style: const TextStyle(
                        color: Color(0xFF101828),
                        fontSize: 13.5,
                        height: 1.35,
                      ),
                    ),
                  ),
                  if (timeLabel.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        timeLabel,
                        style: const TextStyle(
                          color: Color(0xFF98A2B3),
                          fontSize: 10.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (isMine) ...[
              const SizedBox(width: 8),
              avatar,
            ],
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '会议聊天',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新聊天',
                    onPressed: _loadingMessages ? null : () => _loadMessages(),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '成员可撤回 3 分钟内消息，主持人与联席主持人可撤回任意消息',
                style: TextStyle(
                  color: Color(0xFF667085),
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 0, 10, 0),
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
            decoration: BoxDecoration(
              color: _palette.surfaceMuted,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _palette.panelBorder),
            ),
            child: _loadingMessages && _messages.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const Center(
                        child: Text(
                          '暂无聊天消息',
                          style: TextStyle(
                            color: Color(0xFF667085),
                            fontSize: 12.5,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _chatScrollController,
                        itemCount: _messages.length,
                        itemBuilder: (context, index) =>
                            buildChatBubble(_messages[index]),
                      ),
          ),
        ),
        if (chatDisabledReason.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            color: const Color(0xFFFFF4ED),
            child: Text(
              chatDisabledReason,
              style: const TextStyle(color: Color(0xFFB54708)),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                PopupMenuButton<String>(
                  tooltip: '发送表情',
                  enabled: chatEnabled,
                  onSelected: _appendEmoji,
                  itemBuilder: (context) => _chatEmojiMenuItems(),
                  icon: Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: chatEnabled
                          ? const Color(0xFFEFF4FF)
                          : const Color(0xFFF2F4F7),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: chatEnabled
                            ? const Color(0xFFD1E0FF)
                            : const Color(0xFFE4E7EC),
                      ),
                    ),
                    child: Icon(
                      Icons.emoji_emotions_outlined,
                      color: chatEnabled
                          ? const Color(0xFF175CD3)
                          : const Color(0xFF98A2B3),
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _chatInputController,
                    enabled: chatEnabled,
                    maxLines: 3,
                    minLines: 1,
                    decoration: const InputDecoration(hintText: '输入消息，支持表情'),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: chatEnabled ? _sendMessage : null,
                  child: Text(_sendingMessage ? '发送中...' : '发送'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildParticipantTile(
    lk.Participant participant, {
    bool forceFullscreen = false,
  }) {
    final identity = _participantIdentity(participant);
    final track = _preferredVideoTrack(participant);
    final micOn = participant.audioTrackPublications
        .any((publication) => !publication.muted);
    final camOn = participant.videoTrackPublications.any(
      (publication) => !publication.muted && !publication.isScreenShare,
    );
    final sharingScreen = participant.videoTrackPublications.any(
      (publication) => !publication.muted && publication.isScreenShare,
    );
    final label = _participantLabel(participant);
    final isFullscreen = forceFullscreen || _fullscreenIdentity == identity;
    final isSpotlight = _spotlightIdentity == identity;
    final canZoom = shouldShowTileZoomControls(
      hasVideoTrack: track != null,
      isSpotlight: isSpotlight,
      isFullscreen: isFullscreen,
    );
    final currentScale = _zoomScaleOf(identity);

    Widget mediaLayer = track != null
        ? lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.cover)
        : Container(
            color: _palette.primarySoft,
            alignment: Alignment.center,
            child: Icon(
              Icons.person_outline,
              size: 42,
              color: _palette.primaryStrong,
            ),
          );
    if (canZoom) {
      mediaLayer = InteractiveViewer(
        transformationController: _zoomControllerFor(identity),
        minScale: _minTileZoomScale,
        maxScale: _maxTileZoomScale,
        panEnabled: true,
        scaleEnabled: true,
        boundaryMargin: const EdgeInsets.all(120),
        clipBehavior: Clip.hardEdge,
        child: SizedBox.expand(child: mediaLayer),
      );
    }

    return GestureDetector(
      onDoubleTap: () => _toggleSpotlight(identity),
      child: Container(
        decoration: BoxDecoration(
          color: _palette.surfaceMuted,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSpotlight ? _palette.primary : _palette.primaryBorder,
            width: isSpotlight ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(child: mediaLayer),
            _buildRemoteControlOverlay(identity),
            Positioned(
              top: 8,
              right: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _palette.primary.withValues(alpha: 0.67),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: IconButton(
                  tooltip: isFullscreen ? '退出全屏' : '全屏显示该画面',
                  onPressed: () => _toggleTileFullscreen(identity),
                  icon: Icon(
                    isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            if (canZoom)
              Positioned(
                top: 8,
                left: 8,
                child: _buildTileZoomControls(
                  identity: identity,
                  scale: currentScale,
                ),
              ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.52),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (isSpotlight || isFullscreen)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: Icon(
                            Icons.zoom_in_map,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      if (sharingScreen)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: Icon(
                            Icons.screen_share_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      Icon(
                        micOn ? Icons.mic : Icons.mic_off,
                        size: 14,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        camOn ? Icons.videocam : Icons.videocam_off,
                        size: 14,
                        color: Colors.white,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemoteControlOverlay(String identity) {
    if (!_isRemoteControlActiveForIdentity(identity)) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return KeyboardListener(
            focusNode: _remoteControlFocusNode,
            onKeyEvent: (event) => unawaited(_sendRemoteKeyEvent(event)),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                _remoteControlFocusNode.requestFocus();
                unawaited(
                  _sendRemotePointerEvent(
                    event: 'down',
                    localPosition: event.localPosition,
                    size: size,
                    button: _pointerButtonFromButtons(event.buttons),
                  ),
                );
              },
              onPointerMove: (event) {
                unawaited(
                  _sendRemotePointerEvent(
                    event: 'move',
                    localPosition: event.localPosition,
                    size: size,
                  ),
                );
              },
              onPointerUp: (event) {
                unawaited(
                  _sendRemotePointerEvent(
                    event: 'up',
                    localPosition: event.localPosition,
                    size: size,
                    button: _pointerButtonFromButtons(event.buttons),
                  ),
                );
              },
              onPointerSignal: (event) {
                final dynamic signal = event;
                final scrollDelta = signal.scrollDelta;
                if (scrollDelta is Offset) {
                  unawaited(_sendRemoteWheelEvent(scrollDelta));
                }
              },
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: const Color(0xFF2E90FA),
                    width: 2,
                  ),
                ),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              '远程控制中：点击画面后可用键鼠进行操作',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: () => unawaited(
                            _stopRemoteControlSession(
                                reason: 'controller_stop'),
                          ),
                          child: const Text('结束控制'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTileZoomControls({
    required String identity,
    required double scale,
  }) {
    final canZoomOut = scale > _minTileZoomScale + 0.01;
    final canZoomIn = scale < _maxTileZoomScale - 0.01;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: _palette.primary.withValues(alpha: 0.67),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '缩小',
            visualDensity: VisualDensity.compact,
            onPressed: canZoomOut ? () => _stepTileZoom(identity, 0.8) : null,
            icon: const Icon(Icons.remove, size: 16, color: Colors.white),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '${(scale * 100).round()}%',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: '放大',
            visualDensity: VisualDensity.compact,
            onPressed: canZoomIn ? () => _stepTileZoom(identity, 1.25) : null,
            icon: const Icon(Icons.add, size: 16, color: Colors.white),
          ),
          IconButton(
            tooltip: '重置',
            visualDensity: VisualDensity.compact,
            onPressed: canZoomOut ? () => _resetTileZoom(identity) : null,
            icon: const Icon(Icons.refresh, size: 15, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _buildStageArea() {
    final participants = _livekitParticipants();
    if (participants.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: _palette.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _palette.panelBorder),
        ),
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _connecting ? Icons.wifi_tethering : Icons.groups_2_outlined,
              size: 48,
              color: _palette.primaryStrong,
            ),
            const SizedBox(height: 12),
            Text(
              _connecting ? '正在连接会议音视频...' : '当前还没有可展示的视频画面',
              style: TextStyle(
                color: _palette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: TextStyle(color: _palette.textMuted),
            ),
          ],
        ),
      );
    }

    lk.Participant? spotlightParticipant;
    final spotlightIdentity = _spotlightIdentity;
    if (spotlightIdentity != null) {
      spotlightParticipant = _participantByIdentity(spotlightIdentity);
    }
    if (spotlightParticipant != null) {
      final identity = _participantIdentity(spotlightParticipant);
      return Stack(
        children: [
          Positioned.fill(
            child: _buildParticipantTile(spotlightParticipant),
          ),
          Positioned(
            top: 56,
            left: 8,
            child: FilledButton.tonalIcon(
              onPressed: () => _toggleSpotlight(identity),
              icon: const Icon(Icons.grid_view),
              label: const Text('恢复宫格'),
            ),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = stageGridColumnsForWidth(constraints.maxWidth);
        return GridView.builder(
          itemCount: participants.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 16 / 9,
          ),
          itemBuilder: (context, index) {
            return _buildParticipantTile(participants[index]);
          },
        );
      },
    );
  }

  Widget _buildFullscreenTileScaffold() {
    final participant = _fullscreenParticipant();
    if (participant == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0B1220),
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '全屏画面已不可用',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => setState(() => _fullscreenIdentity = null),
                  icon: const Icon(Icons.fullscreen_exit),
                  label: const Text('退出全屏'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final identity = _participantIdentity(participant);
    final title = _participantLabel(participant);
    return Scaffold(
      backgroundColor: const Color(0xFF0B1220),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: () => _toggleTileFullscreen(identity),
                    icon: const Icon(Icons.fullscreen_exit),
                    label: const Text('退出全屏'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _buildParticipantTile(
                  participant,
                  forceFullscreen: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControlBar() {
    final canMicToggle = canToggleMicButton(
      connected: _connected,
      micEnabled: _micEnabled,
      canSelfUnmute: _canSelfUnmute,
    );
    final canCameraToggle = canToggleCameraButton(
      connected: _connected,
      cameraEnabled: _cameraEnabled,
      canOpenVideo: _canOpenVideo,
    );
    final canShareScreen = _canScreenShare;
    final canRecord = _canRecordMeeting && !_recordingBusy;
    final recordingButton = FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor:
            _recordingActive ? const Color(0xFFB42318) : _palette.primaryStrong,
      ),
      onPressed: canRecord
          ? (_recordingActive ? _stopRecording : _startRecording)
          : null,
      icon: Icon(
        _recordingBusy
            ? Icons.sync
            : (_recordingActive
                ? Icons.stop_circle_outlined
                : Icons.fiber_manual_record),
      ),
      label: Text(
        _recordingBusy
            ? '处理中...'
            : (_recordingActive
                ? '停止录制'
                : (_canRecordMeeting ? '开始录制' : '录制已禁用')),
      ),
    );
    final screenShareButton = FilledButton.icon(
      onPressed: (_connected && canShareScreen) ? _toggleScreenShare : null,
      icon: Icon(
        _screenShareEnabled
            ? Icons.stop_screen_share
            : Icons.screen_share_outlined,
      ),
      label: Text(
        screenShareButtonLabelZh(
          canShareScreen: canShareScreen,
          screenShareEnabled: _screenShareEnabled,
        ),
      ),
    );

    return Wrap(
      key: const ValueKey<String>('nativeMeetingBottomControls'),
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (false && !_connected)
          FilledButton.icon(
            onPressed: (_connecting || _leaving) ? null : _joinMeeting,
            icon: Icon(_connecting ? Icons.sync : Icons.login),
            label: Text(_connecting ? '连接中...' : '加入会议'),
          ),
        if (false)
          OutlinedButton.icon(
            onPressed: _openMeetingInfoDialog,
            icon: const Icon(Icons.info_outline),
            label: const Text('会议信息'),
          ),
        if (false && _canUseModeratorControls)
          FilledButton.icon(
            onPressed: _moderationBusy
                ? null
                : () => unawaited(_openModeratorControlDialog()),
            icon: const Icon(Icons.admin_panel_settings_outlined),
            label: Text(_moderationBusy ? '处理中...' : '主持管控'),
          ),
        FilledButton.icon(
          onPressed: canMicToggle ? _toggleMic : null,
          icon: Icon(_micEnabled ? Icons.mic : Icons.mic_off),
          label: Text(micButtonLabelZh(micEnabled: _micEnabled)),
        ),
        FilledButton.icon(
          onPressed: canCameraToggle ? _toggleCamera : null,
          icon: Icon(_cameraEnabled ? Icons.videocam : Icons.videocam_off),
          label: Text(cameraButtonLabelZh(cameraEnabled: _cameraEnabled)),
        ),
        screenShareButton,
        if (false) recordingButton,
        if (false)
          OutlinedButton.icon(
            onPressed: _hasMeetingRef
                ? () => unawaited(_syncRecordingStatus(silent: false))
                : null,
            icon: const Icon(Icons.sync),
            label: const Text('同步状态'),
          ),
        FilledButton.icon(
          onPressed: (_connected && !_leaving) ? _leaveRoom : null,
          icon: const Icon(Icons.call_end),
          style:
              FilledButton.styleFrom(backgroundColor: const Color(0xFFB42318)),
          label: Text(_isHost ? '结束会议' : '离开会议'),
        ),
      ],
    );
  }

  Widget _buildTopActions() {
    final canRecord = _canRecordMeeting && !_recordingBusy;
    final statusLabel = _connected ? '已连接' : '未连接';
    final maxParticipants = widget.joinPayload.maxParticipants <= 0
        ? 100
        : widget.joinPayload.maxParticipants;
    final onlineCount = _memberProfiles.length;
    return Wrap(
      key: const ValueKey<String>('nativeMeetingTopActions'),
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!_connected)
          FilledButton.icon(
            onPressed: (_connecting || _leaving) ? null : _joinMeeting,
            icon: Icon(_connecting ? Icons.sync : Icons.login),
            label: Text(_connecting ? '连接中...' : '加入会议'),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF8FF),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFFB2DDFF)),
          ),
          child: Text(
            '状态：$statusLabel',
            style: const TextStyle(
              color: Color(0xFF175CD3),
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFFF0F9FF),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFFB9E6FE)),
          ),
          child: Text(
            '参会/上限：$onlineCount/$maxParticipants',
            style: const TextStyle(
              color: Color(0xFF0E7090),
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (_isBeingRemoteControlled)
          FilledButton.tonalIcon(
            onPressed: () => unawaited(
              _stopRemoteControlSession(
                notifyPeer: true,
                reason: 'target_stop',
              ),
            ),
            icon: const Icon(Icons.link_off_outlined),
            label: const Text('结束被控'),
          ),
        OutlinedButton.icon(
          onPressed: _openMeetingInfoDialog,
          icon: const Icon(Icons.info_outline),
          label: const Text('会议信息'),
        ),
        if (_canUseModeratorControls)
          FilledButton.icon(
            onPressed: _moderationBusy
                ? null
                : () => unawaited(_openModeratorControlDialog()),
            icon: const Icon(Icons.admin_panel_settings_outlined),
            label: Text(_moderationBusy ? '处理中...' : '主持管控'),
          ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: _recordingActive
                ? const Color(0xFFB42318)
                : _palette.primaryStrong,
          ),
          onPressed: canRecord
              ? (_recordingActive ? _stopRecording : _startRecording)
              : null,
          icon: Icon(
            _recordingBusy
                ? Icons.sync
                : (_recordingActive
                    ? Icons.stop_circle_outlined
                    : Icons.fiber_manual_record),
          ),
          label: Text(
            _recordingBusy
                ? '处理中...'
                : (_recordingActive
                    ? '停止录制'
                    : (_canRecordMeeting ? '开始录制' : '录制已禁用')),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _hasMeetingRef
              ? () => unawaited(_syncRecordingStatus(silent: false))
              : null,
          icon: const Icon(Icons.sync),
          label: const Text('同步状态'),
        ),
      ],
    );
  }

  Widget _buildRightPanel() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.panelBorder),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              decoration: BoxDecoration(
                color: _palette.surfaceRaised,
                border: Border(bottom: BorderSide(color: _palette.panelBorder)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.meetingTitle.trim().isEmpty
                        ? widget.joinPayload.roomName
                        : widget.meetingTitle.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _palette.textStrong,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(child: _buildRecordingChip()),
                      IconButton(
                        tooltip: '刷新会议信息',
                        onPressed: _hasMeetingRef
                            ? () {
                                unawaited(_loadMembers());
                                unawaited(_loadMessages());
                                unawaited(_syncRecordingStatus(silent: false));
                              }
                            : null,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  Text(
                    _status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _palette.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              color: _palette.surfaceRaised,
              child: TabBar(
                tabs: const [
                  Tab(text: '成员列表'),
                  Tab(text: '会议聊天'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _buildMembersTab(),
                  _buildChatTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMeetingHeader(String meetingName) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: _palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _palette.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$meetingName  ·  ${widget.joinPayload.roomName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _palette.textStrong,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          _buildTopActions(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isTileFullscreenActive) {
      return _buildFullscreenTileScaffold();
    }
    final meetingName = widget.meetingTitle.trim().isEmpty
        ? widget.joinPayload.roomName
        : widget.meetingTitle.trim();
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: _palette.pageBackground,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 1100;
                if (narrow) {
                  return ListView(
                    children: [
                      _buildMeetingHeader(meetingName),
                      Offstage(
                        child: Text(
                          '$meetingName  ·  ${widget.joinPayload.roomName}',
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildControlBar(),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 260,
                        child: _buildStageArea(),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(height: 360, child: _buildRightPanel()),
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildMeetingHeader(meetingName),
                          Offstage(
                            child: Text(
                              '$meetingName  ·  ${widget.joinPayload.roomName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _palette.textStrong,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expanded(child: _buildStageArea()),
                          const SizedBox(height: 12),
                          _buildControlBar(),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 370,
                      child: _buildRightPanel(),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
