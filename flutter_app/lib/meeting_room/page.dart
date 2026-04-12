import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:ui_web' as ui_web;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:web/web.dart' as web;
import '../app/theme/meeting_theme.dart';
import '../device_profile.dart';
import 'chat_menu/chat_message_menu_builder.dart';
import 'debug/debug_flags.dart';
import 'debug/stt_debug.dart';
import 'models.dart';
import 'realtime_bot_protocol.dart';
import 'realtime_bot_streaming.dart';
import 'participant_menu/participant_menu_builder.dart';
import 'utils/audio_level.dart';
import 'widgets/media_test_widgets.dart';
import 'widgets/panel_widgets.dart';
import 'widgets/selectable_region.dart';
part 'logic/chat_logic.dart';
part 'widgets/chat_widgets.dart';
part 'widgets/layout_panels.dart';
part 'logic/meeting_service_logic.dart';
part 'logic/moderation_logic.dart';
part 'logic/recording.dart';
part 'logic/room_session_logic.dart';
part 'logic/workspace_logic.dart';
part 'widgets/workspace_widgets.dart';

class MeetingRoomPage extends StatefulWidget {
  final int? meetingId;
  final String? meetingRef;
  final String? shareCode;
  final bool autoJoin;
  final bool preferMobileLayout;

  const MeetingRoomPage({
    super.key,
    this.meetingId,
    this.meetingRef,
    this.shareCode,
    this.autoJoin = false,
    this.preferMobileLayout = false,
  }) : assert(
          ((meetingId != null) ? 1 : 0) +
                  ((meetingRef != null && meetingRef != '') ? 1 : 0) +
                  ((shareCode != null && shareCode != '') ? 1 : 0) ==
              1,
          'Provide exactly one of meetingId, meetingRef, shareCode',
        );

  @override
  State<MeetingRoomPage> createState() => _MeetingRoomPageState();
}

class _MeetingRoomPageState extends State<MeetingRoomPage> {
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  final TextEditingController _workspaceTranscriptController =
      TextEditingController();

  String _accessToken = '';
  String _meetingTitle = '会议';
  String _roomNumber = '-';
  String _status = '准备就绪';

  bool _connected = false;
  bool _joining = false;
  bool _micEnabled = true;
  bool _cameraEnabled = true;
  bool _screenShareEnabled = false;
  bool _screenShareAudioEnabled = false;
  bool _shareScreenWithAudioPreference = true;
  bool _micPermissionGranted = true;
  bool _cameraPermissionGranted = true;
  String? _permissionWarning;
  String _defaultDisplayName = '';
  String _meetingDisplayName = '';
  String _meetingPassword = '';
  String _profileAvatarUrl = '';
  String _shareUrl = '';
  bool _waitingRoomEnabled = false;
  bool _muteOnEntry = false;
  int _maxParticipants = 100;
  DateTime? _actualStartedAt;
  DateTime _elapsedNow = DateTime.now();
  bool _allowGuestLinkJoin = true;
  bool _allowRecording = true;
  bool _allowScreenShare = true;
  bool _allowChat = true;
  bool _allowSelfUnmute = true;
  bool _allowMemberVideo = true;
  bool _realtimeBotEnabled = false;
  bool _realtimeBotMuted = false;
  String _realtimeBotProvider = 'openai';
  String _realtimeBotBaseUrl = 'https://api.openai.com';
  String _realtimeBotOpenaiModel = 'gpt-realtime';
  String _realtimeBotOpenaiVoice = 'marin';
  String _realtimeBotVolcModel = '2.2.0.0';
  String _realtimeBotVolcVoice = '';
  String _realtimeBotVolcWsUrl =
      'wss://openspeech.bytedance.com/api/v3/realtime/dialogue';
  String _realtimeBotVolcAppId = '';
  String _realtimeBotVolcResourceId = 'volc.speech.dialog';
  String _realtimeBotVolcUid = '';
  String _realtimeBotDisplayName = '实时语音助手';
  String _realtimeBotIdentity = '';
  bool _realtimeBotApiKeySet = false;
  bool _realtimeBotVolcAppKeySet = false;
  bool _realtimeBotVolcAccessKeySet = false;
  int? _realtimeBotUserId;
  bool _realtimeBotAutoListen = true;
  bool _realtimeBotListening = false;
  bool _realtimeBotAudioUploading = false;
  bool _realtimeBotIngressSocketConnecting = false;
  bool _realtimeBotPlaybackActive = false;
  bool _realtimeBotCaptureStarting = false;
  bool _isSuperAdminUser = false;
  bool _realtimeBotDebugPanelVisible = false;
  String _currentUserRole = '';

  MeetingThemePalette get _palette => MeetingTheme.of(context);
  String _resolvedMeetingRef = '';
  int? _resolvedMeetingId;
  bool _recordingActive = false;
  bool _recordingUploading = false;
  DateTime? _recordingStartedAt;
  String _activeEgressId = '';
  html.MediaRecorder? _meetingRecorder;
  html.MediaStream? _meetingRecordingStream;
  final List<html.Blob> _meetingRecordingChunks = <html.Blob>[];
  StreamSubscription<html.Event>? _meetingRecordingDataSubscription;
  StreamSubscription<html.Event>? _meetingRecordingStopSubscription;
  Completer<void>? _meetingRecordingFinalizeCompleter;
  dynamic _realtimeBotAudioContext;
  dynamic _realtimeBotCaptureProcessorNode;
  final List<dynamic> _realtimeBotCaptureInputNodes = <dynamic>[];
  dynamic _realtimeBotFallbackMicStream;
  html.WebSocket? _realtimeBotIngressSocket;
  lk.CancelListenFunc? _realtimeBotFrameCapture;
  String _realtimeBotCaptureTrackId = '';
  int _realtimeBotCaptureSampleRate = _realtimeBotAudioTargetSampleRate;
  DateTime? _realtimeBotCaptureBoundAt;
  Function? _realtimeBotCaptureAudioProcessHandler;
  Timer? _realtimeBotIngressResponseTimeoutTimer;
  DateTime? _realtimeBotCurrentUploadStartedAt;
  final List<int> _realtimeBotCaptureBytes = <int>[];
  final List<int> _realtimeBotPrerollBytes = <int>[];
  DateTime? _realtimeBotSpeechStartedAt;
  DateTime? _realtimeBotLastVoiceAt;
  bool _realtimeBotSpeechStreamOpen = false;
  int _realtimeBotDebugInputSourceCount = 0;
  bool _realtimeBotDebugVoiceActive = false;
  bool _realtimeBotDebugFallbackMicOpen = false;
  double _realtimeBotDebugLastRms = 0.0;
  int _realtimeBotDebugBufferedBytes = 0;
  int _realtimeBotDebugLastUploadBytes = 0;
  int _realtimeBotDebugUploadCount = 0;
  int? _realtimeBotDebugLastUploadLatencyMs;
  DateTime? _realtimeBotDebugLastUploadAt;
  DateTime? _realtimeBotDebugLastProcessAt;
  int _realtimeBotDebugProcessCount = 0;
  DateTime? _realtimeBotDebugLastRebuildAt;
  String _realtimeBotDebugAudioContextState = 'unknown';
  String _realtimeBotDebugLastEvent = 'idle';
  String _realtimeBotDebugLastError = '';
  String _realtimeBotDebugLastPreview = '';

  bool _echoCancellation = true;
  bool _noiseSuppression = true;
  bool _autoGainControl = true;

  String? _selectedAudioInputId;
  String? _selectedAudioOutputId;
  String? _selectedVideoInputId;
  List<lk.MediaDevice> _audioInputs = const [];
  List<lk.MediaDevice> _audioOutputs = const [];
  List<lk.MediaDevice> _videoInputs = const [];
  CameraResolutionPreset _cameraResolutionPreset =
      CameraResolutionPreset.p2160;
  ScreenShareResolutionPreset _screenShareResolutionPreset =
      ScreenShareResolutionPreset.p2160;
  bool _adaptiveStreamEnabled = false;
  bool _dynacastEnabled = false;
  RemoteShareViewMode _remoteCameraViewMode = RemoteShareViewMode.original;
  RemoteShareViewMode _remoteShareViewMode = RemoteShareViewMode.original;
  final Map<String, TransformationController> _tileZoomControllers =
      <String, TransformationController>{};
  bool _desktopParticipantsCollapsed = false;
  bool _desktopChatCollapsed = false;
  bool _desktopChatPanelExpanded = false;
  bool _desktopWorkspacePanelExpanded = false;
  int _cameraPreviewFactoryCounter = 0;

  static const double _minTileZoomScale = 1.0;
  static const double _maxTileZoomScale = 5.0;
  static const double _desktopSideRailWidth = 56.0;
  static const Duration _desktopPanelAnimationDuration =
      Duration(milliseconds: 180);
  static const int _cameraTrackSourceValue = 1;
  static const int _microphoneTrackSourceValue = 2;
  static const int _screenShareTrackSourceValue = 3;
  static const int _screenShareAudioTrackSourceValue = 4;
  static const Map<String, int> _trackSourceTokenToValue = <String, int>{
    'camera': _cameraTrackSourceValue,
    'microphone': _microphoneTrackSourceValue,
    'mic': _microphoneTrackSourceValue,
    'screen_share': _screenShareTrackSourceValue,
    'screenshare': _screenShareTrackSourceValue,
    'screen_share_audio': _screenShareAudioTrackSourceValue,
    'screenshareaudio': _screenShareAudioTrackSourceValue,
  };
  static const String _micRequestMetadataKey = 'request_mic_pending';
  static const String _videoRequestMetadataKey = 'request_video_pending';
  static const String _screenShareRequestMetadataKey =
      'request_screen_share_pending';
  static const String _hostForceOpenMicMetadataKey =
      'host_force_open_mic_nonce';
  static const String _hostForceOpenVideoMetadataKey =
      'host_force_open_video_nonce';
  static const String _displayNameMetadataKey = 'meeting_display_name';
  static const String _displayNameVersionMetadataKey =
      'meeting_display_name_version';
  static const Duration _permissionRequestTimeout = Duration(seconds: 8);
  static const Duration _roomConnectTimeout = Duration(seconds: 20);
  static const int _realtimeBotAudioTargetSampleRate = 16000;
  static const int _realtimeBotAudioSilenceMs = 700;
  static const int _realtimeBotAudioMinSpeechMs = 350;
  static const int _realtimeBotAudioForceFlushMs = 1600;
  static const int _realtimeBotAudioMaxSpeechMs = 8000;
  static const int _realtimeBotIngressStreamChunkBytes = 640;
  static const int _realtimeBotIngressStreamMaxBufferBytes = 640 * 600;
  static const int _realtimeBotIngressPrerollBytes = 640 * 10;
  static const double _realtimeBotVadThreshold = 0.0013;
  static const double _realtimeBotVadPeakThreshold = 0.011;
  static const double _realtimeBotVadStartRmsRatio = 0.3;
  static const double _realtimeBotVadStartPeakRatio = 0.5;
  static const double _realtimeBotVadHoldRmsRatio = 1.45;
  static const double _realtimeBotVadHoldPeakRatio = 1.3;
  static const int _realtimeBotDebugRebuildIntervalMs = 250;
  static const int _realtimeBotAudioKeepaliveMs = 1200;
  static const int _realtimeBotIngressResponseTimeoutMs = 45000;

  String? _spotlightIdentity;
  String? _fullscreenIdentity;

  double _normalizedAudioLevel(double rawLevel) {
    if (!rawLevel.isFinite || rawLevel <= 0) return 0;
    return math.sqrt(rawLevel.clamp(0.0, 1.0)).clamp(0.0, 1.0);
  }

  void _openCommunicationPanelFullscreen({required bool forChat}) {
    final panelLabel = forChat ? '聊天' : '工作区';
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => Dialog.fullscreen(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: forChat
                ? _buildChatPanel(
                    headerActions: [
                      MeetingPanelHeaderActionBar(
                        panelLabel: panelLabel,
                        isFullscreen: true,
                        onToggleFullscreen: () =>
                            Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  )
                : _buildWorkspacePanel(
                    headerActions: [
                      MeetingPanelHeaderActionBar(
                        panelLabel: panelLabel,
                        isFullscreen: true,
                        onToggleFullscreen: () =>
                            Navigator.of(dialogContext).pop(),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _roomListener;
  Timer? _meetingElapsedTimer;
  Timer? _chatTimer;
  Timer? _memberTimer;
  Timer? _workspaceTimer;
  Timer? _waitingRoomTimer;
  Timer? _recordingStatusTimer;
  Timer? _realtimeBotCaptureKeepaliveTimer;
  StreamSubscription<html.Event>? _fullscreenSubscription;
  int _latestMessageId = 0;
  final List<ChatMessage> _messages = [];
  final Map<int, ChatMessage> _pendingLocalDraftMessages =
      <int, ChatMessage>{};
  final Set<int> _playedRealtimeBotAudioMessageIds = <int>{};
  final Set<int> _playingRealtimeBotAudioMessageIds = <int>{};
  final Set<int> _recallingMessageIds = <int>{};
  int _localDraftMessageSequence = -1;
  bool _workspaceLoading = false;
  bool _workspaceReady = false;
  bool _workspaceSttActive = false;
  bool _workspaceSttStopping = false;
  String _workspacePartialText = '';
  String _workspaceSttDebugState = 'idle';
  String _workspaceSttDebugMimeType = '';
  int _workspaceSttDebugBlobEventCount = 0;
  int _workspaceSttDebugLastBlobSize = 0;
  String _workspaceSttDebugLastError = '';
  String _workspaceSttDebugWsState = 'not-created';
  int _workspaceSttDebugAudioTrackCount = 0;
  int _workspaceSttDebugStartTapCount = 0;
  int _workspaceSttDebugStopTapCount = 0;
  String _workspaceSttDebugLastAction = '-';
  html.WebSocket? _workspaceSttSocket;
  html.MediaRecorder? _workspaceSttRecorder;
  html.MediaStream? _workspaceSttStream;
  StreamSubscription<html.Event>? _workspaceSttDataSubscription;
  StreamSubscription<html.Event>? _workspaceSttStopSubscription;
  StreamSubscription<html.MessageEvent>? _workspaceSttMessageSubscription;
  StreamSubscription<html.Event>? _workspaceSttOpenSubscription;
  StreamSubscription<html.Event>? _workspaceSttCloseSubscription;
  StreamSubscription<html.Event>? _workspaceSttErrorSubscription;
  Completer<void>? _workspaceSttRecorderStopCompleter;
  Completer<void>? _workspaceSttFlushDataCompleter;
  int _workspacePendingAudioChunkSends = 0;
  List<WorkspaceAgentSession> _workspaceAgentSessions =
      const <WorkspaceAgentSession>[];
  WorkspaceContextSnapshot? _workspaceContext;
  List<WorkspaceTranscriptChunk> _workspaceTranscripts =
      const <WorkspaceTranscriptChunk>[];
  List<WorkspaceArtifact> _workspaceArtifacts = const <WorkspaceArtifact>[];
  Map<int, MeetingMemberProfile> _memberProfiles = {};
  final Map<String, String> _runtimeDisplayNamesByIdentity = <String, String>{};
  final Map<String, int> _guestDisplayNameVersionsByIdentity = <String, int>{};
  bool _updatingLocalRequestMetadata = false;
  String? _lastHandledHostForceMicNonce;
  String? _lastHandledHostForceVideoNonce;
  bool _handlingHostForceOpen = false;
  List<WaitingRoomEntry> _waitingRoomEntries = const [];
  int _lastWaitingRoomCount = 0;
  bool _hasNewWaitingRoomNotice = false;
  bool _waitingForAdmission = false;
  static const List<String> _quickEmojis = <String>[
    '😀',
    '😄',
    '😂',
    '😍',
    '👍',
    '👏',
    '🙏',
    '🎉',
    '🤝',
    '💡',
    '✅',
    '🔥',
  ];
  static const Map<String, String> _quickEmojiLabels = <String, String>{
    '😀': '微笑',
    '😄': '开心',
    '😂': '大笑',
    '😍': '喜欢',
    '👍': '赞同',
    '👏': '鼓掌',
    '🙏': '感谢',
    '🎉': '庆祝',
    '🤝': '合作',
    '💡': '想法',
    '✅': '确认',
    '🔥': '给力',
  };

  bool get _isShareEntry =>
      (widget.shareCode ?? '').trim().isNotEmpty &&
      widget.meetingId == null &&
      (widget.meetingRef ?? '').trim().isEmpty;

  bool get _requiresAuth => !_isShareEntry;

  bool get _chatWriteEnabled {
    final profile = _localMemberProfile;
    if (profile != null && !profile.allowChat) {
      return false;
    }
    return _allowChat;
  }

  String get _localRoleKey {
    final role = (_localMemberProfile?.role ?? _currentUserRole).trim();
    return role.isEmpty ? 'participant' : role;
  }

  int? get _localUserId =>
      _userIdFromIdentity(_room?.localParticipant?.identity ?? '');

  MeetingMemberProfile? get _localMemberProfile {
    final userId = _localUserId;
    if (userId == null) return null;
    return _memberProfiles[userId];
  }

  bool get _localCanSelfUnmute {
    if (_isModerator) return true;
    final profile = _localMemberProfile;
    if (profile != null) return profile.allowSelfUnmute;
    final local = _room?.localParticipant;
    if (local == null) return _allowSelfUnmute;
    if (!_participantPermissionsReady(local)) return _allowSelfUnmute;
    return _participantCanPublishSource(local, _microphoneTrackSourceValue);
  }

  bool get _localCanMemberVideo {
    if (_isModerator) return true;
    final profile = _localMemberProfile;
    if (profile != null) return profile.allowMemberVideo;
    final local = _room?.localParticipant;
    if (local == null) return _allowMemberVideo;
    if (!_participantPermissionsReady(local)) return _allowMemberVideo;
    return _participantCanPublishSource(local, _cameraTrackSourceValue);
  }

  bool get _localCanScreenShare {
    if (_isModerator) return true;
    final profile = _localMemberProfile;
    if (profile != null) return profile.allowScreenShare;
    final local = _room?.localParticipant;
    if (local == null) return _allowScreenShare;
    if (!_participantPermissionsReady(local)) return _allowScreenShare;
    return _participantCanPublishSource(local, _screenShareTrackSourceValue) ||
        _participantCanPublishSource(local, _screenShareAudioTrackSourceValue);
  }

  bool get _isModerator {
    return _localRoleKey == 'host' || _localRoleKey == 'cohost';
  }

  bool get _isHost => _localRoleKey == 'host';

  bool get _canUseModeratorControls {
    if (!_isModerator) return false;
    return _hasPrivateMeetingApiScope;
  }

  bool get _canRecordMeeting {
    if (!_connected) return false;
    if (!_hasPrivateMeetingApiScope) return false;
    if (!_allowRecording) return false;
    return _isModerator;
  }

  bool get _hasPrivateMeetingApiScope {
    if (widget.meetingId != null) return true;
    if ((widget.meetingRef ?? '').trim().isNotEmpty) return true;
    return _resolvedMeetingRef.trim().isNotEmpty;
  }

  int? get _effectiveMeetingId => widget.meetingId ?? _resolvedMeetingId;

  String _privateMeetingApiBase() {
    final meetingRef = (widget.meetingRef ?? '').trim();
    if (meetingRef.isNotEmpty) {
      return '/api/my/meetings/${Uri.encodeComponent(meetingRef)}';
    }
    final resolvedMeetingRef = _resolvedMeetingRef.trim();
    if (resolvedMeetingRef.isNotEmpty) {
      return '/api/my/meetings/${Uri.encodeComponent(resolvedMeetingRef)}';
    }
    final meetingId = widget.meetingId;
    if (meetingId != null) {
      return '/api/meetings/$meetingId';
    }
    throw StateError('Meeting reference is unavailable for private API.');
  }

  String _publicMeetingApiBase() =>
      '/api/public/meetings/share/${widget.shareCode}';

  String _meetingInfoApiPath() {
    if (_isShareEntry) {
      return _publicMeetingApiBase();
    }
    return _privateMeetingApiBase();
  }

  String _meetingMembersApiPath() {
    if (_isShareEntry) {
      return '${_publicMeetingApiBase()}/members';
    }
    return '${_privateMeetingApiBase()}/members';
  }

  String _meetingMessagesApiPath({required int limit}) {
    if (_isShareEntry) {
      return '${_publicMeetingApiBase()}/messages?limit=$limit';
    }
    return '${_privateMeetingApiBase()}/messages?limit=$limit';
  }

  String _meetingMessageItemApiPath(int messageId) {
    if (_isShareEntry) {
      return '${_publicMeetingApiBase()}/messages/$messageId';
    }
    return '${_privateMeetingApiBase()}/messages/$messageId';
  }

  String _meetingJoinTokenApiPath() {
    if (_isShareEntry) {
      return '${_publicMeetingApiBase()}/join-token';
    }
    return '${_privateMeetingApiBase()}/join-token';
  }

  String _publicMyDisplayNameApiPath() =>
      '${_publicMeetingApiBase()}/my-display-name';

  String _meetingControlsApiPath() => '${_privateMeetingApiBase()}/controls';
  String _meetingAiControlsApiPath() =>
      '${_privateMeetingApiBase()}/ai-controls';
  String _meetingAiControlsTestApiPath() =>
      '${_privateMeetingApiBase()}/ai-controls/test';
  String _meetingAiRealtimeAudioApiPath() =>
      '${_privateMeetingApiBase()}/ai-controls/realtime-audio';
  String _meetingAiRealtimeAudioWsPath() =>
      meetingAiRealtimeAudioWsPath(_meetingAiRealtimeAudioApiPath());

  String _meetingAiRealtimeAudioWsUrl() {
    final location = html.window.location;
    final scheme = location.protocol == 'https:' ? 'wss' : 'ws';
    final token = _accessToken.trim();
    final tokenQuery = token.isEmpty
        ? ''
        : '?token=${Uri.encodeQueryComponent(token)}';
    return '$scheme://${location.host}${_meetingAiRealtimeAudioWsPath()}$tokenQuery';
  }

  String _meetingMuteAllApiPath() =>
      '${_privateMeetingApiBase()}/members/mute-all';

  String _meetingHostLeaveApiPath() => '${_privateMeetingApiBase()}/host-leave';

  String _meetingWaitingRoomApiPath() =>
      '${_privateMeetingApiBase()}/waiting-room';

  String _meetingRaiseHandApiPath() =>
      '${_privateMeetingApiBase()}/members/raise-hand';

  String _meetingRecordingEgressApiPath() =>
      '${_privateMeetingApiBase()}/recordings/egress';

  String _meetingRecordingEgressStartApiPath() =>
      '${_meetingRecordingEgressApiPath()}/start';

  String _meetingRecordingEgressStopApiPath() =>
      '${_meetingRecordingEgressApiPath()}/stop';

  String _meetingWorkspaceTranscriptsApiPath({int? limit}) {
    final meetingId = _effectiveMeetingId;
    if (meetingId == null || meetingId <= 0) {
      throw StateError('Meeting id is unavailable for workspace transcripts.');
    }
    final base = '/api/meetings/$meetingId/transcripts';
    if (limit == null) return base;
    return '$base?limit=$limit';
  }

  String _meetingWorkspaceCurrentContextApiPath() {
    final meetingId = _effectiveMeetingId;
    if (meetingId == null || meetingId <= 0) {
      throw StateError('Meeting id is unavailable for workspace context.');
    }
    return '/api/meetings/$meetingId/context/current';
  }

  String _meetingWorkspaceAgentsApiPath() {
    final meetingId = _effectiveMeetingId;
    if (meetingId == null || meetingId <= 0) {
      throw StateError('Meeting id is unavailable for workspace agents.');
    }
    return '/api/meetings/$meetingId/agents';
  }

  String _meetingWorkspaceAgentActionsApiPath() {
    final meetingId = _effectiveMeetingId;
    if (meetingId == null || meetingId <= 0) {
      throw StateError(
          'Meeting id is unavailable for workspace agent actions.');
    }
    return '/api/meetings/$meetingId/agent-actions';
  }

  String _meetingWorkspaceArtifactsApiPath({int? limit}) {
    final meetingId = _effectiveMeetingId;
    if (meetingId == null || meetingId <= 0) {
      throw StateError('Meeting id is unavailable for workspace artifacts.');
    }
    final base = '/api/meetings/$meetingId/artifacts';
    if (limit == null) return base;
    return '$base?limit=$limit';
  }

  String _meetingWorkspaceRealtimeSttWebsocketPath() {
    final meetingId = _effectiveMeetingId;
    if (meetingId == null || meetingId <= 0) {
      throw StateError('Meeting id is unavailable for realtime STT.');
    }
    return '/ws/meetings/$meetingId/stt';
  }

  String _meetingMemberActionApiPath(int userId, String action) =>
      '${_privateMeetingApiBase()}/members/$userId/$action';

  String _meetingParticipantActionApiPath(String identity, String action) =>
      '${_privateMeetingApiBase()}/participants/${Uri.encodeComponent(identity)}/$action';

  String _meetingParticipantItemApiPath(String identity) =>
      '${_privateMeetingApiBase()}/participants/${Uri.encodeComponent(identity)}';

  @override
  void initState() {
    super.initState();
    _fullscreenSubscription = html.document.onFullscreenChange.listen((_) {
      if (!mounted) return;
      if (html.document.fullscreenElement == null) {
        final previousIdentity = _fullscreenIdentity;
        if (previousIdentity != null) {
          _resetTileZoom(previousIdentity, rebuild: false);
        }
        setState(() {
          _fullscreenIdentity = null;
        });
      } else if (_fullscreenIdentity != null) {
        setState(() {});
      }
    });
    _bootstrap();
  }

  @override
  void dispose() {
    _recordingStatusTimer?.cancel();
    _recordingStatusTimer = null;
    _realtimeBotCaptureKeepaliveTimer?.cancel();
    _realtimeBotCaptureKeepaliveTimer = null;
    _workspaceTimer?.cancel();
    _workspaceTimer = null;
    _chatController.dispose();
    _chatScrollController.dispose();
    _workspaceTranscriptController.dispose();
    _meetingElapsedTimer?.cancel();
    _meetingElapsedTimer = null;
    _stopChatPolling();
    _stopMemberPolling();
    _stopWaitingRoomPolling();
    _fullscreenSubscription?.cancel();
    _disposeAllZoomControllers();
    unawaited(_stopWorkspaceRealtimeStt(immediate: true));
    unawaited(_stopRealtimeBotAudioIngress());
    unawaited(_disposeRoom());
    super.dispose();
  }

  Uri _uri(String path) => Uri.base.resolve(path);

  void _setStatus(String text) {
    if (!mounted) return;
    setState(() {
      _status = text;
    });
  }

  bool get _showRealtimeBotDebugPanel {
    return shouldShowRealtimeBotDebugPanel(
      projectDebugUiEnabled: meetingDebugUiEnabled,
      isSuperAdminUser: _isSuperAdminUser,
      debugPanelVisible: _realtimeBotDebugPanelVisible,
    );
  }

  bool get _showWorkspaceSttDebugPanel {
    return shouldShowWorkspaceSttDebug(
      projectDebugUiEnabled: meetingDebugUiEnabled,
    );
  }

  String _clipDebugText(String text, {int maxLength = 120}) {
    final normalized = text.trim();
    if (normalized.isEmpty) return '-';
    if (normalized.length <= maxLength) return normalized;
    return '${normalized.substring(0, maxLength)}...';
  }

  String _formatDebugTime(DateTime? value) {
    if (value == null) return '-';
    final hh = value.hour.toString().padLeft(2, '0');
    final mm = value.minute.toString().padLeft(2, '0');
    final ss = value.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  void _updateRealtimeBotDebug({
    String? event,
    String? error,
    bool clearError = false,
    String? preview,
    String? audioContextState,
    bool? voiceActive,
    double? rms,
    bool bumpProcessCount = false,
    DateTime? lastProcessAt,
    int? sourceCount,
    bool? fallbackMicOpen,
    int? bufferedBytes,
    int? lastUploadBytes,
    int? lastUploadLatencyMs,
    DateTime? lastUploadAt,
    bool bumpUploadCount = false,
    bool forceRebuild = false,
  }) {
    var changed = false;
    if (event != null && event != _realtimeBotDebugLastEvent) {
      _realtimeBotDebugLastEvent = event;
      changed = true;
    }
    if (clearError && _realtimeBotDebugLastError.isNotEmpty) {
      _realtimeBotDebugLastError = '';
      changed = true;
    }
    if (error != null && error != _realtimeBotDebugLastError) {
      _realtimeBotDebugLastError = error;
      changed = true;
    }
    if (preview != null && preview != _realtimeBotDebugLastPreview) {
      _realtimeBotDebugLastPreview = preview;
      changed = true;
    }
    if (audioContextState != null &&
        audioContextState != _realtimeBotDebugAudioContextState) {
      _realtimeBotDebugAudioContextState = audioContextState;
      changed = true;
    }
    if (voiceActive != null && voiceActive != _realtimeBotDebugVoiceActive) {
      _realtimeBotDebugVoiceActive = voiceActive;
      changed = true;
    }
    if (rms != null && rms != _realtimeBotDebugLastRms) {
      _realtimeBotDebugLastRms = rms;
      changed = true;
    }
    if (lastProcessAt != null &&
        lastProcessAt != _realtimeBotDebugLastProcessAt) {
      _realtimeBotDebugLastProcessAt = lastProcessAt;
      changed = true;
    }
    if (bumpProcessCount) {
      _realtimeBotDebugProcessCount += 1;
      changed = true;
    }
    if (sourceCount != null &&
        sourceCount != _realtimeBotDebugInputSourceCount) {
      _realtimeBotDebugInputSourceCount = sourceCount;
      changed = true;
    }
    if (fallbackMicOpen != null &&
        fallbackMicOpen != _realtimeBotDebugFallbackMicOpen) {
      _realtimeBotDebugFallbackMicOpen = fallbackMicOpen;
      changed = true;
    }
    if (bufferedBytes != null &&
        bufferedBytes != _realtimeBotDebugBufferedBytes) {
      _realtimeBotDebugBufferedBytes = bufferedBytes;
      changed = true;
    }
    if (lastUploadBytes != null &&
        lastUploadBytes != _realtimeBotDebugLastUploadBytes) {
      _realtimeBotDebugLastUploadBytes = lastUploadBytes;
      changed = true;
    }
    if (lastUploadLatencyMs != null &&
        lastUploadLatencyMs != _realtimeBotDebugLastUploadLatencyMs) {
      _realtimeBotDebugLastUploadLatencyMs = lastUploadLatencyMs;
      changed = true;
    }
    if (lastUploadAt != null && lastUploadAt != _realtimeBotDebugLastUploadAt) {
      _realtimeBotDebugLastUploadAt = lastUploadAt;
      changed = true;
    }
    if (bumpUploadCount) {
      _realtimeBotDebugUploadCount += 1;
      changed = true;
    }
    if (!changed || !mounted) return;
    final now = DateTime.now();
    if (forceRebuild ||
        _realtimeBotDebugLastRebuildAt == null ||
        now.difference(_realtimeBotDebugLastRebuildAt!).inMilliseconds >=
            _realtimeBotDebugRebuildIntervalMs) {
      _realtimeBotDebugLastRebuildAt = now;
      setState(() {});
    }
  }

  String _csvEscape(String value) {
    final normalized = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final escaped = normalized.replaceAll('"', '""');
    return '"$escaped"';
  }

  int _participantRoleWeight(String roleKey) {
    switch (roleKey) {
      case 'host':
        return 0;
      case 'cohost':
        return 1;
      default:
        return 2;
    }
  }

  String _participantExportFileName() {
    final baseRaw = (_roomNumber.trim().isNotEmpty && _roomNumber.trim() != '-')
        ? _roomNumber.trim()
        : _meetingTitle.trim();
    final safeBase = baseRaw
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final fallbackBase = safeBase.isEmpty ? 'meeting' : safeBase;
    final now = DateTime.now();
    final stamp =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    return '${fallbackBase}_入会名单_$stamp.csv';
  }

  Future<void> _exportParticipantRosterCsv() async {
    if (!_canUseModeratorControls) {
      _setStatus('仅主持人或联席主持人可导出入会名单');
      return;
    }
    final rows = _collectParticipantRows();
    if (rows.isEmpty) {
      _setStatus('当前暂无在会成员可导出');
      return;
    }
    final sortedRows = List<ParticipantRowData>.from(rows)
      ..sort((a, b) {
        final typeOrder =
            (a.userId == null ? 1 : 0).compareTo(b.userId == null ? 1 : 0);
        if (typeOrder != 0) return typeOrder;
        final roleOrder = _participantRoleWeight(a.roleKey)
            .compareTo(_participantRoleWeight(b.roleKey));
        if (roleOrder != 0) return roleOrder;
        return a.displayName
            .toLowerCase()
            .compareTo(b.displayName.toLowerCase());
      });

    final exportedAt = DateTime.now().toIso8601String();
    final headers = <String>[
      '导出时间',
      '会议标题',
      '会议号',
      '显示名称',
      '参会标识',
      '成员类型',
      '用户ID',
      '角色标识',
      '角色名称',
      '麦克风开启',
      '摄像头开启',
      '正在共享屏幕',
      '允许自行开麦',
      '允许开视频',
      '允许聊天',
      '允许屏幕共享',
    ];
    final buffer = StringBuffer()..writeln(headers.map(_csvEscape).join(','));
    for (final row in sortedRows) {
      final values = <String>[
        exportedAt,
        _meetingTitle,
        _roomNumber,
        row.displayName,
        row.identity,
        row.userId == null ? '访客' : '已注册成员',
        row.userId?.toString() ?? '',
        row.roleKey,
        row.role,
        row.micEnabled ? 'true' : 'false',
        row.cameraEnabled ? 'true' : 'false',
        row.isScreenSharing ? 'true' : 'false',
        row.allowSelfUnmute ? 'true' : 'false',
        row.allowMemberVideo ? 'true' : 'false',
        row.allowChat ? 'true' : 'false',
        row.allowScreenShare ? 'true' : 'false',
      ];
      buffer.writeln(values.map(_csvEscape).join(','));
    }

    final fileName = _participantExportFileName();
    final csvText = '\uFEFF${buffer.toString()}';
    final csvBytes = utf8.encode(csvText);
    final blob = html.Blob([csvBytes], 'text/csv;charset=utf-8');
    final blobUrl = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: blobUrl)
      ..download = fileName
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    html.Url.revokeObjectUrl(blobUrl);
    _setStatus('入会名单导出成功：$fileName');
  }

  Future<void> _copyMeetingNumber() async {
    final value = _roomNumber.trim();
    if (value.isEmpty || value == '-') {
      _setStatus('当前没有可复制的会议号');
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    _setStatus('会议号已复制：$value');
  }

  String _resolvedShareUrl() {
    final fromApi = _shareUrl.trim();
    if (fromApi.isNotEmpty) {
      final parsed = Uri.tryParse(fromApi);
      if (parsed != null) {
        if (parsed.hasScheme) {
          return fromApi;
        }
        if (fromApi.startsWith('/')) {
          return Uri.base.resolve(fromApi).toString();
        }
      }
    }
    if (_isShareEntry) {
      final code = (widget.shareCode ?? '').trim();
      if (code.isNotEmpty) {
        return Uri.base.resolve('/m/$code').toString();
      }
    }
    return '';
  }

  String _meetingShareInfoText() {
    final shareUrl = _resolvedShareUrl();
    final waitingRoomLabel = _waitingRoomEnabled ? '开启' : '关闭';
    final guestJoinLabel = _allowGuestLinkJoin ? '允许' : '禁止';
    final lines = <String>[
      '会议标题：$_meetingTitle',
      '会议号：$_roomNumber',
      '等候室：$waitingRoomLabel',
      '访客链接入会：$guestJoinLabel',
    ];
    if (shareUrl.isNotEmpty) {
      lines.add('分享链接：$shareUrl');
    }
    return lines.join('\n');
  }

  Future<void> _openMeetingShareDialog() async {
    final shareUrl = _resolvedShareUrl();
    if (shareUrl.isEmpty) {
      _setStatus('当前会议暂时无法生成分享链接');
      return;
    }
    final shareInfo = _meetingShareInfoText();

    Future<void> copyText(String text, String successMessage) async {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      _setStatus(successMessage);
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _palette.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _palette.primaryBorder),
        ),
        titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
        contentPadding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        title: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _palette.primarySoft,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(
                Icons.share_outlined,
                size: 16,
                color: _palette.primaryStrong,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '会议分享',
              style: TextStyle(
                color: _palette.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 17,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 600,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: _palette.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _palette.panelBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '邀请链接',
                            style: TextStyle(
                              color: _palette.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: _palette.primaryStrong,
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () =>
                              unawaited(copyText(shareUrl, '分享链接已复制')),
                          icon: const Icon(Icons.copy_outlined, size: 14),
                          label: const Text('复制'),
                        ),
                      ],
                    ),
                    SelectableText(
                      shareUrl,
                      style: TextStyle(
                        color: _palette.textSecondary,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: _palette.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _palette.panelBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '完整会议信息',
                            style: TextStyle(
                              color: _palette.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: _palette.primaryStrong,
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () =>
                              unawaited(copyText(shareInfo, '会议信息已复制')),
                          icon: const Icon(Icons.content_copy, size: 14),
                          label: const Text('复制'),
                        ),
                      ],
                    ),
                    SelectableText(
                      shareInfo,
                      style: TextStyle(
                        color: _palette.textSecondary,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  int? _userIdFromIdentity(String identity) {
    if (!identity.startsWith('u')) return null;
    final marker = identity.indexOf('_');
    final idPart =
        marker > 1 ? identity.substring(1, marker) : identity.substring(1);
    return int.tryParse(idPart);
  }

  MeetingMemberProfile? _profileForIdentity(String identity) {
    final userId = _userIdFromIdentity(identity);
    if (userId == null) return null;
    return _memberProfiles[userId];
  }

  String _realtimeBotVirtualIdentity() {
    final identity = _realtimeBotIdentity.trim();
    if (identity.isNotEmpty) return identity;
    return '__realtime_bot__';
  }

  String _friendlyIdentityFallback(String identity) {
    final trimmed = identity.trim();
    if (trimmed.startsWith('g_')) {
      final parts = trimmed.split('_');
      if (parts.length >= 3) {
        final display = parts.sublist(2).join('_').replaceAll('_', ' ').trim();
        if (display.isNotEmpty) {
          return display;
        }
      }
      return '访客';
    }
    return trimmed;
  }

  String? _runtimeDisplayNameForIdentity(String identity) {
    final cached = _runtimeDisplayNamesByIdentity[identity]?.trim() ?? '';
    if (cached.isEmpty) return null;
    return cached;
  }

  String? _connectedIdentityForUserId(int userId) {
    final room = _room;
    if (room == null) return null;
    final local = room.localParticipant;
    if (local != null && _userIdFromIdentity(local.identity) == userId) {
      return local.identity;
    }
    for (final participant in room.remoteParticipants.values) {
      if (_userIdFromIdentity(participant.identity) == userId) {
        return participant.identity;
      }
    }
    return null;
  }

  Set<int> _connectedUserIdsInRoom() {
    final room = _room;
    if (room == null) return const <int>{};
    final ids = <int>{};
    final local = room.localParticipant;
    if (local != null) {
      final localUserId = _userIdFromIdentity(local.identity);
      if (localUserId != null) {
        ids.add(localUserId);
      }
    }
    for (final participant in room.remoteParticipants.values) {
      final userId = _userIdFromIdentity(participant.identity);
      if (userId != null) {
        ids.add(userId);
      }
    }
    return ids;
  }

  MeetingMemberProfile _memberProfileWithDisplayName(
    MeetingMemberProfile profile,
    String displayName, {
    int? displayNameVersion,
  }) {
    return MeetingMemberProfile(
      userId: profile.userId,
      username: profile.username,
      displayName: displayName,
      displayNameVersion: displayNameVersion ?? profile.displayNameVersion,
      avatarUrl: profile.avatarUrl,
      role: profile.role,
      mutedByHost: profile.mutedByHost,
      videoBlockedByHost: profile.videoBlockedByHost,
      allowSelfUnmute: profile.allowSelfUnmute,
      allowMemberVideo: profile.allowMemberVideo,
      allowChat: profile.allowChat,
      allowScreenShare: profile.allowScreenShare,
      micRequestPending: profile.micRequestPending,
      videoRequestPending: profile.videoRequestPending,
    );
  }

  void _applyIdentityDisplayNameLocally(
    String identity,
    String displayName, {
    int? userId,
    int? displayNameVersion,
  }) {
    final nextName = displayName.trim();
    if (nextName.isEmpty || !mounted) return;
    setState(() {
      _runtimeDisplayNamesByIdentity[identity] = nextName;
      final resolvedUserId = userId ?? _userIdFromIdentity(identity);
      if (resolvedUserId != null) {
        final profile = _memberProfiles[resolvedUserId];
        final profileNameChanged =
            profile != null && profile.displayName.trim() != nextName;
        final profileVersionChanged = profile != null &&
            displayNameVersion != null &&
            profile.displayNameVersion != displayNameVersion;
        if (profile != null && (profileNameChanged || profileVersionChanged)) {
          _memberProfiles = <int, MeetingMemberProfile>{
            ..._memberProfiles,
            resolvedUserId: _memberProfileWithDisplayName(
              profile,
              nextName,
              displayNameVersion: displayNameVersion,
            ),
          };
        }
        final localUserId = _localUserId;
        if (localUserId != null &&
            localUserId == resolvedUserId &&
            _meetingDisplayName.trim() != nextName) {
          _meetingDisplayName = nextName;
        }
      } else {
        if (displayNameVersion != null && displayNameVersion > 0) {
          _guestDisplayNameVersionsByIdentity[identity] = displayNameVersion;
        }
        final localIdentity = _room?.localParticipant?.identity;
        if (localIdentity != null &&
            localIdentity == identity &&
            _meetingDisplayName.trim() != nextName) {
          _meetingDisplayName = nextName;
        }
      }
    });
  }

  String _displayNameForIdentity(String identity, {String? fallback}) {
    final runtimeDisplayName = _runtimeDisplayNameForIdentity(identity);
    if (runtimeDisplayName != null) {
      return runtimeDisplayName;
    }
    final profile = _profileForIdentity(identity);
    if (profile != null && profile.displayName.trim().isNotEmpty) {
      return profile.displayName.trim();
    }
    if (_meetingDisplayName.trim().isNotEmpty) {
      final userId = _userIdFromIdentity(identity);
      final localUserId =
          _userIdFromIdentity(_room?.localParticipant?.identity ?? '');
      if (userId != null && localUserId != null && userId == localUserId) {
        return _meetingDisplayName.trim();
      }
    }
    return (fallback ?? _friendlyIdentityFallback(identity)).trim();
  }

  String _avatarUrlForIdentity(String identity) {
    final profile = _profileForIdentity(identity);
    if (profile != null && profile.avatarUrl.trim().isNotEmpty) {
      return profile.avatarUrl.trim();
    }
    final userId = _userIdFromIdentity(identity);
    final localUserId =
        _userIdFromIdentity(_room?.localParticipant?.identity ?? '');
    if (userId != null && localUserId != null && userId == localUserId) {
      return _profileAvatarUrl;
    }
    return '';
  }

  Map<String, dynamic> _participantMetadataAsMap(lk.Participant participant) {
    final raw = (participant.metadata ?? '').trim();
    if (raw.isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      // Ignore malformed metadata payloads and fallback to empty.
    }
    return <String, dynamic>{};
  }

  String _participantDisplayNameFromMetadata(lk.Participant participant) {
    final payload = _participantMetadataAsMap(participant);
    return (payload[_displayNameMetadataKey] ?? '').toString().trim();
  }

  int _participantDisplayNameVersionFromMetadata(lk.Participant participant) {
    final payload = _participantMetadataAsMap(participant);
    return _intFromJson(payload[_displayNameVersionMetadataKey], 0);
  }

  Future<void> _setLocalDisplayNameMetadata(
    String displayName, {
    int? displayNameVersion,
    bool bumpVersionIfMissing = false,
  }) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    final normalized = displayName.trim();
    if (normalized.isEmpty) return;
    final payload = _participantMetadataAsMap(local);
    final currentVersion = _intFromJson(
      payload[_displayNameVersionMetadataKey],
      0,
    );
    var nextVersion = displayNameVersion ?? currentVersion;
    if (nextVersion <= 0) {
      nextVersion = currentVersion;
      if (nextVersion <= 0 || bumpVersionIfMissing) {
        nextVersion += 1;
      }
    }
    if (nextVersion <= 0) nextVersion = 1;
    payload[_displayNameMetadataKey] = normalized;
    payload[_displayNameVersionMetadataKey] = nextVersion;
    await local.setMetadata(jsonEncode(payload));
    _applyIdentityDisplayNameLocally(
      local.identity,
      normalized,
      userId: _userIdFromIdentity(local.identity),
      displayNameVersion: nextVersion,
    );
  }

  RequestPendingFlags _requestPendingFlagsForParticipant(
      lk.Participant participant) {
    final payload = _participantMetadataAsMap(participant);
    return RequestPendingFlags(
      micPending: _boolFromJson(payload[_micRequestMetadataKey], false),
      videoPending: _boolFromJson(payload[_videoRequestMetadataKey], false),
      screenSharePending:
          _boolFromJson(payload[_screenShareRequestMetadataKey], false),
    );
  }

  String? _metadataKeyForRequestType(String requestType) {
    switch (requestType.trim().toLowerCase()) {
      case 'mic':
        return _micRequestMetadataKey;
      case 'video':
        return _videoRequestMetadataKey;
      case 'screen_share':
        return _screenShareRequestMetadataKey;
      default:
        return null;
    }
  }

  bool _isLocalRequestPending(String requestType) {
    final local = _room?.localParticipant;
    if (local == null) {
      return false;
    }
    final flags = _requestPendingFlagsForParticipant(local);
    switch (requestType.trim().toLowerCase()) {
      case 'mic':
        return (_localMemberProfile?.micRequestPending ?? false) ||
            flags.micPending;
      case 'video':
        return (_localMemberProfile?.videoRequestPending ?? false) ||
            flags.videoPending;
      case 'screen_share':
        return flags.screenSharePending;
      default:
        return false;
    }
  }

  Future<void> _setLocalRequestPending(
    String requestType,
    bool pending,
  ) async {
    final local = _room?.localParticipant;
    if (local == null) {
      throw Exception('尚未加入会议');
    }
    final key = _metadataKeyForRequestType(requestType);
    if (key == null) {
      throw Exception('不支持的申请类型：$requestType');
    }
    final payload = _participantMetadataAsMap(local);
    payload[key] = pending;
    await local.setMetadata(jsonEncode(payload));
  }

  Future<bool> _submitPermissionRequest(String requestType) async {
    final normalized = requestType.trim().toLowerCase();
    if (_isLocalRequestPending(normalized)) {
      return false;
    }
    final canUseRaiseHandApi = (normalized == 'mic' || normalized == 'video') &&
        _hasPrivateMeetingApiScope &&
        _localUserId != null;

    if (canUseRaiseHandApi) {
      await _requestRaiseHand(normalized);
      try {
        await _setLocalRequestPending(normalized, true);
      } catch (_) {
        // Registered members rely on backend pending flags if metadata update fails.
      }
      return true;
    }

    await _setLocalRequestPending(normalized, true);
    return true;
  }

  Future<void> _reconcileLocalRequestMetadataWithPermissions() async {
    if (_updatingLocalRequestMetadata) {
      return;
    }
    final local = _room?.localParticipant;
    if (local == null) {
      return;
    }
    final flags = _requestPendingFlagsForParticipant(local);
    if (!flags.micPending && !flags.videoPending && !flags.screenSharePending) {
      return;
    }

    final canMic = _participantCanPublishSource(
      local,
      _microphoneTrackSourceValue,
    );
    final canVideo = _participantCanPublishSource(
      local,
      _cameraTrackSourceValue,
    );
    final canShare = _participantCanPublishSource(
          local,
          _screenShareTrackSourceValue,
        ) ||
        _participantCanPublishSource(
          local,
          _screenShareAudioTrackSourceValue,
        );

    final clearMic = flags.micPending && canMic;
    final clearVideo = flags.videoPending && canVideo;
    final clearShare = flags.screenSharePending && canShare;
    if (!clearMic && !clearVideo && !clearShare) {
      return;
    }

    _updatingLocalRequestMetadata = true;
    try {
      final payload = _participantMetadataAsMap(local);
      if (clearMic) {
        payload[_micRequestMetadataKey] = false;
      }
      if (clearVideo) {
        payload[_videoRequestMetadataKey] = false;
      }
      if (clearShare) {
        payload[_screenShareRequestMetadataKey] = false;
      }
      await local.setMetadata(jsonEncode(payload));
    } catch (_) {
      // Best effort cleanup.
    } finally {
      _updatingLocalRequestMetadata = false;
    }
  }

  Future<void> _forceEnableLocalMicFromHost() async {
    final local = _room?.localParticipant;
    if (local == null || _micEnabled) {
      return;
    }
    if (!_localCanSelfUnmute) {
      _setStatus('主持人尝试开启麦克风，但当前权限不允许');
      return;
    }
    if (!_micPermissionGranted) {
      final granted =
          await _requestBrowserPermissionWithRetry(audio: true, video: false);
      if (!granted) {
        _setStatus('主持人请求开启麦克风，但浏览器未授予麦克风权限');
        return;
      }
      if (mounted) {
        setState(() {
          _micPermissionGranted = true;
          _permissionWarning = null;
        });
      }
    }
    try {
      await local.setMicrophoneEnabled(
        true,
        audioCaptureOptions: _buildAudioCaptureOptions(),
      );
      if (!mounted) return;
      setState(() => _micEnabled = true);
      _syncRealtimeBotAudioIngress();
      _setStatus('主持人已为你开启麦克风');
    } catch (e) {
      _setStatus('主持人请求开启麦克风失败：${_friendlyError(e)}');
    }
  }

  Future<void> _forceEnableLocalCameraFromHost() async {
    final local = _room?.localParticipant;
    if (local == null || _cameraEnabled) {
      return;
    }
    if (!_localCanMemberVideo) {
      _setStatus('主持人尝试开启摄像头，但当前权限不允许');
      return;
    }
    if (!_cameraPermissionGranted) {
      final granted =
          await _requestBrowserPermissionWithRetry(audio: false, video: true);
      if (!granted) {
        _setStatus('主持人请求开启摄像头，但浏览器未授予摄像头权限');
        return;
      }
      if (mounted) {
        setState(() {
          _cameraPermissionGranted = true;
          _permissionWarning = null;
        });
      }
    }
    try {
      await local.setCameraEnabled(
        true,
        cameraCaptureOptions: _buildCameraCaptureOptions(),
      );
      if (!mounted) return;
      setState(() => _cameraEnabled = true);
      _setStatus('主持人已为你开启摄像头');
    } catch (e) {
      _setStatus('主持人请求开启摄像头失败：${_friendlyError(e)}');
    }
  }

  Future<void> _handleHostForceOpenCommands() async {
    if (_handlingHostForceOpen) return;
    final local = _room?.localParticipant;
    if (local == null) return;
    final payload = _participantMetadataAsMap(local);
    final micNonce =
        (payload[_hostForceOpenMicMetadataKey] ?? '').toString().trim();
    final videoNonce =
        (payload[_hostForceOpenVideoMetadataKey] ?? '').toString().trim();
    final shouldHandleMic =
        micNonce.isNotEmpty && micNonce != _lastHandledHostForceMicNonce;
    final shouldHandleVideo =
        videoNonce.isNotEmpty && videoNonce != _lastHandledHostForceVideoNonce;
    if (!shouldHandleMic && !shouldHandleVideo) {
      return;
    }

    _handlingHostForceOpen = true;
    try {
      if (shouldHandleMic) {
        _lastHandledHostForceMicNonce = micNonce;
        await _forceEnableLocalMicFromHost();
      }
      if (shouldHandleVideo) {
        _lastHandledHostForceVideoNonce = videoNonce;
        await _forceEnableLocalCameraFromHost();
      }
    } finally {
      _handlingHostForceOpen = false;
    }
  }

  bool _isPermissionErrorText(String message) {
    final lower = message.toLowerCase();
    return lower.contains('permission') ||
        lower.contains('denied') ||
        lower.contains('notallowed') ||
        lower.contains('securityerror');
  }

  String _friendlyError(Object error) {
    if (error is MeetingApiException) {
      return error.detail;
    }
    final text = error.toString();
    final normalized = text.startsWith('Exception: ')
        ? text.substring('Exception: '.length)
        : text;
    final lowered = normalized.toLowerCase();
    if (lowered.contains('screen sharing is not supported on mobile devices') ||
        lowered.contains('screensharing is not supported on mobile devices') ||
        (lowered.contains('screen sharing') &&
            lowered.contains('not supported on mobile')) ||
        lowered.contains('getdisplaymedia is not supported')) {
      return '当前手机浏览器通常不支持屏幕共享，请改用电脑端 Chrome/Edge，或使用原生客户端后重试。';
    }
    return normalized;
  }

  bool _isWaitingRoomPendingError(Object error) {
    if (error is! MeetingApiException) return false;
    final status = (error.payload?['waiting_room_status'] ?? '').toString();
    return error.statusCode == 403 && status == 'pending';
  }

  bool _isWaitingRoomRejectedError(Object error) {
    if (error is! MeetingApiException) return false;
    final status = (error.payload?['waiting_room_status'] ?? '').toString();
    return error.statusCode == 403 && status == 'rejected';
  }

  bool _boolFromJson(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }

  int _intFromJson(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  DateTime? _dateTimeFromJson(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return parsed.toLocal();
  }

  void _refreshElapsedTicker() {
    if (_actualStartedAt == null) {
      _meetingElapsedTimer?.cancel();
      _meetingElapsedTimer = null;
      return;
    }
    _elapsedNow = DateTime.now();
    if (_meetingElapsedTimer != null) return;
    _meetingElapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _elapsedNow = DateTime.now();
      });
    });
  }

  int _activeParticipantCount() {
    if (!_connected || _room == null) return 0;
    final localCount = _room!.localParticipant == null ? 0 : 1;
    return localCount + _room!.remoteParticipants.length;
  }

  String _meetingElapsedText() {
    final startedAt = _actualStartedAt;
    if (startedAt == null) return '未开始';
    var elapsed = _elapsedNow.difference(startedAt);
    if (elapsed.isNegative) {
      elapsed = Duration.zero;
    }
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final hours = elapsed.inHours;
    final minutes = elapsed.inMinutes.remainder(60);
    final seconds = elapsed.inSeconds.remainder(60);
    return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  String _networkQualityLabel() {
    if (!_connected) return '未连接';
    final quality = _room?.localParticipant?.connectionQuality;
    switch (quality) {
      case lk.ConnectionQuality.excellent:
        return '优秀';
      case lk.ConnectionQuality.good:
        return '良好';
      case lk.ConnectionQuality.poor:
        return '较差';
      case lk.ConnectionQuality.lost:
        return '中断';
      case lk.ConnectionQuality.unknown:
      case null:
        return '检测中';
    }
  }

  IconData _networkQualityIcon() {
    if (!_connected) return Icons.wifi_off_rounded;
    final quality = _room?.localParticipant?.connectionQuality;
    switch (quality) {
      case lk.ConnectionQuality.excellent:
      case lk.ConnectionQuality.good:
        return Icons.wifi_rounded;
      case lk.ConnectionQuality.poor:
        return Icons.network_check_rounded;
      case lk.ConnectionQuality.lost:
        return Icons.signal_wifi_statusbar_connected_no_internet_4;
      case lk.ConnectionQuality.unknown:
      case null:
        return Icons.wifi_tethering_error_rounded;
    }
  }

  Color _networkQualityTint() {
    if (!_connected) return _palette.textMuted;
    final quality = _room?.localParticipant?.connectionQuality;
    switch (quality) {
      case lk.ConnectionQuality.excellent:
      case lk.ConnectionQuality.good:
        return _palette.success;
      case lk.ConnectionQuality.poor:
        return _palette.warning;
      case lk.ConnectionQuality.lost:
        return _palette.dangerSoft;
      case lk.ConnectionQuality.unknown:
      case null:
        return _palette.heroMutedText;
    }
  }

  Widget _buildTopMetricChip({
    required IconData icon,
    required String text,
    Color? accent,
  }) {
    final resolvedAccent = accent ?? _palette.heroMutedText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _palette.surfaceMuted,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _palette.primaryBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: resolvedAccent),
          const SizedBox(width: 5),
          MeetingMetaText(
            text,
            style: TextStyle(
              color: _palette.primaryStrong,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _roleLabel(String roleKey) {
    switch (roleKey.trim()) {
      case 'host':
        return '主持人';
      case 'cohost':
        return '联席主持人';
      default:
        return '成员';
    }
  }

  bool _isScreenSharing(lk.Participant participant) {
    final screenVideo = participant
        .getTrackPublicationBySource(lk.TrackSource.screenShareVideo);
    final screenAudio = participant
        .getTrackPublicationBySource(lk.TrackSource.screenShareAudio);
    return (screenVideo != null && !screenVideo.muted) ||
        (screenAudio != null && !screenAudio.muted);
  }

  int? _trackSourceValueFromDynamic(dynamic source) {
    if (source is int) return source;

    try {
      final dynamic rawValue = source.value;
      if (rawValue is int) return rawValue;
      if (rawValue != null) {
        final parsed = int.tryParse(rawValue.toString());
        if (parsed != null) return parsed;
      }
    } catch (_) {}

    final rawToken = source.toString().trim().toLowerCase();
    final numeric = int.tryParse(rawToken);
    if (numeric != null) return numeric;
    final token = rawToken.contains('.') ? rawToken.split('.').last : rawToken;
    return _trackSourceTokenToValue[token];
  }

  Set<int> _participantPublishSourceValues(lk.Participant participant) {
    final values = <int>{};
    for (final source in participant.permissions.canPublishSources) {
      final sourceValue = _trackSourceValueFromDynamic(source);
      if (sourceValue != null) {
        values.add(sourceValue);
      }
    }
    return values;
  }

  bool _participantCanPublishSource(
      lk.Participant participant, int sourceValue) {
    final permissions = participant.permissions;
    if (!permissions.canPublish) return false;
    final values = _participantPublishSourceValues(participant);
    if (values.isEmpty) {
      return participant.permissions.canPublishSources.isEmpty;
    }
    return values.contains(sourceValue);
  }

  bool _participantCanPublishChat(lk.Participant participant) {
    return participant.permissions.canPublishData;
  }

  bool _participantPermissionsReady(lk.Participant participant) {
    final permissions = participant.permissions;
    if (permissions.canSubscribe) return true;
    if (permissions.canPublish || permissions.canPublishData) return true;
    return _participantPublishSourceValues(participant).isNotEmpty;
  }

  lk.AudioCaptureOptions _buildAudioCaptureOptions() {
    final deviceId =
        (_selectedAudioInputId == null || _selectedAudioInputId!.isEmpty)
            ? null
            : _selectedAudioInputId;
    return lk.AudioCaptureOptions(
      deviceId: deviceId,
      echoCancellation: _echoCancellation,
      noiseSuppression: _noiseSuppression,
      autoGainControl: _autoGainControl,
    );
  }

  lk.CameraCaptureOptions _buildCameraCaptureOptions() {
    final deviceId =
        (_selectedVideoInputId == null || _selectedVideoInputId!.isEmpty)
            ? null
            : _selectedVideoInputId;
    return lk.CameraCaptureOptions(
      deviceId: deviceId,
      params: _cameraVideoParameters(),
    );
  }

  lk.VideoParameters _cameraVideoParameters() {
    switch (_cameraResolutionPreset) {
      case CameraResolutionPreset.p720:
        return lk.VideoParametersPresets.h720_169;
      case CameraResolutionPreset.p1080:
        return lk.VideoParametersPresets.h1080_169;
      case CameraResolutionPreset.p1440:
        return lk.VideoParametersPresets.h1440_169;
      case CameraResolutionPreset.p2160:
        return lk.VideoParametersPresets.h2160_169;
    }
  }

  lk.VideoParameters _screenShareVideoParameters() {
    switch (_screenShareResolutionPreset) {
      case ScreenShareResolutionPreset.p720:
        return lk.VideoParametersPresets.screenShareH720FPS15;
      case ScreenShareResolutionPreset.p1080:
        return lk.VideoParametersPresets.screenShareH1080FPS15;
      case ScreenShareResolutionPreset.p1440:
        return lk.VideoParametersPresets.screenShareH1440FPS30;
      case ScreenShareResolutionPreset.p2160:
        return lk.VideoParametersPresets.screenShareH2160FPS30;
    }
  }

  String _cameraResolutionLabel(CameraResolutionPreset preset) {
    switch (preset) {
      case CameraResolutionPreset.p720:
        return '1280 x 720';
      case CameraResolutionPreset.p1080:
        return '1920 x 1080';
      case CameraResolutionPreset.p1440:
        return '2560 x 1440';
      case CameraResolutionPreset.p2160:
        return '3840 x 2160';
    }
  }

  lk.ScreenShareCaptureOptions _buildScreenShareCaptureOptions({
    bool captureScreenAudio = false,
  }) {
    return lk.ScreenShareCaptureOptions(
      captureScreenAudio: captureScreenAudio,
      params: _screenShareVideoParameters(),
    );
  }

  String _screenShareResolutionLabel(ScreenShareResolutionPreset preset) {
    switch (preset) {
      case ScreenShareResolutionPreset.p720:
        return '1280 x 720';
      case ScreenShareResolutionPreset.p1080:
        return '1920 x 1080';
      case ScreenShareResolutionPreset.p1440:
        return '2560 x 1440';
      case ScreenShareResolutionPreset.p2160:
        return '3840 x 2160';
    }
  }

  String _remoteShareViewModeLabel(RemoteShareViewMode mode) {
    if (mode == RemoteShareViewMode.original) {
      return '保持原比例';
    }
    if (mode == RemoteShareViewMode.stretch) {
      return '拉伸';
    }
    switch (mode) {
      case RemoteShareViewMode.original:
        return '保持原比例';
      case RemoteShareViewMode.stretch:
      // ignore: unreachable_switch_default
      default:
        return '拉伸';
    }
  }

  lk.VideoViewFit _videoFitForTile(ParticipantTileData tile) {
    final mode =
        tile.isScreenShare ? _remoteShareViewMode : _remoteCameraViewMode;
    switch (mode) {
      case RemoteShareViewMode.original:
        return lk.VideoViewFit.contain;
      case RemoteShareViewMode.stretch:
        return lk.VideoViewFit.cover;
    }
  }

  lk.MediaDevice? _findDeviceById(List<lk.MediaDevice> devices, String? id) {
    if (id == null || id.isEmpty) return null;
    for (final device in devices) {
      if (device.deviceId == id) return device;
    }
    return null;
  }

  String _deviceLabel(lk.MediaDevice device, String fallback, int index) {
    final label = device.label.trim();
    if (label.isNotEmpty) return label;
    return '$fallback ${index + 1}';
  }

  Future<void> _loadMediaDevices() async {
    try {
      final audioInputs = await lk.Hardware.instance.audioInputs();
      final audioOutputs = await lk.Hardware.instance.audioOutputs();
      final videoInputs = await lk.Hardware.instance.videoInputs();
      if (!mounted) return;
      setState(() {
        _audioInputs = audioInputs;
        _audioOutputs = audioOutputs;
        _videoInputs = videoInputs;
        _selectedAudioInputId ??=
            audioInputs.isNotEmpty ? audioInputs.first.deviceId : null;
        _selectedAudioOutputId ??=
            audioOutputs.isNotEmpty ? audioOutputs.first.deviceId : null;
        _selectedVideoInputId ??=
            videoInputs.isNotEmpty ? videoInputs.first.deviceId : null;
      });
    } catch (e) {
      _setStatus('读取设备列表失败：${_friendlyError(e)}');
    }
  }

  Future<bool> _requestBrowserPermission({
    required bool audio,
    required bool video,
  }) async {
    if (!audio && !video) return true;
    final devices = html.window.navigator.mediaDevices;
    if (devices == null) return false;
    try {
      final stream = await devices.getUserMedia({
        'audio': audio,
        'video': video,
      }).timeout(_permissionRequestTimeout);
      for (final track in stream.getTracks()) {
        track.stop();
      }
      return true;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _requestBrowserPermissionWithRetry({
    required bool audio,
    required bool video,
  }) async {
    if (await _requestBrowserPermission(audio: audio, video: video)) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 180));
    return _requestBrowserPermission(audio: audio, video: video);
  }

  Future<List<String>> _ensurePermissionsForJoin({
    required bool enableMic,
    required bool enableCamera,
  }) async {
    final denied = <String>[];
    final micOk = !enableMic
        ? true
        : await _requestBrowserPermissionWithRetry(audio: true, video: false);
    final cameraOk = !enableCamera
        ? true
        : await _requestBrowserPermissionWithRetry(audio: false, video: true);
    if (!mounted) return denied;
    setState(() {
      _micPermissionGranted = micOk;
      _cameraPermissionGranted = cameraOk;
      if (micOk && cameraOk) {
        _permissionWarning = null;
      }
    });
    if (!micOk) denied.add('麦克风');
    if (!cameraOk) denied.add('摄像头');
    return denied;
  }

  Future<void> _showPermissionDeniedDialog(List<String> denied) async {
    if (denied.isEmpty || !mounted) return;
    setState(() {
      _permissionWarning =
          '未获取到 ${denied.join('、')} 权限，已尝试重新申请但仍被禁用。请在浏览器站点权限中开启后重试。';
    });
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

  TransformationController _zoomControllerFor(String identity) {
    return _tileZoomControllers.putIfAbsent(
      identity,
      () => TransformationController(),
    );
  }

  double _zoomScaleOf(String identity) {
    final controller = _tileZoomControllers[identity];
    if (controller == null) return 1;
    return _matrixScale(controller.value);
  }

  double _matrixScale(Matrix4 matrix) {
    final sx = matrix.storage[0].abs();
    final sy = matrix.storage[5].abs();
    final avg = (sx + sy) / 2;
    if (!avg.isFinite || avg <= 0) return 1;
    return avg;
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

  Future<void> _applyMediaSettingsToRoom({
    bool republishIfEnabled = false,
  }) async {
    final room = _room;
    if (room == null) return;
    try {
      final audioInput = _findDeviceById(_audioInputs, _selectedAudioInputId);
      final audioOutput =
          _findDeviceById(_audioOutputs, _selectedAudioOutputId);
      final videoInput = _findDeviceById(_videoInputs, _selectedVideoInputId);

      if (audioInput != null) {
        await room.setAudioInputDevice(audioInput);
      }
      if (audioOutput != null) {
        await room.setAudioOutputDevice(audioOutput);
      }
      if (videoInput != null) {
        await room.setVideoInputDevice(videoInput);
      }

      final local = room.localParticipant;
      if (local != null && republishIfEnabled && local.isMicrophoneEnabled()) {
        await local.setMicrophoneEnabled(
          false,
          audioCaptureOptions: _buildAudioCaptureOptions(),
        );
        await local.setMicrophoneEnabled(
          true,
          audioCaptureOptions: _buildAudioCaptureOptions(),
        );
      }
      if (local != null && republishIfEnabled && local.isCameraEnabled()) {
        await local.setCameraEnabled(
          false,
          cameraCaptureOptions: _buildCameraCaptureOptions(),
        );
        await local.setCameraEnabled(
          true,
          cameraCaptureOptions: _buildCameraCaptureOptions(),
        );
      }
      _onRoomUpdated();
    } catch (e) {
      _setStatus('应用音视频设置失败：${_friendlyError(e)}');
    }
  }

  Future<void> _openMediaSettingsDialog() async {
    await _loadMediaDevices();
    if (!mounted) return;

    var audioInputId = _selectedAudioInputId;
    var audioOutputId = _selectedAudioOutputId;
    var videoInputId = _selectedVideoInputId;
    var echoCancellation = _echoCancellation;
    var noiseSuppression = _noiseSuppression;
    var autoGainControl = _autoGainControl;
    var cameraResolutionPreset = _cameraResolutionPreset;
    var screenShareResolutionPreset = _screenShareResolutionPreset;
    var adaptiveStreamEnabled = _adaptiveStreamEnabled;
    var dynacastEnabled = _dynacastEnabled;
    var remoteCameraViewMode = _remoteCameraViewMode;
    var remoteShareViewMode = _remoteShareViewMode;
    var micTesting = false;
    var cameraTesting = false;
    var micTestStatus = '尚未开始麦克风测试';
    var cameraTestStatus = '尚未开始摄像头测试';
    var micTestLevel = 0.0;
    String? cameraPreviewViewType;
    web.MediaStream? micTestStream;
    html.MediaStream? cameraTestStream;
    html.VideoElement? cameraPreviewElement;
    web.AudioContext? micTestAudioContext;
    web.AnalyserNode? micTestAnalyser;
    web.MediaStreamAudioSourceNode? micTestSource;
    Timer? micLevelTimer;

    if (_findDeviceById(_audioInputs, audioInputId) == null) {
      audioInputId =
          _audioInputs.isNotEmpty ? _audioInputs.first.deviceId : null;
    }
    if (_findDeviceById(_audioOutputs, audioOutputId) == null) {
      audioOutputId =
          _audioOutputs.isNotEmpty ? _audioOutputs.first.deviceId : null;
    }
    if (_findDeviceById(_videoInputs, videoInputId) == null) {
      videoInputId =
          _videoInputs.isNotEmpty ? _videoInputs.first.deviceId : null;
    }

    final applied = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) {
              final theme = Theme.of(context);
              final colors = theme.colorScheme;

              Future<void> stopMicTest({bool resetStatus = true}) async {
                micLevelTimer?.cancel();
                micLevelTimer = null;
                try {
                  await micTestAudioContext?.close().toDart;
                } catch (_) {}
                micTestAudioContext = null;
                micTestAnalyser = null;
                try {
                  micTestSource?.disconnect();
                } catch (_) {}
                micTestSource = null;
                for (final track
                    in micTestStream?.getTracks().toDart ?? const []) {
                  track.stop();
                }
                micTestStream = null;
                setDialogState(() {
                  micTesting = false;
                  micTestLevel = 0;
                  if (resetStatus) {
                    micTestStatus = '麦克风测试已停止';
                  }
                });
              }

              Future<void> stopCameraTest({bool resetStatus = true}) async {
                try {
                  cameraPreviewElement?.pause();
                } catch (_) {}
                cameraPreviewElement?.srcObject = null;
                cameraPreviewElement = null;
                cameraTestStream?.getTracks().forEach((track) => track.stop());
                cameraTestStream = null;
                setDialogState(() {
                  cameraTesting = false;
                  cameraPreviewViewType = null;
                  if (resetStatus) {
                    cameraTestStatus = '摄像头测试已停止';
                  }
                });
              }

              Future<void> runMicTest() async {
                await stopMicTest(resetStatus: false);
                setDialogState(() {
                  micTesting = true;
                  micTestLevel = 0;
                  micTestStatus = '正在采集麦克风输入...';
                });
                try {
                  final mediaDevices = web.window.navigator.mediaDevices;
                  if (mediaDevices == null) {
                    throw StateError('浏览器不支持媒体设备测试');
                  }
                  final audioConstraints = audioInputId == null
                      ? web.MediaTrackConstraints(
                          echoCancellation: echoCancellation.toJS,
                          noiseSuppression: noiseSuppression.toJS,
                          autoGainControl: autoGainControl.toJS,
                        )
                      : web.MediaTrackConstraints(
                          deviceId: web.ConstrainDOMStringParameters(
                            exact: audioInputId!.toJS,
                          ),
                          echoCancellation: echoCancellation.toJS,
                          noiseSuppression: noiseSuppression.toJS,
                          autoGainControl: autoGainControl.toJS,
                        );
                  final stream = await mediaDevices
                      .getUserMedia(
                        web.MediaStreamConstraints(
                          audio: audioConstraints,
                          video: false.toJS,
                        ),
                      )
                      .toDart;
                  micTestStream = stream;
                  micTestAudioContext = web.AudioContext(
                    web.AudioContextOptions(
                      latencyHint: 'interactive'.toJS,
                    ),
                  );
                  final ctx = micTestAudioContext!;
                  try {
                    await ctx.resume().toDart.timeout(
                          const Duration(seconds: 3),
                        );
                  } catch (_) {
                    // Best effort only.
                  }
                  micTestAnalyser = ctx.createAnalyser()
                    ..fftSize = 2048
                    ..smoothingTimeConstant = 0.8;
                  micTestSource = ctx.createMediaStreamSource(stream);
                  micTestSource!.connect(micTestAnalyser!);
                  micLevelTimer = Timer.periodic(
                    const Duration(milliseconds: 120),
                    (_) {
                      final analyser = micTestAnalyser;
                      if (analyser == null) return;
                      final data =
                          JSUint8Array.withLength(analyser.frequencyBinCount);
                      analyser.getByteTimeDomainData(data);
                      final samples = data.toDart;
                      if (!mounted) return;
                      setDialogState(() {
                        micTestLevel = computeNormalizedMicTestLevel(samples);
                        micTestStatus =
                            micTestLevel > 0.04 ? '已检测到麦克风输入' : '等待你说话以验证麦克风';
                      });
                    },
                  );
                } catch (e) {
                  await stopMicTest(resetStatus: false);
                  setDialogState(() {
                    micTestStatus = '麦克风测试失败：${_friendlyError(e)}';
                  });
                }
              }

              Future<void> runCameraTest() async {
                await stopCameraTest(resetStatus: false);
                setDialogState(() {
                  cameraTesting = true;
                  cameraTestStatus = '正在打开摄像头预览...';
                });
                try {
                  final mediaDevices = html.window.navigator.mediaDevices;
                  if (mediaDevices == null) {
                    throw StateError('浏览器不支持媒体设备测试');
                  }
                  final stream =
                      await mediaDevices.getUserMedia(<String, dynamic>{
                    'audio': false,
                    'video': <String, dynamic>{
                      'deviceId': videoInputId == null
                          ? null
                          : <String, String>{'exact': videoInputId!},
                    },
                  });
                  cameraTestStream = stream;
                  final preview = html.VideoElement()
                    ..autoplay = true
                    ..muted = true
                    ..setAttribute('playsinline', 'true')
                    ..style.width = '100%'
                    ..style.height = '100%'
                    ..style.objectFit = 'cover'
                    ..srcObject = stream;
                  final viewType =
                      'meeting-room-camera-preview-${_cameraPreviewFactoryCounter++}';
                  ui_web.platformViewRegistry.registerViewFactory(
                    viewType,
                    (int _) => preview,
                  );
                  cameraPreviewElement = preview;
                  setDialogState(() {
                    cameraPreviewViewType = viewType;
                    cameraTestStatus = '摄像头预览中';
                  });
                } catch (e) {
                  await stopCameraTest(resetStatus: false);
                  setDialogState(() {
                    cameraTestStatus = '摄像头测试失败：${_friendlyError(e)}';
                  });
                }
              }

              return AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                insetPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                contentPadding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                title: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: colors.primary.withValues(alpha: 0.12),
                      child: Icon(
                        Icons.tune_rounded,
                        color: colors.primary,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('音视频设置'),
                          Text(
                            '调整设备、音质与画面传输策略',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: 760,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: colors.primary.withValues(alpha: 0.08),
                              border: Border.all(
                                color: colors.primary.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Text(
                              '建议优先完成设备选择和测试，再调整画面传输策略。',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const Text('输入/输出设备',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<String>(
                            value: audioInputId,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '麦克风设备'),
                            items: _audioInputs.asMap().entries.map((entry) {
                              final i = entry.key;
                              final device = entry.value;
                              return DropdownMenuItem<String>(
                                value: device.deviceId,
                                child: Text(_deviceLabel(device, '麦克风', i)),
                              );
                            }).toList(),
                            onChanged: (v) =>
                                setDialogState(() => audioInputId = v),
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<String>(
                            value: audioOutputId,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '扬声器设备'),
                            items: _audioOutputs.asMap().entries.map((entry) {
                              final i = entry.key;
                              final device = entry.value;
                              return DropdownMenuItem<String>(
                                value: device.deviceId,
                                child: Text(_deviceLabel(device, '扬声器', i)),
                              );
                            }).toList(),
                            onChanged: (v) =>
                                setDialogState(() => audioOutputId = v),
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<String>(
                            value: videoInputId,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '摄像头设备'),
                            items: _videoInputs.asMap().entries.map((entry) {
                              final i = entry.key;
                              final device = entry.value;
                              return DropdownMenuItem<String>(
                                value: device.deviceId,
                                child: Text(_deviceLabel(device, '摄像头', i)),
                              );
                            }).toList(),
                            onChanged: (v) =>
                                setDialogState(() => videoInputId = v),
                          ),
                          const SizedBox(height: 14),
                          const Text('音频增强',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          SwitchListTile.adaptive(
                            value: noiseSuppression,
                            onChanged: (v) =>
                                setDialogState(() => noiseSuppression = v),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('噪声抑制'),
                          ),
                          SwitchListTile.adaptive(
                            value: echoCancellation,
                            onChanged: (v) =>
                                setDialogState(() => echoCancellation = v),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('回声消除'),
                          ),
                          SwitchListTile.adaptive(
                            value: autoGainControl,
                            onChanged: (v) =>
                                setDialogState(() => autoGainControl = v),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('自动增益'),
                          ),
                          const SizedBox(height: 8),
                          DeviceTestCard(
                            title: '麦克风测试',
                            description: '检查输入设备是否可用，并观察说话时音量变化',
                            icon: Icons.mic_none_rounded,
                            isRunning: micTesting,
                            statusText: micTestStatus,
                            statusIsError: micTestStatus.contains('失败'),
                            primaryActionLabel: micTesting ? '重新测试' : '开始测试',
                            secondaryActionLabel: '停止测试',
                            onPrimaryAction: runMicTest,
                            onSecondaryAction: micTesting ? stopMicTest : null,
                            footer: Row(
                              children: [
                                SizedBox(
                                  width: 72,
                                  child: Text(
                                    '输入电平',
                                    style: TextStyle(
                                      color: _palette.textMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: ParticipantAudioLevelBar(
                                    level: micTestLevel,
                                    isActive: micTesting && micTestLevel > 0.02,
                                    width: double.infinity,
                                    height: 8,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 44,
                                  child: Text(
                                    '${(micTestLevel * 100).round()}%',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      color: _palette.textMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          DeviceTestCard(
                            title: '摄像头测试',
                            description: '检查所选摄像头是否能正常出画',
                            icon: Icons.videocam_outlined,
                            isRunning: cameraTesting,
                            statusText: cameraTestStatus,
                            statusIsError: cameraTestStatus.contains('失败'),
                            primaryActionLabel: cameraTesting ? '重新测试' : '开始测试',
                            secondaryActionLabel: '停止测试',
                            onPrimaryAction: runCameraTest,
                            onSecondaryAction:
                                cameraTesting ? stopCameraTest : null,
                            preview: Container(
                              height: 180,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: _palette.textStrong,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _palette.panelBorder,
                                ),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: cameraPreviewViewType == null
                                  ? Center(
                                      child: Text(
                                        '开始测试后会在这里显示摄像头预览',
                                        style: TextStyle(
                                          color: _palette.textMuted,
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    )
                                  : HtmlElementView(
                                      viewType: cameraPreviewViewType!,
                                    ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Divider(height: 1),
                          const SizedBox(height: 14),
                          const Text('画面与传输',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<CameraResolutionPreset>(
                            value: cameraResolutionPreset,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '本机摄像头分辨率'),
                            items: CameraResolutionPreset.values
                                .map((preset) => DropdownMenuItem(
                                      value: preset,
                                      child:
                                          Text(_cameraResolutionLabel(preset)),
                                    ))
                                .toList(),
                            onChanged: (value) {
                              if (value == null) return;
                              setDialogState(
                                  () => cameraResolutionPreset = value);
                            },
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<ScreenShareResolutionPreset>(
                            value: screenShareResolutionPreset,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '本机共享分辨率'),
                            items: ScreenShareResolutionPreset.values
                                .map((preset) => DropdownMenuItem(
                                      value: preset,
                                      child: Text(
                                          _screenShareResolutionLabel(preset)),
                                    ))
                                .toList(),
                            onChanged: (value) {
                              if (value == null) return;
                              setDialogState(
                                  () => screenShareResolutionPreset = value);
                            },
                          ),
                          const SizedBox(height: 10),
                          SwitchListTile.adaptive(
                            value: adaptiveStreamEnabled,
                            onChanged: (value) => setDialogState(
                              () => adaptiveStreamEnabled = value,
                            ),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('自适应订阅清晰度'),
                            subtitle: const Text(
                              '开启后会按画面大小自动降低订阅清晰度，关闭可优先保持最高画质。',
                            ),
                          ),
                          SwitchListTile.adaptive(
                            value: dynacastEnabled,
                            onChanged: (value) =>
                                setDialogState(() => dynacastEnabled = value),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('动态分层推流'),
                            subtitle: const Text(
                              '开启后会节省带宽，关闭可优先保持高分辨率稳定输出。',
                            ),
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<RemoteShareViewMode>(
                            value: remoteCameraViewMode,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '观看成员摄像头画面'),
                            items: RemoteShareViewMode.values
                                .map((mode) => DropdownMenuItem(
                                      value: mode,
                                      child:
                                          Text(_remoteShareViewModeLabel(mode)),
                                    ))
                                .toList(),
                            onChanged: (value) {
                              if (value == null) return;
                              setDialogState(
                                  () => remoteCameraViewMode = value);
                            },
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<RemoteShareViewMode>(
                            value: remoteShareViewMode,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '观看成员共享画面'),
                            items: RemoteShareViewMode.values
                                .map((mode) => DropdownMenuItem(
                                      value: mode,
                                      child:
                                          Text(_remoteShareViewModeLabel(mode)),
                                    ))
                                .toList(),
                            onChanged: (value) {
                              if (value == null) return;
                              setDialogState(() => remoteShareViewMode = value);
                            },
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '拉伸会铺满窗口并可能裁剪边缘；保持原比例会完整显示并可能留黑边。',
                            style: TextStyle(
                              color: _palette.textMuted,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(context, true),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('应用设置'),
                  ),
                ],
              );
            },
          ),
        ) ??
        false;

    micLevelTimer?.cancel();
    try {
      await micTestAudioContext?.close().toDart;
    } catch (_) {}
    try {
      micTestSource?.disconnect();
    } catch (_) {}
    for (final track in micTestStream?.getTracks().toDart ?? const []) {
      track.stop();
    }
    cameraPreviewElement?.srcObject = null;
    cameraTestStream?.getTracks().forEach((track) => track.stop());

    if (!applied || !mounted) return;

    final roomTransportPolicyChanged =
        adaptiveStreamEnabled != _adaptiveStreamEnabled ||
            dynacastEnabled != _dynacastEnabled;

    setState(() {
      _selectedAudioInputId = audioInputId;
      _selectedAudioOutputId = audioOutputId;
      _selectedVideoInputId = videoInputId;
      _echoCancellation = echoCancellation;
      _noiseSuppression = noiseSuppression;
      _autoGainControl = autoGainControl;
      _cameraResolutionPreset = cameraResolutionPreset;
      _screenShareResolutionPreset = screenShareResolutionPreset;
      _adaptiveStreamEnabled = adaptiveStreamEnabled;
      _dynacastEnabled = dynacastEnabled;
      _remoteCameraViewMode = remoteCameraViewMode;
      _remoteShareViewMode = remoteShareViewMode;
    });
    await _applyMediaSettingsToRoom(republishIfEnabled: true);
    if (roomTransportPolicyChanged && _connected) {
      _setStatus('画质设置已保存，“自适应订阅清晰度/动态分层推流”将在下次重新入会后生效');
      return;
    }
    _setStatus('音视频设置已应用');
  }

  Future<void> _openMeetingDisplayNameDialog() async {
    final controller = TextEditingController(
      text: _meetingDisplayName.trim().isEmpty
          ? _defaultDisplayName
          : _meetingDisplayName,
    );
    final saved = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('本次会议显示名'),
            content: TextField(
              controller: controller,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: '显示名称',
                hintText: '将显示在参会成员列表和视频窗标题中',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保存'),
              ),
            ],
          ),
        ) ??
        false;
    if (!saved) {
      controller.dispose();
      return;
    }
    final next = controller.text.trim();
    controller.dispose();
    if (next.isEmpty) {
      _setStatus('显示名不能为空');
      return;
    }
    try {
      await _updateMyMeetingDisplayName(next);
      _setStatus('会议显示名已更新');
    } catch (e) {
      _setStatus('更新显示名失败：${_friendlyError(e)}');
    }
  }

  Future<void> _openJoinSetupDialog() async {
    if (_connected || _joining || !mounted) return;
    try {
      await _loadMeetingInfo();
    } catch (_) {
      // Use cached meeting policy when refresh fails.
    }
    if (_connected || _joining || !mounted) return;
    final controller = TextEditingController(
      text: _meetingDisplayName.trim().isEmpty
          ? _defaultDisplayName
          : _meetingDisplayName,
    );
    final passwordController = TextEditingController(text: _meetingPassword);
    var micEnabled = !_muteOnEntry;
    var cameraEnabled = _allowMemberVideo;

    final confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) {
              final theme = Theme.of(context);
              final colors = theme.colorScheme;
              final permissionWarning = _permissionWarning?.trim() ?? '';
              return AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                insetPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                contentPadding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                title: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: colors.primary.withValues(alpha: 0.12),
                      child: Icon(
                        Icons.video_call_rounded,
                        size: 18,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('入会前确认'),
                          Text(
                            '确认昵称、密码与设备状态后进入会议',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: 580,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * 0.72,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: colors.outlineVariant),
                              color: colors.surfaceContainerHighest.withValues(
                                alpha: 0.32,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '身份信息',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextField(
                                  controller: controller,
                                  maxLength: 80,
                                  decoration: const InputDecoration(
                                    labelText: '本次显示名',
                                    hintText: '其他参会者看到的名称',
                                  ),
                                ),
                                const SizedBox(height: 4),
                                TextField(
                                  controller: passwordController,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: '会议密码（如有）',
                                    hintText: '若主持人设置了密码，请输入',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: colors.outlineVariant),
                              color: colors.surfaceContainerHighest.withValues(
                                alpha: 0.32,
                              ),
                            ),
                            child: Column(
                              children: [
                                SwitchListTile.adaptive(
                                  value: micEnabled,
                                  onChanged: (v) =>
                                      setDialogState(() => micEnabled = v),
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('进入会议时开启麦克风'),
                                ),
                                const Divider(height: 1),
                                SwitchListTile.adaptive(
                                  value: cameraEnabled,
                                  onChanged: _allowMemberVideo
                                      ? (v) => setDialogState(
                                          () => cameraEnabled = v)
                                      : null,
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('进入会议时开启摄像头'),
                                  subtitle: !_allowMemberVideo
                                      ? const Text('主持人已禁止成员默认开启摄像头')
                                      : null,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: colors.primary.withValues(alpha: 0.08),
                              border: Border.all(
                                color: colors.primary.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.tips_and_updates_outlined,
                                  size: 18,
                                  color: colors.primary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '确认后将请求你所选择的设备权限，并立即尝试入会。',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (permissionWarning.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              padding:
                                  const EdgeInsets.fromLTRB(12, 10, 12, 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: _palette.warningSurface,
                                border:
                                    Border.all(color: _palette.warningBorder),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.warning_amber_rounded,
                                    size: 18,
                                    color: _palette.warning,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      permissionWarning,
                                      style: TextStyle(
                                        color: _palette.warning,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('稍后加入'),
                  ),
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(context, true),
                    icon: const Icon(Icons.login),
                    label: const Text('确认入会'),
                  ),
                ],
              );
            },
          ),
        ) ??
        false;
    final meetingName = controller.text.trim();
    final meetingPassword = passwordController.text.trim();
    controller.dispose();
    passwordController.dispose();
    if (!confirmed) return;
    if (meetingName.isEmpty) {
      _setStatus('显示名不能为空');
      return;
    }

    if (!mounted) return;
    setState(() {
      _meetingDisplayName = meetingName;
      _meetingPassword = meetingPassword;
      _micEnabled = micEnabled;
      _cameraEnabled = cameraEnabled;
    });
    await _joinRoom();
  }

  void _toggleSpotlight(String identity) =>
      _focusParticipantTile(identity, allowToggle: true);

  Future<void> _toggleTileFullscreen(String identity) async {
    try {
      final fullscreenActive = html.document.fullscreenElement != null;
      final isSameTile = fullscreenActive && _fullscreenIdentity == identity;
      if (isSameTile) {
        _resetTileZoom(identity, rebuild: false);
        html.document.exitFullscreen();
        return;
      }
      final previousFullscreenIdentity = _fullscreenIdentity;
      if (previousFullscreenIdentity != null &&
          previousFullscreenIdentity != identity) {
        _resetTileZoom(previousFullscreenIdentity, rebuild: false);
      }
      _resetTileZoom(identity, rebuild: false);
      if (mounted) {
        setState(() {
          _fullscreenIdentity = identity;
        });
      }
      if (!fullscreenActive) {
        await html.document.documentElement?.requestFullscreen();
        if (mounted && _fullscreenIdentity == identity) {
          setState(() {});
        }
      }
    } catch (e) {
      _setStatus('全屏切换失败：${_friendlyError(e)}');
    }
  }

  bool _shouldRunRealtimeBotAudioIngress() {
    if (_isShareEntry || !_hasPrivateMeetingApiScope) return false;
    if (!_connected || !_isModerator) return false;
    if (!_realtimeBotEnabled || !_realtimeBotAutoListen) return false;
    if (_room == null) return false;
    return true;
  }

  String _realtimeBotIngressBlocker() {
    if (_isShareEntry || !_hasPrivateMeetingApiScope) return 'private_api';
    if (!_connected) return 'not_connected';
    if (!_isModerator) return 'not_moderator';
    if (!_realtimeBotEnabled) return 'bot_disabled';
    if (!_realtimeBotAutoListen) return 'auto_listen_off';
    if (_room == null) return 'room_unavailable';
    return 'none';
  }

  void _syncRealtimeBotAudioIngress() {
    final shouldRun = _shouldRunRealtimeBotAudioIngress();
    _updateRealtimeBotDebug(
      event: shouldRun ? 'sync_run' : 'sync_stop',
      forceRebuild: true,
    );
    if (shouldRun) {
      unawaited(_startRealtimeBotAudioIngress());
    } else {
      unawaited(_stopRealtimeBotAudioIngress());
    }
  }

  void _startRealtimeBotCaptureKeepalive() {
    _realtimeBotCaptureKeepaliveTimer?.cancel();
    _realtimeBotCaptureKeepaliveTimer = Timer.periodic(
      const Duration(milliseconds: _realtimeBotAudioKeepaliveMs),
      (_) {
        _maintainRealtimeBotAudioIngress();
      },
    );
  }

  void _stopRealtimeBotCaptureKeepalive() {
    _realtimeBotCaptureKeepaliveTimer?.cancel();
    _realtimeBotCaptureKeepaliveTimer = null;
  }

  void _maintainRealtimeBotAudioIngress() {
    final hasCapture = _realtimeBotFrameCapture != null;
    _updateRealtimeBotDebug(
      audioContextState: hasCapture ? 'worklet' : 'idle',
      sourceCount: hasCapture ? 1 : 0,
    );
    if (_realtimeBotFallbackMicStream == null) {
      unawaited(_ensureRealtimeBotFallbackMicStream());
    }
    if (_realtimeBotListening && hasCapture) {
      final now = DateTime.now();
      final boundAt = _realtimeBotCaptureBoundAt;
      final lastProcessAt = _realtimeBotDebugLastProcessAt;
      if (shouldRestartRealtimeBotCapture(
        now: now,
        boundAt: boundAt,
        lastProcessAt: lastProcessAt,
      )) {
        _updateRealtimeBotDebug(
          event: 'capture_stalled',
          error: lastProcessAt == null
              ? 'audio renderer has no frames for >8s'
              : 'audio renderer stopped processing for >8s',
          forceRebuild: true,
        );
        unawaited(_bindRealtimeBotFrameCapture(force: true));
        return;
      }
    }
    if (_realtimeBotListening && !hasCapture) {
      unawaited(_bindRealtimeBotFrameCapture(force: true));
    }
  }

  Future<void> _forceRestartRealtimeBotAudioIngress() async {
    await _stopRealtimeBotAudioIngress();
    await _startRealtimeBotAudioIngress();
    _setStatus('已手动重启AI收音链路');
  }

  Future<void> _enableRealtimeBotFallbackMicFromGesture() async {
    await _ensureRealtimeBotFallbackMicStream();
    _refreshRealtimeBotAudioIngressSources();
    _setStatus('已尝试启用浏览器麦克风采集');
  }

  dynamic _pickRealtimeBotParticipantAudioTrack(
    dynamic participant, {
    bool preferMicrophoneSource = true,
  }) {
    if (participant == null) return null;
    try {
      final identity = (participant.identity ?? '').toString().trim();
      if (identity.isNotEmpty && identity == _realtimeBotVirtualIdentity()) {
        return null;
      }
    } catch (_) {}
    if (preferMicrophoneSource) {
      try {
        final micPub =
            participant.getTrackPublicationBySource(lk.TrackSource.microphone);
        if (micPub != null &&
            !_boolFromJson(micPub.muted, false) &&
            micPub.track != null) {
          return micPub.track;
        }
      } catch (_) {}
    }
    try {
      for (final dynamic pub in participant.audioTrackPublications) {
        if (_boolFromJson(pub.muted, false)) continue;
        final dynamic track = pub.track;
        if (track != null) return track;
      }
    } catch (_) {}
    return null;
  }

  dynamic _resolveRealtimeBotCaptureTrack() {
    final room = _room;
    if (room == null) return null;
    final local = room.localParticipant;
    if (local != null) {
      try {
        final localPrimaryTrack = _pickRealtimeBotParticipantAudioTrack(
          local,
          preferMicrophoneSource: true,
        );
        if (localPrimaryTrack != null) {
          return localPrimaryTrack;
        }
      } catch (_) {}
    }

    for (final participant in room.remoteParticipants.values) {
      final isSpeaking = _boolFromJson(participant.isSpeaking, false);
      if (!isSpeaking) continue;
      final track = _pickRealtimeBotParticipantAudioTrack(
        participant,
        preferMicrophoneSource: true,
      );
      if (track != null) return track;
    }
    for (final participant in room.remoteParticipants.values) {
      final track = _pickRealtimeBotParticipantAudioTrack(
        participant,
        preferMicrophoneSource: true,
      );
      if (track != null) return track;
    }
    if (local != null) {
      final fallbackTrack = _pickRealtimeBotParticipantAudioTrack(
        local,
        preferMicrophoneSource: false,
      );
      if (fallbackTrack != null) return fallbackTrack;
    }
    return null;
  }

  String _realtimeBotInputTrackDiagnostics() {
    final room = _room;
    if (room == null) return 'room=null';
    final local = room.localParticipant;
    if (local == null) return 'local=null';
    final localPubs = local.audioTrackPublications;
    var localMuted = 0;
    var localWithTrack = 0;
    for (final pub in localPubs) {
      if (_boolFromJson(pub.muted, false)) localMuted += 1;
      if (pub.track != null) localWithTrack += 1;
    }
    final micEnabled = local.isMicrophoneEnabled();
    var remoteMembers = 0;
    var remotePubs = 0;
    var remoteMuted = 0;
    var remoteWithTrack = 0;
    var remoteSpeaking = 0;
    for (final participant in room.remoteParticipants.values) {
      final identity = (participant.identity).toString().trim();
      if (identity == _realtimeBotVirtualIdentity()) continue;
      remoteMembers += 1;
      if (_boolFromJson(participant.isSpeaking, false)) {
        remoteSpeaking += 1;
      }
      for (final pub in participant.audioTrackPublications) {
        remotePubs += 1;
        if (_boolFromJson(pub.muted, false)) remoteMuted += 1;
        if (pub.track != null) remoteWithTrack += 1;
      }
    }
    return 'local_pubs=${localPubs.length}, local_muted=$localMuted, local_with_track=$localWithTrack, '
        'mic_enabled=$micEnabled, remote_members=$remoteMembers, remote_pubs=$remotePubs, '
        'remote_muted=$remoteMuted, remote_with_track=$remoteWithTrack, remote_speaking=$remoteSpeaking';
  }

  String _realtimeBotTrackIdentifier(dynamic track) {
    if (track == null) return '';
    try {
      final value = (track.mediaStreamTrack.id ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    } catch (_) {}
    try {
      final value = (track.sid ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    } catch (_) {}
    return '';
  }

  Future<void> _stopRealtimeBotFrameCapture() async {
    final capture = _realtimeBotFrameCapture;
    _realtimeBotFrameCapture = null;
    if (capture != null) {
      try {
        await capture();
      } catch (_) {}
    }
    _realtimeBotCaptureTrackId = '';
    _realtimeBotCaptureBoundAt = null;
  }

  Future<void> _bindRealtimeBotFrameCapture({bool force = false}) async {
    final track = _resolveRealtimeBotCaptureTrack();
    if (track == null) {
      final detail = _realtimeBotInputTrackDiagnostics();
      await _stopRealtimeBotFrameCapture();
      _updateRealtimeBotDebug(
        event: 'no_input_track',
        sourceCount: 0,
        error: 'no livekit local audio track ($detail)',
        forceRebuild: true,
      );
      return;
    }
    final trackId = _realtimeBotTrackIdentifier(track);
    if (!force &&
        _realtimeBotFrameCapture != null &&
        trackId.isNotEmpty &&
        trackId == _realtimeBotCaptureTrackId) {
      _updateRealtimeBotDebug(sourceCount: 1);
      return;
    }
    await _stopRealtimeBotFrameCapture();
    try {
      _realtimeBotFrameCapture = track.addAudioRenderer(
        onFrame: _handleRealtimeBotAudioFrame,
        options: const lk.AudioRendererOptions(
          sampleRate: _realtimeBotAudioTargetSampleRate,
          channels: 1,
          format: lk.AudioFormat.Int16,
        ),
      );
    } catch (e) {
      _updateRealtimeBotDebug(
        event: 'capture_bind_failed',
        error: _friendlyError(e),
        sourceCount: 0,
        forceRebuild: true,
      );
      return;
    }
    _realtimeBotCaptureTrackId = trackId;
    _realtimeBotCaptureBoundAt = DateTime.now();
    _updateRealtimeBotDebug(
      event: 'capture_bound',
      clearError: true,
      sourceCount: 1,
      forceRebuild: true,
    );
  }

  Future<void> _startRealtimeBotAudioIngress() async {
    if (_realtimeBotListening || _realtimeBotCaptureStarting) {
      await _bindRealtimeBotFrameCapture(force: true);
      _updateRealtimeBotDebug(event: 'start_skipped', forceRebuild: true);
      return;
    }
    _realtimeBotCaptureStarting = true;
    _updateRealtimeBotDebug(event: 'starting', forceRebuild: true);
    try {
      _startRealtimeBotCaptureKeepalive();
      await _ensureRealtimeBotIngressSocketReady();
      await _ensureRealtimeBotFallbackMicStream();
      await _bindRealtimeBotFrameCapture(force: true);
      if (mounted) {
        setState(() {
          _realtimeBotListening = true;
        });
      } else {
        _realtimeBotListening = true;
      }
      if (_realtimeBotFrameCapture == null) {
        _updateRealtimeBotDebug(
          event: 'listening_wait_track',
          audioContextState: 'idle',
          sourceCount: 0,
          fallbackMicOpen: _realtimeBotFallbackMicStream != null,
          forceRebuild: true,
        );
        return;
      }
      _updateRealtimeBotDebug(
        event: 'listening',
        clearError: true,
        audioContextState: 'worklet',
        sourceCount: _realtimeBotFrameCapture == null ? 0 : 1,
        fallbackMicOpen: _realtimeBotFallbackMicStream != null,
        forceRebuild: true,
      );
    } catch (e) {
      _stopRealtimeBotCaptureKeepalive();
      _updateRealtimeBotDebug(
        event: 'start_failed',
        error: _friendlyError(e),
        forceRebuild: true,
      );
      // Keep silent fallback: AI chat mode can still work without automatic speech ingress.
    } finally {
      _realtimeBotCaptureStarting = false;
      _updateRealtimeBotDebug(forceRebuild: true);
    }
  }

  Future<void> _ensureRealtimeBotFallbackMicStream() async {
    if (_realtimeBotFallbackMicStream != null) {
      _updateRealtimeBotDebug(fallbackMicOpen: true);
      return;
    }
    final mediaDevices = html.window.navigator.mediaDevices;
    if (mediaDevices == null) {
      _updateRealtimeBotDebug(
        event: 'fallback_mic_unavailable',
        error: 'navigator.mediaDevices unavailable',
      );
      return;
    }
    try {
      final dynamic stream = await mediaDevices.getUserMedia(<String, dynamic>{
        'audio': <String, dynamic>{
          'echoCancellation': _echoCancellation,
          'noiseSuppression': _noiseSuppression,
          'autoGainControl': _autoGainControl,
        },
        'video': false,
      });
      if (stream != null) {
        _realtimeBotFallbackMicStream = stream;
        _updateRealtimeBotDebug(
          event: 'fallback_mic_ready',
          clearError: true,
          fallbackMicOpen: true,
          forceRebuild: true,
        );
      }
    } catch (e) {
      try {
        final dynamic simpleStream = await mediaDevices.getUserMedia(
          <String, dynamic>{'audio': true, 'video': false},
        );
        if (simpleStream != null) {
          _realtimeBotFallbackMicStream = simpleStream;
          _updateRealtimeBotDebug(
            event: 'fallback_mic_ready',
            clearError: true,
            fallbackMicOpen: true,
            forceRebuild: true,
          );
          return;
        }
      } catch (_) {}
      _updateRealtimeBotDebug(
        event: 'fallback_mic_failed',
        error: _friendlyError(e),
        fallbackMicOpen: false,
      );
      // Keep running with room-track-only capture when fallback mic cannot be opened.
    }
  }

  dynamic _createRealtimeBotMediaStreamSource(
      dynamic audioContext, dynamic stream) {
    final candidates = <dynamic>[stream];
    try {
      final nested = stream == null ? null : stream.jsStream;
      if (nested != null) {
        candidates.add(nested);
      }
    } catch (_) {}
    if (stream is html.MediaStream) {
      try {
        candidates.add(js.JsObject.fromBrowserObject(stream));
      } catch (_) {}
    }
    for (final candidate in candidates) {
      if (candidate == null) continue;
      try {
        return audioContext.createMediaStreamSource(candidate);
      } catch (_) {}
      try {
        return audioContext
            .callMethod('createMediaStreamSource', <dynamic>[candidate]);
      } catch (_) {}
    }
    throw StateError('createMediaStreamSource failed for compatible stream');
  }

  void _connectRealtimeBotAudioNodes(dynamic sourceNode, dynamic destination) {
    try {
      sourceNode.connectNode(destination);
      return;
    } catch (_) {}
    try {
      sourceNode.connect(destination);
      return;
    } catch (_) {}
    sourceNode.callMethod('connect', <dynamic>[destination]);
  }

  void _disconnectRealtimeBotAudioNode(dynamic node) {
    try {
      node.disconnectNode();
      return;
    } catch (_) {}
    try {
      node.disconnect();
      return;
    } catch (_) {}
    node.callMethod('disconnect', const <dynamic>[]);
  }

  void _resumeRealtimeBotAudioContext(dynamic audioContext) {
    try {
      audioContext.resume();
      return;
    } catch (_) {}
    try {
      audioContext.callMethod('resume', const <dynamic>[]);
    } catch (_) {}
  }

  String _realtimeBotAudioContextState(dynamic audioContext) {
    try {
      final value = (audioContext.state ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    } catch (_) {}
    try {
      final value = (audioContext['state'] ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    } catch (_) {}
    return 'unknown';
  }

  int _realtimeBotAudioContextSampleRate() {
    final audioContext = _realtimeBotAudioContext;
    if (audioContext == null) return _realtimeBotAudioTargetSampleRate;
    try {
      return _intFromJson(
        audioContext.sampleRate,
        _realtimeBotAudioTargetSampleRate,
      );
    } catch (_) {}
    try {
      return _intFromJson(
        audioContext['sampleRate'],
        _realtimeBotAudioTargetSampleRate,
      );
    } catch (_) {}
    return _realtimeBotAudioTargetSampleRate;
  }

  List<dynamic> _collectRealtimeBotInputStreams() {
    final streams = <dynamic>[];
    void addIfUnique(dynamic stream) {
      if (stream == null) return;
      for (final existing in streams) {
        if (identical(existing, stream)) {
          return;
        }
      }
      streams.add(stream);
    }

    final fallback = _realtimeBotFallbackMicStream;
    if (fallback != null) {
      addIfUnique(fallback);
    }
    return streams;
  }

  void _disconnectRealtimeBotInputNodes() {
    for (final node in _realtimeBotCaptureInputNodes) {
      try {
        _disconnectRealtimeBotAudioNode(node);
      } catch (_) {}
    }
    _realtimeBotCaptureInputNodes.clear();
  }

  void _refreshRealtimeBotAudioIngressSources() {
    unawaited(_bindRealtimeBotFrameCapture(force: true));
  }

  bool _isRealtimeBotIngressSocketOpen() {
    final socket = _realtimeBotIngressSocket;
    if (socket == null) return false;
    return socket.readyState == html.WebSocket.OPEN;
  }

  void _clearRealtimeBotIngressResponseTimeout() {
    _realtimeBotIngressResponseTimeoutTimer?.cancel();
    _realtimeBotIngressResponseTimeoutTimer = null;
    _realtimeBotCurrentUploadStartedAt = null;
  }

  void _startRealtimeBotIngressResponseTimeout() {
    _realtimeBotIngressResponseTimeoutTimer?.cancel();
    _realtimeBotIngressResponseTimeoutTimer = Timer(
      const Duration(milliseconds: _realtimeBotIngressResponseTimeoutMs),
      () {
        if (!_realtimeBotAudioUploading) return;
        _realtimeBotAudioUploading = false;
        final startedAt = _realtimeBotCurrentUploadStartedAt;
        final latency = startedAt == null
            ? null
            : DateTime.now().difference(startedAt).inMilliseconds;
        _clearRealtimeBotIngressResponseTimeout();
        _updateRealtimeBotDebug(
          event: 'upload_timeout',
          error: 'ai ingress websocket response timeout',
          lastUploadAt: DateTime.now(),
          lastUploadLatencyMs: latency,
          forceRebuild: true,
        );
        _setStatus('AI audio ingress timeout');
      },
    );
  }

  Future<void> _closeRealtimeBotIngressSocket({
    bool updateDebug = true,
  }) async {
    _clearRealtimeBotIngressResponseTimeout();
    _realtimeBotIngressSocketConnecting = false;
    _realtimeBotSpeechStreamOpen = false;
    final socket = _realtimeBotIngressSocket;
    _realtimeBotIngressSocket = null;
    if (socket != null) {
      try {
        socket.close(1000, 'client-close');
      } catch (_) {}
    }
    if (updateDebug) {
      _updateRealtimeBotDebug(
        event: 'ws_closed',
        forceRebuild: true,
      );
    }
  }

  Future<void> _ensureRealtimeBotIngressSocketReady() async {
    if (_isRealtimeBotIngressSocketOpen()) return;
    if (_realtimeBotIngressSocketConnecting) {
      final waitUntil =
          DateTime.now().add(const Duration(milliseconds: 8000));
      while (_realtimeBotIngressSocketConnecting &&
          DateTime.now().isBefore(waitUntil)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_isRealtimeBotIngressSocketOpen()) return;
    }

    _realtimeBotIngressSocketConnecting = true;
    try {
      if (_requiresAuth || _hasPrivateMeetingApiScope) {
        await _ensureJwt();
      }
      final socket = html.WebSocket(_meetingAiRealtimeAudioWsUrl());
      _realtimeBotIngressSocket = socket;
      socket.onMessage.listen((event) {
        unawaited(_handleRealtimeBotIngressSocketMessage(event.data));
      });
      socket.onClose.listen((event) {
        if (!identical(socket, _realtimeBotIngressSocket)) return;
        final closeCode = event is html.CloseEvent ? event.code : 0;
        final closeReason = event is html.CloseEvent ? event.reason : '';
        _realtimeBotIngressSocket = null;
        _realtimeBotSpeechStreamOpen = false;
        if (_realtimeBotAudioUploading) {
          final startedAt = _realtimeBotCurrentUploadStartedAt;
          final latency = startedAt == null
              ? null
              : DateTime.now().difference(startedAt).inMilliseconds;
          _realtimeBotAudioUploading = false;
          _clearRealtimeBotIngressResponseTimeout();
          _updateRealtimeBotDebug(
            event: 'upload_failed',
            error: 'ai ingress websocket closed ($closeCode) $closeReason'
                .trim(),
            lastUploadAt: DateTime.now(),
            lastUploadLatencyMs: latency,
            forceRebuild: true,
          );
          _setStatus('AI audio ingress websocket disconnected');
        } else {
          _updateRealtimeBotDebug(
            event: 'ws_closed',
            error: 'ai ingress websocket closed ($closeCode) $closeReason'
                .trim(),
            forceRebuild: true,
          );
        }
      });
      final openFuture = socket.onOpen.first;
      final errorFuture = socket.onError.first.then<void>((_) {
        throw StateError('ai ingress websocket open failed');
      });
      await Future.any<void>(<Future<void>>[
        openFuture,
        errorFuture,
      ]).timeout(const Duration(milliseconds: 8000));
      _updateRealtimeBotDebug(
        event: 'ws_open',
        clearError: true,
        forceRebuild: true,
      );
    } finally {
      _realtimeBotIngressSocketConnecting = false;
    }
  }

  bool _sendRealtimeBotIngressPayload(Map<String, dynamic> payload) {
    final socket = _realtimeBotIngressSocket;
    if (socket == null || socket.readyState != html.WebSocket.OPEN) {
      unawaited(_ensureRealtimeBotIngressSocketReady());
      return false;
    }
    try {
      socket.send(jsonEncode(payload));
      return true;
    } catch (_) {
      unawaited(_ensureRealtimeBotIngressSocketReady());
      return false;
    }
  }

  void _flushRealtimeBotStreamAudioChunks({bool force = false}) {
    flushRealtimeBotStreamChunks(
      _realtimeBotCaptureBytes,
      chunkBytes: _realtimeBotIngressStreamChunkBytes,
      force: force,
      sendChunk: (chunk) {
        final ok = _sendRealtimeBotIngressPayload(
        <String, dynamic>{
          'type': 'audio_chunk',
          'audio_base64': base64Encode(chunk),
          'sample_rate': _realtimeBotCaptureSampleRate,
          'channels': 1,
        },
      );
        return ok;
      },
    );
  }

  void _startRealtimeBotSpeechStream(DateTime now) {
    _realtimeBotSpeechStartedAt = now;
    _realtimeBotLastVoiceAt = now;
    _realtimeBotCaptureBytes.clear();
    _realtimeBotSpeechStreamOpen = _sendRealtimeBotIngressPayload(
      const <String, dynamic>{'type': 'speech_start'},
    );
    _updateRealtimeBotDebug(
      event: _realtimeBotSpeechStreamOpen
          ? 'speech_start'
          : 'speech_start_pending_ws',
      bufferedBytes: _realtimeBotCaptureBytes.length,
    );
  }

  void _endRealtimeBotSpeechStream({
    required DateTime now,
    bool force = false,
  }) {
    final wasActive =
        _realtimeBotSpeechStartedAt != null || _realtimeBotSpeechStreamOpen;
    if (!wasActive) return;
    _flushRealtimeBotStreamAudioChunks(force: true);
    if (_realtimeBotSpeechStreamOpen) {
      _sendRealtimeBotIngressPayload(const <String, dynamic>{'type': 'speech_end'});
    }
    _realtimeBotCaptureBytes.clear();
    _realtimeBotPrerollBytes.clear();
    _realtimeBotSpeechStartedAt = null;
    _realtimeBotLastVoiceAt = null;
    _realtimeBotSpeechStreamOpen = false;
    _updateRealtimeBotDebug(
      event: force ? 'speech_end_forced' : 'speech_end',
      bufferedBytes: 0,
      voiceActive: false,
    );
  }

  Future<void> _handleRealtimeBotIngressSocketMessage(dynamic rawData) async {
    final message = parseRealtimeBotIngressMessage(rawData);
    if (message == null) return;

    switch (message.kind) {
      case RealtimeBotIngressMessageKind.ready:
        _updateRealtimeBotDebug(
          event: 'ws_ready',
          clearError: true,
          forceRebuild: true,
        );
        return;
      case RealtimeBotIngressMessageKind.ack:
        _updateRealtimeBotDebug(
          event: 'ws_ack',
          clearError: true,
        );
        return;
      case RealtimeBotIngressMessageKind.asrInterim:
        _updateRealtimeBotDebug(event: 'asr_interim');
        return;
      case RealtimeBotIngressMessageKind.asrFinal:
        if (message.previewText.isNotEmpty) {
          _updateRealtimeBotDebug(preview: message.previewText);
        }
        _updateRealtimeBotDebug(event: 'asr_final');
        return;
      case RealtimeBotIngressMessageKind.replyDelta:
        _updateRealtimeBotDebug(event: 'reply_delta');
        return;
      case RealtimeBotIngressMessageKind.noContent:
        _realtimeBotAudioUploading = false;
        _clearRealtimeBotIngressResponseTimeout();
        _setStatus('未识别到完整语音，请连贯说完再停顿');
        _updateRealtimeBotDebug(
          event: 'no_content',
          error: '',
          voiceActive: false,
          bufferedBytes: 0,
        );
        return;
      case RealtimeBotIngressMessageKind.error:
        final startedAt = _realtimeBotCurrentUploadStartedAt;
        final latency = startedAt == null
            ? null
            : DateTime.now().difference(startedAt).inMilliseconds;
        _realtimeBotAudioUploading = false;
        _clearRealtimeBotIngressResponseTimeout();
        _updateRealtimeBotDebug(
          event: 'upload_failed',
          error: message.detail,
          lastUploadAt: DateTime.now(),
          lastUploadLatencyMs: latency,
          forceRebuild: true,
        );
        _setStatus('AI audio ingress failed: ${message.detail}');
        return;
      case RealtimeBotIngressMessageKind.result:
        final startedAt = _realtimeBotCurrentUploadStartedAt;
        final latency = startedAt == null
            ? null
            : DateTime.now().difference(startedAt).inMilliseconds;
        _realtimeBotAudioUploading = false;
        _clearRealtimeBotIngressResponseTimeout();
        if (message.recognizedText.isNotEmpty) {
          _updateRealtimeBotDebug(preview: message.recognizedText);
        }
        if (message.previewText.isNotEmpty) {
          _setStatus('AI reply: ${message.previewText}');
          _updateRealtimeBotDebug(preview: message.previewText);
        }
        final rawMessage = message.message;
        if (rawMessage != null) {
          final botMessage = ChatMessage.fromJson(rawMessage);
          if (botMessage.audioBase64.trim().isNotEmpty) {
            await _playRealtimeBotAudio(botMessage);
          }
        }
        _updateRealtimeBotDebug(
          event: 'upload_ok',
          clearError: true,
          lastUploadAt: DateTime.now(),
          lastUploadLatencyMs: latency,
          bumpUploadCount: true,
          forceRebuild: true,
        );
        await _loadMessages();
        return;
    }
  }

  Future<void> _stopRealtimeBotAudioIngress() async {
    _stopRealtimeBotCaptureKeepalive();
    if (!_realtimeBotListening &&
        _realtimeBotFrameCapture == null &&
        _realtimeBotCaptureAudioProcessHandler == null &&
        _realtimeBotAudioContext == null) {
      _realtimeBotCaptureBytes.clear();
      _realtimeBotPrerollBytes.clear();
      _realtimeBotSpeechStartedAt = null;
      _realtimeBotLastVoiceAt = null;
      _realtimeBotCaptureStarting = false;
      _updateRealtimeBotDebug(
        event: 'stopped',
        voiceActive: false,
        audioContextState: 'closed',
        sourceCount: 0,
        bufferedBytes: 0,
        forceRebuild: true,
      );
      return;
    }
    try {
      _endRealtimeBotSpeechStream(now: DateTime.now(), force: true);
    } catch (_) {}
    try {
      await _stopRealtimeBotFrameCapture();
    } catch (_) {}
    try {
      if (_realtimeBotCaptureProcessorNode != null) {
        try {
          _realtimeBotCaptureProcessorNode!.onaudioprocess = null;
        } catch (_) {
          _realtimeBotCaptureProcessorNode!['onaudioprocess'] = null;
        }
      }
    } catch (_) {}
    _realtimeBotCaptureAudioProcessHandler = null;
    try {
      _disconnectRealtimeBotInputNodes();
    } catch (_) {}
    try {
      if (_realtimeBotCaptureProcessorNode != null) {
        _disconnectRealtimeBotAudioNode(_realtimeBotCaptureProcessorNode!);
      }
    } catch (_) {}
    _realtimeBotCaptureProcessorNode = null;
    final fallbackStream = _realtimeBotFallbackMicStream;
    if (fallbackStream != null) {
      try {
        if (fallbackStream is html.MediaStream) {
          for (final track in fallbackStream.getTracks()) {
            try {
              track.stop();
            } catch (_) {}
          }
        } else {
          final dynamic tracks = fallbackStream.callMethod(
            'getTracks',
            const <dynamic>[],
          );
          if (tracks is List) {
            for (final track in tracks) {
              try {
                track.callMethod('stop', const <dynamic>[]);
              } catch (_) {}
            }
          } else if (tracks != null) {
            final int length = _intFromJson(tracks['length'], 0);
            for (var idx = 0; idx < length; idx++) {
              final dynamic track = tracks[idx];
              try {
                track.callMethod('stop', const <dynamic>[]);
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
    }
    _realtimeBotFallbackMicStream = null;
    try {
      if (_realtimeBotAudioContext != null) {
        try {
          _realtimeBotAudioContext!.close();
        } catch (_) {
          _realtimeBotAudioContext!.callMethod('close', const <dynamic>[]);
        }
      }
    } catch (_) {}
    _realtimeBotAudioContext = null;
    await _closeRealtimeBotIngressSocket(updateDebug: false);
    _realtimeBotCaptureBytes.clear();
    _realtimeBotPrerollBytes.clear();
    _realtimeBotSpeechStartedAt = null;
    _realtimeBotLastVoiceAt = null;
    _realtimeBotSpeechStreamOpen = false;
    _realtimeBotCaptureStarting = false;
    if (mounted) {
      setState(() {
        _realtimeBotListening = false;
      });
    } else {
      _realtimeBotListening = false;
    }
    _updateRealtimeBotDebug(
      event: 'stopped',
      voiceActive: false,
      audioContextState: 'closed',
      sourceCount: 0,
      bufferedBytes: 0,
      fallbackMicOpen: false,
      forceRebuild: true,
    );
  }

  void _handleRealtimeBotAudioFrame(lk.AudioFrame frame) {
    if (!_shouldRunRealtimeBotAudioIngress()) return;
    if (_realtimeBotPlaybackActive) return;
    if (frame.data.isEmpty) return;

    Uint8List pcmBytes = frame.data;
    double rms = 0.0;
    if (frame.format == lk.AudioFormat.Int16) {
      rms = _pcm16RmsLevel(pcmBytes);
    } else {
      if (frame.data.length < 4) return;
      final usableBytes = frame.data.length - (frame.data.length % 4);
      if (usableBytes <= 0) return;
      final floats = Float32List.view(
        frame.data.buffer,
        frame.data.offsetInBytes,
        usableBytes ~/ 4,
      );
      rms = _rmsLevel(floats);
      pcmBytes = _float32ToPcm16Bytes(floats);
    }

    final now = DateTime.now();
    final safeRms = rms.isFinite ? rms : 0.0;
    final peak = _pcm16PeakLevel(pcmBytes);
    final hasVoice = safeRms >= _realtimeBotVadThreshold ||
        peak >= _realtimeBotVadPeakThreshold;
    final startVoice = safeRms >=
            (_realtimeBotVadThreshold * _realtimeBotVadStartRmsRatio) ||
        peak >= (_realtimeBotVadPeakThreshold * _realtimeBotVadStartPeakRatio);
    final holdVoice = hasVoice ||
        safeRms >= (_realtimeBotVadThreshold * _realtimeBotVadHoldRmsRatio) ||
        peak >= (_realtimeBotVadPeakThreshold * _realtimeBotVadHoldPeakRatio);
    _realtimeBotCaptureSampleRate = _realtimeBotAudioTargetSampleRate;
    _ingestRealtimeBotPcmFrame(
      now: now,
      pcmBytes: pcmBytes,
      safeRms: safeRms,
      hasVoice: holdVoice,
      startVoice: startVoice,
    );
  }

  void _handleRealtimeBotAudioProcess(dynamic event) {
    if (!_shouldRunRealtimeBotAudioIngress()) return;
    if (_realtimeBotPlaybackActive) return;
    final dynamic inputBuffer = event['inputBuffer'];
    if (inputBuffer == null) return;
    final inputChannels = _intFromJson(inputBuffer['numberOfChannels'], 0);
    if (inputChannels <= 0) return;
    final rawInput = _asFloat32List(
      inputBuffer.callMethod('getChannelData', <dynamic>[0]),
    );
    if (rawInput == null || rawInput.isEmpty) return;

    final dynamic outputBuffer = event['outputBuffer'];
    if (outputBuffer != null) {
      final outputChannels = _intFromJson(outputBuffer['numberOfChannels'], 0);
      if (outputChannels > 0) {
        final output = _asFloat32List(
          outputBuffer.callMethod('getChannelData', <dynamic>[0]),
        );
        if (output != null && output.isNotEmpty) {
          for (var i = 0; i < output.length; i++) {
            output[i] = 0.0;
          }
        }
      }
    }

    final sourceRate = _realtimeBotAudioContextSampleRate();
    final normalized = _downsampleFloat32(
      rawInput,
      sourceRate: sourceRate,
      targetRate: _realtimeBotAudioTargetSampleRate,
    );
    if (normalized.isEmpty) return;
    final normalizedPcmBytes = _float32ToPcm16Bytes(normalized);
    _realtimeBotCaptureSampleRate = _realtimeBotAudioTargetSampleRate;
    final rms = _rmsLevel(normalized);
    final now = DateTime.now();
    final safeRms = rms.isFinite ? rms : 0.0;
    final peak = _pcm16PeakLevel(normalizedPcmBytes);
    final hasVoice = safeRms >= _realtimeBotVadThreshold ||
        peak >= _realtimeBotVadPeakThreshold;
    final startVoice = safeRms >=
            (_realtimeBotVadThreshold * _realtimeBotVadStartRmsRatio) ||
        peak >= (_realtimeBotVadPeakThreshold * _realtimeBotVadStartPeakRatio);
    final holdVoice = hasVoice ||
        safeRms >= (_realtimeBotVadThreshold * _realtimeBotVadHoldRmsRatio) ||
        peak >= (_realtimeBotVadPeakThreshold * _realtimeBotVadHoldPeakRatio);
    _ingestRealtimeBotPcmFrame(
      now: now,
      pcmBytes: normalizedPcmBytes,
      safeRms: safeRms,
      hasVoice: holdVoice,
      startVoice: startVoice,
    );
  }

  void _ingestRealtimeBotPcmFrame({
    required DateTime now,
    required Uint8List pcmBytes,
    required double safeRms,
    required bool hasVoice,
    required bool startVoice,
  }) {
    _updateRealtimeBotDebug(
      bumpProcessCount: true,
      lastProcessAt: now,
      rms: safeRms,
    );
    if (_realtimeBotSpeechStartedAt == null) {
      _realtimeBotPrerollBytes.addAll(pcmBytes);
      if (_realtimeBotPrerollBytes.length > _realtimeBotIngressPrerollBytes) {
        _realtimeBotPrerollBytes.removeRange(
          0,
          _realtimeBotPrerollBytes.length - _realtimeBotIngressPrerollBytes,
        );
      }
    }
    var frameAlreadyInBuffer = false;
    if (startVoice && _realtimeBotSpeechStartedAt == null) {
      _startRealtimeBotSpeechStream(now);
      if (_realtimeBotPrerollBytes.isNotEmpty) {
        _realtimeBotCaptureBytes.addAll(_realtimeBotPrerollBytes);
        _realtimeBotPrerollBytes.clear();
        frameAlreadyInBuffer = true;
      }
    }
    if (_realtimeBotSpeechStartedAt == null) {
      _updateRealtimeBotDebug(
        voiceActive: false,
        rms: safeRms,
        bufferedBytes: 0,
      );
      return;
    }
    if (hasVoice) {
      _realtimeBotLastVoiceAt = now;
    }
    if (!frameAlreadyInBuffer) {
      _realtimeBotCaptureBytes.addAll(pcmBytes);
    }
    if (_realtimeBotCaptureBytes.length > _realtimeBotIngressStreamMaxBufferBytes) {
      _realtimeBotCaptureBytes.removeRange(
        0,
        _realtimeBotCaptureBytes.length - _realtimeBotIngressStreamMaxBufferBytes,
      );
    }
    _flushRealtimeBotStreamAudioChunks();

    final speechStartedAt = _realtimeBotSpeechStartedAt!;
    final elapsedMs = now.difference(speechStartedAt).inMilliseconds;
    final lastVoiceAt = _realtimeBotLastVoiceAt ?? speechStartedAt;
    final silenceMs = now.difference(lastVoiceAt).inMilliseconds;
    if (shouldEndRealtimeBotSpeechTurn(
      elapsedMs: elapsedMs,
      silenceMs: silenceMs,
      minSpeechMs: _realtimeBotAudioMinSpeechMs,
      silenceThresholdMs: _realtimeBotAudioSilenceMs,
      maxSpeechMs: _realtimeBotAudioMaxSpeechMs,
    )) {
      _realtimeBotAudioUploading = true;
      _realtimeBotCurrentUploadStartedAt = now;
      _startRealtimeBotIngressResponseTimeout();
      _endRealtimeBotSpeechStream(now: now);
      _updateRealtimeBotDebug(
        event: 'uploading',
        clearError: true,
        voiceActive: false,
        bufferedBytes: 0,
        lastUploadBytes: 0,
        forceRebuild: true,
      );
      return;
    }
    _updateRealtimeBotDebug(
      event: hasVoice ? 'streaming_voice' : 'streaming_silence',
      voiceActive: hasVoice,
      rms: safeRms,
      bufferedBytes: _realtimeBotCaptureBytes.length,
    );
  }

  Float32List? _asFloat32List(dynamic value) {
    if (value is Float32List) return value;
    if (value is List) {
      final list = <double>[];
      for (final item in value) {
        if (item is num) {
          list.add(item.toDouble());
        }
      }
      return Float32List.fromList(list);
    }
    return null;
  }

  Float32List _downsampleFloat32(
    Float32List input, {
    required int sourceRate,
    required int targetRate,
  }) {
    if (input.isEmpty) return Float32List(0);
    final srcRate =
        sourceRate <= 0 ? _realtimeBotAudioTargetSampleRate : sourceRate;
    final dstRate =
        targetRate <= 0 ? _realtimeBotAudioTargetSampleRate : targetRate;
    if (srcRate == dstRate) {
      return Float32List.fromList(input);
    }
    final ratio = srcRate / dstRate;
    final outputLength = (input.length / ratio).floor();
    if (outputLength <= 0) return Float32List(0);
    final output = Float32List(outputLength);
    var sourceOffset = 0.0;
    for (var i = 0; i < outputLength; i++) {
      final nextOffset = sourceOffset + ratio;
      final start = sourceOffset.floor();
      final end = math.min(nextOffset.floor(), input.length);
      if (end <= start) {
        output[i] = input[math.min(start, input.length - 1)];
      } else {
        double sum = 0.0;
        var count = 0;
        for (var j = start; j < end; j++) {
          sum += input[j];
          count += 1;
        }
        output[i] = count <= 0 ? 0.0 : sum / count;
      }
      sourceOffset = nextOffset;
    }
    return output;
  }

  Uint8List _float32ToPcm16Bytes(Float32List input) {
    final output = Uint8List(input.length * 2);
    final data = ByteData.view(output.buffer);
    for (var i = 0; i < input.length; i++) {
      final clamped = input[i].clamp(-1.0, 1.0);
      final sample = (clamped * 32767.0).round();
      data.setInt16(i * 2, sample, Endian.little);
    }
    return output;
  }

  double _rmsLevel(Float32List input) {
    if (input.isEmpty) return 0.0;
    double sum = 0.0;
    for (final sample in input) {
      sum += sample * sample;
    }
    return math.sqrt(sum / input.length);
  }

  double _pcm16RmsLevel(Uint8List input) {
    final sampleCount = input.length ~/ 2;
    if (sampleCount <= 0) return 0.0;
    final bytes = ByteData.sublistView(input);
    double sum = 0.0;
    for (var i = 0; i < sampleCount; i++) {
      final value = bytes.getInt16(i * 2, Endian.little) / 32768.0;
      sum += value * value;
    }
    return math.sqrt(sum / sampleCount);
  }

  double _pcm16PeakLevel(Uint8List input) {
    final sampleCount = input.length ~/ 2;
    if (sampleCount <= 0) return 0.0;
    final bytes = ByteData.sublistView(input);
    var peak = 0.0;
    for (var i = 0; i < sampleCount; i++) {
      final value = (bytes.getInt16(i * 2, Endian.little)).abs() / 32768.0;
      if (value > peak) {
        peak = value;
      }
    }
    return peak;
  }

  bool _looksLikeWav(Uint8List input) {
    if (input.length < 12) return false;
    return input[0] == 0x52 &&
        input[1] == 0x49 &&
        input[2] == 0x46 &&
        input[3] == 0x46 &&
        input[8] == 0x57 &&
        input[9] == 0x41 &&
        input[10] == 0x56 &&
        input[11] == 0x45;
  }

  Uint8List _pcm16ToWavBytes(
    Uint8List pcmBytes, {
    int sampleRate = 24000,
    int channels = 1,
  }) {
    final safeChannels = channels <= 0 ? 1 : channels;
    final safeSampleRate = sampleRate <= 0 ? 24000 : sampleRate;
    final dataLength = pcmBytes.length;
    final byteRate = safeSampleRate * safeChannels * 2;
    final blockAlign = safeChannels * 2;
    final header = ByteData(44);

    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        header.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    header.setUint32(4, 36 + dataLength, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, safeChannels, Endian.little);
    header.setUint32(24, safeSampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    header.setUint32(40, dataLength, Endian.little);

    final output = Uint8List(44 + dataLength);
    output.setRange(0, 44, header.buffer.asUint8List());
    output.setRange(44, 44 + dataLength, pcmBytes);
    return output;
  }

  Future<void> _openRenameMemberDialog(ParticipantRowData row) async {
    final userId = row.userId;
    final isGuest = userId == null;
    final controller = TextEditingController(text: row.displayName);
    final saved = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('成员改名'),
            content: TextField(
              controller: controller,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: '显示名',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保存'),
              ),
            ],
          ),
        ) ??
        false;
    if (!saved) {
      controller.dispose();
      return;
    }
    final next = controller.text.trim();
    controller.dispose();
    try {
      if (isGuest) {
        await _renameParticipantByIdentity(row.identity, next);
      } else {
        await _renameMember(userId, next);
      }
      _setStatus('成员显示名已更新');
    } catch (e) {
      _setStatus('成员改名失败：${_friendlyError(e)}');
    }
  }

  Future<void> _openModeratorControlDialog() async {
    if (!_canUseModeratorControls) return;
    if (mounted) {
      setState(() {
        _hasNewWaitingRoomNotice = false;
      });
    }
    var waitingRoomEnabled = _waitingRoomEnabled;
    var allowGuestLinkJoin = _allowGuestLinkJoin;
    var allowScreenShare = _allowScreenShare;
    var allowChat = _allowChat;
    var allowSelfUnmute = _allowSelfUnmute;
    var allowMemberVideo = _allowMemberVideo;
    var busy = false;
    var waitingEntries = <WaitingRoomEntry>[];
    String? errorMessage;

    try {
      waitingEntries = await _loadWaitingRoomEntries();
      if (mounted) {
        setState(() {
          _waitingRoomEntries = waitingEntries;
          _lastWaitingRoomCount = waitingEntries.length;
        });
      }
    } catch (e) {
      errorMessage = _friendlyError(e);
    }

    Future<void> refreshWaitingEntries(StateSetter setDialogState) async {
      try {
        final rows = await _loadWaitingRoomEntries();
        setDialogState(() {
          waitingEntries = rows;
          errorMessage = null;
        });
        if (mounted) {
          setState(() {
            _waitingRoomEntries = rows;
            _lastWaitingRoomCount = rows.length;
          });
        }
      } catch (e) {
        setDialogState(() {
          errorMessage = _friendlyError(e);
        });
      }
    }

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> updateControl(
            String key,
            bool value,
            void Function(bool value) assignLocal,
          ) async {
            if (busy) return;
            setDialogState(() {
              busy = true;
              assignLocal(value);
            });
            try {
              await _patchMeetingControls({key: value});
              setDialogState(() {
                waitingRoomEnabled = _waitingRoomEnabled;
                allowGuestLinkJoin = _allowGuestLinkJoin;
                allowScreenShare = _allowScreenShare;
                allowChat = _allowChat;
                allowSelfUnmute = _allowSelfUnmute;
                allowMemberVideo = _allowMemberVideo;
                busy = false;
                errorMessage = null;
              });
            } catch (e) {
              setDialogState(() {
                waitingRoomEnabled = _waitingRoomEnabled;
                allowGuestLinkJoin = _allowGuestLinkJoin;
                allowScreenShare = _allowScreenShare;
                allowChat = _allowChat;
                allowSelfUnmute = _allowSelfUnmute;
                allowMemberVideo = _allowMemberVideo;
                busy = false;
                errorMessage = _friendlyError(e);
              });
            }
          }

          Future<void> handleMuteAll() async {
            if (busy) return;
            setDialogState(() => busy = true);
            try {
              await _muteAllMembers();
              setDialogState(() {
                busy = false;
                errorMessage = null;
              });
            } catch (e) {
              setDialogState(() {
                busy = false;
                errorMessage = _friendlyError(e);
              });
            }
          }

          Future<void> handleReview(int userId, String status) async {
            if (busy) return;
            setDialogState(() => busy = true);
            try {
              await _reviewWaitingRoomEntry(userId, status);
              await refreshWaitingEntries(setDialogState);
              setDialogState(() => busy = false);
            } catch (e) {
              setDialogState(() {
                busy = false;
                errorMessage = _friendlyError(e);
              });
            }
          }

          return AlertDialog(
            title: const Text('会议管控'),
            content: SizedBox(
              width: 760,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile.adaptive(
                      value: waitingRoomEnabled,
                      onChanged: busy
                          ? null
                          : (v) => unawaited(updateControl(
                                'waiting_room_enabled',
                                v,
                                (value) => waitingRoomEnabled = value,
                              )),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('开启等候室'),
                    ),
                    SwitchListTile.adaptive(
                      value: allowGuestLinkJoin,
                      onChanged: busy
                          ? null
                          : (v) => unawaited(updateControl(
                                'allow_guest_link_join',
                                v,
                                (value) => allowGuestLinkJoin = value,
                              )),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('允许访客通过链接加入'),
                    ),
                    SwitchListTile.adaptive(
                      value: allowChat,
                      onChanged: busy
                          ? null
                          : (v) => unawaited(updateControl(
                                'allow_chat',
                                v,
                                (value) => allowChat = value,
                              )),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('允许聊天'),
                    ),
                    SwitchListTile.adaptive(
                      value: allowScreenShare,
                      onChanged: busy
                          ? null
                          : (v) => unawaited(updateControl(
                                'allow_screen_share',
                                v,
                                (value) => allowScreenShare = value,
                              )),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('允许屏幕共享'),
                    ),
                    SwitchListTile.adaptive(
                      value: allowSelfUnmute,
                      onChanged: busy
                          ? null
                          : (v) => unawaited(updateControl(
                                'allow_self_unmute',
                                v,
                                (value) => allowSelfUnmute = value,
                              )),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('允许成员自我解除静音'),
                    ),
                    SwitchListTile.adaptive(
                      value: allowMemberVideo,
                      onChanged: busy
                          ? null
                          : (v) => unawaited(updateControl(
                                'allow_member_video',
                                v,
                                (value) => allowMemberVideo = value,
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
                          onPressed:
                              busy ? null : () => unawaited(handleMuteAll()),
                          icon: const Icon(Icons.mic_off),
                          label: const Text('全员静音'),
                        ),
                        OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () => unawaited(
                                  refreshWaitingEntries(setDialogState)),
                          icon: const Icon(Icons.refresh),
                          label: const Text('刷新等候室'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      '等候室待审核',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    if (errorMessage != null && errorMessage!.trim().isNotEmpty)
                      Text(
                        errorMessage!,
                        style: TextStyle(
                          color: _palette.danger,
                          fontSize: 12.5,
                        ),
                      ),
                    if (waitingEntries.isEmpty)
                      Text(
                        '暂无待审核成员',
                        style: TextStyle(color: _palette.textMuted),
                      )
                    else
                      ...waitingEntries.map(
                        (entry) => Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            border: Border.all(color: _palette.panelBorder),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${entry.displayName} (${entry.username})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => unawaited(
                                        handleReview(entry.userId, 'rejected')),
                                child: const Text('拒绝'),
                              ),
                              FilledButton(
                                onPressed: busy
                                    ? null
                                    : () => unawaited(
                                        handleReview(entry.userId, 'approved')),
                                child: const Text('通过'),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openAiControlDialog() async {
    if (!_canUseModeratorControls) return;
    var enabled = _realtimeBotEnabled;
    var muted = _realtimeBotMuted;
    var debugPanelVisible = _realtimeBotDebugPanelVisible;
    var provider = _realtimeBotProvider.trim().toLowerCase();
    if (provider != 'volcengine') provider = 'openai';
    var apiKeySet = _realtimeBotApiKeySet;
    var volcAppKeySet = _realtimeBotVolcAppKeySet;
    var volcAccessKeySet = _realtimeBotVolcAccessKeySet;
    final baseUrlController = TextEditingController(text: _realtimeBotBaseUrl);
    final openaiModelController =
        TextEditingController(text: _realtimeBotOpenaiModel);
    final openaiVoiceController =
        TextEditingController(text: _realtimeBotOpenaiVoice);
    final volcModelController =
        TextEditingController(text: _realtimeBotVolcModel);
    final volcVoiceController =
        TextEditingController(text: _realtimeBotVolcVoice);
    final volcWsUrlController =
        TextEditingController(text: _realtimeBotVolcWsUrl);
    final volcAppIdController =
        TextEditingController(text: _realtimeBotVolcAppId);
    final volcResourceIdController =
        TextEditingController(text: _realtimeBotVolcResourceId);
    final volcUidController = TextEditingController(text: _realtimeBotVolcUid);
    final displayNameController =
        TextEditingController(text: _realtimeBotDisplayName);
    final apiKeyController = TextEditingController();
    final volcAppKeyController = TextEditingController();
    final volcAccessKeyController = TextEditingController();
    var busy = false;
    String? errorMessage;
    String? testMessage;

    Future<void> saveConfig(StateSetter setDialogState) async {
      if (busy) return;
      final baseUrl = baseUrlController.text.trim();
      final openaiModel = openaiModelController.text.trim();
      final openaiVoice = openaiVoiceController.text.trim();
      final volcModelRaw = volcModelController.text.trim();
      final volcModel = volcModelRaw.isEmpty ? '2.2.0.0' : volcModelRaw;
      final volcVoice = volcVoiceController.text.trim();
      final volcWsUrl = volcWsUrlController.text.trim();
      final volcAppId = volcAppIdController.text.trim();
      final volcResourceId = volcResourceIdController.text.trim();
      final volcUid = volcUidController.text.trim();
      final displayName = displayNameController.text.trim();
      final keyInput = apiKeyController.text.trim();
      final volcAppKeyInput = volcAppKeyController.text.trim();
      final volcAccessKeyInput = volcAccessKeyController.text.trim();
      final draft = MeetingRealtimeBotControlsDraft(
        provider: provider,
        enabled: enabled,
        muted: muted,
        displayName: displayName,
        baseUrl: baseUrl,
        openaiModel: openaiModel,
        openaiVoice: openaiVoice,
        volcModel: volcModel,
        volcVoice: volcVoice,
        volcWsUrl: volcWsUrl,
        volcAppId: volcAppId,
        volcResourceId: volcResourceId,
        volcUid: volcUid,
        apiKeyAlreadySet: apiKeySet,
        volcAccessKeyAlreadySet: volcAccessKeySet,
      );
      final validationError = draft.validateForSave(
        apiKey: keyInput,
        volcAccessKey: volcAccessKeyInput,
      );
      if (validationError != null) {
        setDialogState(() => errorMessage = validationError);
        return;
      }
      final payload = draft.buildSavePayload(
        apiKey: keyInput,
        volcAppKey: volcAppKeyInput,
        volcAccessKey: volcAccessKeyInput,
      );
      setDialogState(() {
        busy = true;
        errorMessage = null;
        testMessage = null;
      });
      try {
        await _patchMeetingAiControls(payload);
        setDialogState(() {
          enabled = _realtimeBotEnabled;
          muted = _realtimeBotMuted;
          provider = _realtimeBotProvider;
          apiKeySet = _realtimeBotApiKeySet;
          volcAppKeySet = _realtimeBotVolcAppKeySet;
          volcAccessKeySet = _realtimeBotVolcAccessKeySet;
          baseUrlController.text = _realtimeBotBaseUrl;
          openaiModelController.text = _realtimeBotOpenaiModel;
          openaiVoiceController.text = _realtimeBotOpenaiVoice;
          volcModelController.text = _realtimeBotVolcModel;
          volcVoiceController.text = _realtimeBotVolcVoice;
          volcWsUrlController.text = _realtimeBotVolcWsUrl;
          volcAppIdController.text = _realtimeBotVolcAppId;
          volcResourceIdController.text = _realtimeBotVolcResourceId;
          volcUidController.text = _realtimeBotVolcUid;
          displayNameController.text = _realtimeBotDisplayName;
          apiKeyController.clear();
          volcAppKeyController.clear();
          volcAccessKeyController.clear();
          busy = false;
          errorMessage = null;
          testMessage = '配置已保存';
        });
      } catch (e) {
        setDialogState(() {
          busy = false;
          errorMessage = _friendlyError(e);
        });
      }
    }

    Future<void> testConnectivity(StateSetter setDialogState) async {
      if (busy) return;
      final baseUrl = baseUrlController.text.trim();
      final openaiModel = openaiModelController.text.trim();
      final openaiVoice = openaiVoiceController.text.trim();
      final volcModelRaw = volcModelController.text.trim();
      final volcModel = volcModelRaw.isEmpty ? '2.2.0.0' : volcModelRaw;
      final volcVoice = volcVoiceController.text.trim();
      final volcWsUrl = volcWsUrlController.text.trim();
      final volcAppId = volcAppIdController.text.trim();
      final volcResourceId = volcResourceIdController.text.trim();
      final volcUid = volcUidController.text.trim();
      final keyInput = apiKeyController.text.trim();
      final volcAppKeyInput = volcAppKeyController.text.trim();
      final volcAccessKeyInput = volcAccessKeyController.text.trim();
      if (provider == 'volcengine') {
        if (volcWsUrl.isEmpty || volcAppId.isEmpty || volcResourceId.isEmpty) {
          setDialogState(
              () => errorMessage = '请先填写火山引擎 WebSocket / App ID / Resource ID');
          return;
        }
        if (!volcAccessKeySet && volcAccessKeyInput.isEmpty) {
          setDialogState(() => errorMessage = '连通性测试需要火山引擎 Access Key');
          return;
        }
      } else {
        if (baseUrl.isEmpty || openaiModel.isEmpty || openaiVoice.isEmpty) {
          setDialogState(
              () => errorMessage = '请先填写 OpenAI Base URL / Model / Voice');
          return;
        }
        if (!apiKeySet && keyInput.isEmpty) {
          setDialogState(() => errorMessage = '连通性测试需要 OpenAI API Key');
          return;
        }
      }
      final testModel = provider == 'volcengine' ? volcModel : openaiModel;
      final testVoice = provider == 'volcengine' ? volcVoice : openaiVoice;
      setDialogState(() {
        busy = true;
        errorMessage = null;
        testMessage = null;
      });
      try {
        final result = await _testMeetingAiConnectivity(
          provider: provider,
          baseUrl: baseUrl,
          model: testModel,
          voice: testVoice,
          apiKey: keyInput,
          volcWsUrl: volcWsUrl,
          volcAppId: volcAppId,
          volcAppKey: volcAppKeyInput,
          volcAccessKey: volcAccessKeyInput,
          volcResourceId: volcResourceId,
          volcUid: volcUid,
          prompt: '请回复：连通性测试成功',
        );
        final latency = _intFromJson(result['latency_ms'], 0);
        final preview = (result['preview_text'] ?? '').toString().trim();
        setDialogState(() {
          busy = false;
          testMessage = preview.isEmpty
              ? '连通性测试成功（${latency}ms）'
              : '连通性测试成功（${latency}ms）：$preview';
        });
      } catch (e) {
        setDialogState(() {
          busy = false;
          errorMessage = _friendlyError(e);
        });
      }
    }

    try {
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('AI管控'),
              content: SizedBox(
                width: 680,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile.adaptive(
                        value: enabled,
                        onChanged: busy
                            ? null
                            : (v) => setDialogState(() => enabled = v),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('启用实时语音成员'),
                      ),
                      SwitchListTile.adaptive(
                        value: muted,
                        onChanged: busy
                            ? null
                            : (v) => setDialogState(() => muted = v),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('静音实时语音成员'),
                      ),
                      if (_isSuperAdminUser)
                        SwitchListTile.adaptive(
                          value: debugPanelVisible,
                          onChanged: busy
                              ? null
                              : (v) {
                                  setDialogState(() => debugPanelVisible = v);
                                  if (_realtimeBotDebugPanelVisible == v ||
                                      !mounted) {
                                    return;
                                  }
                                  setState(() {
                                    _realtimeBotDebugPanelVisible = v;
                                  });
                                },
                          contentPadding: EdgeInsets.zero,
                          title: const Text('显示 AI Debug'),
                        ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: provider,
                        decoration: const InputDecoration(labelText: '模型厂商'),
                        items: const [
                          DropdownMenuItem(
                            value: 'openai',
                            child: Text('OpenAI'),
                          ),
                          DropdownMenuItem(
                            value: 'volcengine',
                            child: Text('火山引擎'),
                          ),
                        ],
                        onChanged: busy
                            ? null
                            : (v) => setDialogState(() {
                                  provider =
                                      (v ?? 'openai').trim().toLowerCase() ==
                                              'volcengine'
                                          ? 'volcengine'
                                          : 'openai';
                                  errorMessage = null;
                                  testMessage = null;
                                }),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: displayNameController,
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: '会议内显示名称',
                          hintText: '实时语音助手',
                        ),
                      ),
                      if (provider == 'volcengine') ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: volcModelController,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'Volcengine Model',
                            hintText: '2.2.0.0',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: volcVoiceController,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'Volcengine Voice',
                            hintText: '可选',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: volcWsUrlController,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'Volcengine WebSocket URL',
                            hintText:
                                'wss://openspeech.bytedance.com/api/v3/realtime/dialogue',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: volcAppIdController,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'Volcengine App ID',
                            hintText: '必填',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: volcResourceIdController,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'Volcengine Resource ID',
                            hintText: 'volc.speech.dialog',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: volcUidController,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'Volcengine UID（可选）',
                            hintText: '用于日志定位',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: volcAppKeyController,
                          enabled: !busy,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: volcAppKeySet
                                ? 'Volcengine App Key（留空沿用已保存）'
                                : 'Volcengine App Key',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: volcAccessKeyController,
                          enabled: !busy,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: volcAccessKeySet
                                ? 'Volcengine Access Key（留空沿用已保存）'
                                : 'Volcengine Access Key',
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: baseUrlController,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'OpenAI Base URL',
                            hintText: 'https://api.openai.com',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: openaiModelController,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'Model',
                            hintText: 'gpt-realtime',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: openaiVoiceController,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            labelText: 'Voice',
                            hintText: 'marin',
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: apiKeyController,
                          enabled: !busy,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: apiKeySet
                                ? 'OpenAI API Key（留空沿用已保存）'
                                : 'OpenAI API Key',
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: busy
                                ? null
                                : () => unawaited(saveConfig(setDialogState)),
                            icon: const Icon(Icons.save_outlined),
                            label: const Text('保存配置'),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () =>
                                    unawaited(testConnectivity(setDialogState)),
                            icon: const Icon(Icons.network_check_outlined),
                            label: const Text('测试连通性'),
                          ),
                        ],
                      ),
                      if ((testMessage ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          testMessage!,
                          style: TextStyle(
                            color: _palette.success,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                      if ((errorMessage ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          errorMessage!,
                          style: TextStyle(
                            color: _palette.danger,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      baseUrlController.dispose();
      openaiModelController.dispose();
      openaiVoiceController.dispose();
      volcModelController.dispose();
      volcVoiceController.dispose();
      volcWsUrlController.dispose();
      volcAppIdController.dispose();
      volcResourceIdController.dispose();
      volcUidController.dispose();
      displayNameController.dispose();
      apiKeyController.dispose();
      volcAppKeyController.dispose();
      volcAccessKeyController.dispose();
    }
  }

  void _appendEmoji(String emoji) {
    final value = _chatController.value;
    final text = value.text;
    var start = value.selection.start;
    var end = value.selection.end;
    if (start < 0 || end < 0) {
      start = text.length;
      end = text.length;
    }
    final nextText = text.replaceRange(start, end, emoji);
    final cursor = start + emoji.length;
    _chatController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: cursor),
      composing: TextRange.empty,
    );
  }

  PopupMenuEntry<String> _chatEmojiMenuSection(String title) {
    return PopupMenuItem<String>(
      enabled: false,
      height: 24,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
      child: Text(
        title,
        style: TextStyle(
          color: _palette.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  PopupMenuEntry<String> _chatEmojiMenuItem(String emoji) {
    final label = _quickEmojiLabels[emoji] ?? '表情';
    return PopupMenuItem<String>(
      value: emoji,
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _palette.primarySoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              emoji,
              style: const TextStyle(fontSize: 16),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: _palette.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<PopupMenuEntry<String>> _chatEmojiMenuItems() {
    final items = <PopupMenuEntry<String>>[
      _chatEmojiMenuSection('常用表情'),
    ];
    for (final emoji in _quickEmojis) {
      items.add(_chatEmojiMenuItem(emoji));
    }
    return items;
  }

  bool _isMyMessage(ChatMessage message) {
    final localUserId = _localUserId;
    if (localUserId == null) return false;
    return message.senderUserId == localUserId;
  }

  bool _canRecallMessage(ChatMessage message) {
    if (!_connected) return false;
    if (_isShareEntry && _localUserId == null) return false;
    if (_isModerator) return true;
    if (!_isMyMessage(message)) return false;
    final createdAt = message.createdAt;
    if (createdAt == null) return false;
    return DateTime.now().difference(createdAt) <= const Duration(minutes: 3);
  }

  String _displayNameForMessage(ChatMessage message) {
    if (message.senderUserId > 0) {
      final identity = _connectedIdentityForUserId(message.senderUserId);
      if (identity != null) {
        final runtimeName = _runtimeDisplayNameForIdentity(identity);
        if (runtimeName != null) {
          return runtimeName;
        }
      }
      final profile = _memberProfiles[message.senderUserId];
      final profileName = profile?.displayName.trim() ?? '';
      if (profileName.isNotEmpty) {
        return profileName;
      }
    }
    final senderDisplayName = message.senderDisplayName.trim();
    if (senderDisplayName.isNotEmpty) return senderDisplayName;
    final senderUsername = message.senderUsername.trim();
    if (senderUsername.isNotEmpty) return senderUsername;
    return '-';
  }

  String _messageTimeLabel(DateTime? createdAt) {
    if (createdAt == null) return '';
    final local = createdAt.toLocal();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final hhmm = '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
    final now = DateTime.now();
    if (_isSameLocalDate(now, local)) {
      return hhmm;
    }
    return '${twoDigits(local.month)}-${twoDigits(local.day)} $hhmm';
  }

  bool _isSameLocalDate(DateTime left, DateTime right) {
    return left.year == right.year &&
        left.month == right.month &&
        left.day == right.day;
  }

  String _initialForName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.substring(0, 1).toUpperCase();
  }

  Future<void> _confirmRecallMessage(ChatMessage message) async {
    if (_recallingMessageIds.contains(message.id)) return;
    if (!_canRecallMessage(message)) return;
    final shouldRecall = await showDialog<bool>(
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
    if (!shouldRecall) return;
    await _recallMessage(message);
  }

  Future<void> _recallMessage(ChatMessage message) async {
    if (_isShareEntry && _localUserId == null) return;
    if (_recallingMessageIds.contains(message.id)) return;
    if (!mounted) return;
    setState(() {
      _recallingMessageIds.add(message.id);
    });
    try {
      final res = await _request(
        'DELETE',
        _meetingMessageItemApiPath(message.id),
        requireAuth: _isShareEntry,
      );
      await _jsonOrThrow(res);
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((row) => row.id == message.id);
        _latestMessageId = _messages.isEmpty ? 0 : _messages.last.id;
        _recallingMessageIds.remove(message.id);
      });
      _setStatus('消息已撤回');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recallingMessageIds.remove(message.id);
      });
      _setStatus('撤回消息失败：${_friendlyError(e)}');
    }
  }

  PreferredVideoSelection _findPreferredVideoTrack(
      lk.Participant participant) {
    final screenPub = participant
        .getTrackPublicationBySource(lk.TrackSource.screenShareVideo);
    if (screenPub != null &&
        screenPub.track is lk.VideoTrack &&
        !screenPub.muted) {
      return PreferredVideoSelection(
        track: screenPub.track as lk.VideoTrack,
        isScreenShare: true,
      );
    }
    final camPub =
        participant.getTrackPublicationBySource(lk.TrackSource.camera);
    if (camPub != null && camPub.track is lk.VideoTrack && !camPub.muted) {
      return PreferredVideoSelection(
        track: camPub.track as lk.VideoTrack,
        isScreenShare: false,
      );
    }
    for (final pub in participant.videoTrackPublications) {
      if (pub.track is lk.VideoTrack && !pub.muted) {
        return PreferredVideoSelection(
          track: pub.track as lk.VideoTrack,
          isScreenShare: pub.source == lk.TrackSource.screenShareVideo,
        );
      }
    }
    return const PreferredVideoSelection(track: null, isScreenShare: false);
  }

  List<ParticipantTileData> _collectTiles() {
    final room = _room;
    if (room == null) return const [];
    final output = <ParticipantTileData>[];
    final identities = <String>{};
    final local = room.localParticipant;
    if (local != null && identities.add(local.identity)) {
      final localVideo = _findPreferredVideoTrack(local);
      output.add(
        ParticipantTileData(
          identity: local.identity,
          displayName: _displayNameForIdentity(
            local.identity,
            fallback: local.name.trim().isNotEmpty
                ? local.name
                : (_meetingDisplayName.trim().isEmpty
                    ? local.identity
                    : _meetingDisplayName),
          ),
          avatarUrl: _avatarUrlForIdentity(local.identity),
          isLocal: true,
          isSpeaking: local.isSpeaking,
          audioLevel: _normalizedAudioLevel(local.audioLevel),
          micEnabled: local.isMicrophoneEnabled(),
          cameraEnabled: local.isCameraEnabled(),
          videoTrack: localVideo.track,
          isScreenShare: localVideo.isScreenShare,
        ),
      );
    }
    for (final p in room.remoteParticipants.values) {
      if (!identities.add(p.identity)) {
        continue;
      }
      final remoteVideo = _findPreferredVideoTrack(p);
      output.add(
        ParticipantTileData(
          identity: p.identity,
          displayName: _displayNameForIdentity(
            p.identity,
            fallback: p.name.trim().isEmpty ? p.identity : p.name,
          ),
          avatarUrl: _avatarUrlForIdentity(p.identity),
          isLocal: false,
          isSpeaking: p.isSpeaking,
          audioLevel: _normalizedAudioLevel(p.audioLevel),
          micEnabled: p.isMicrophoneEnabled(),
          cameraEnabled: p.isCameraEnabled(),
          videoTrack: remoteVideo.track,
          isScreenShare: remoteVideo.isScreenShare,
        ),
      );
    }
    return output;
  }

  List<ParticipantRowData> _collectParticipantRows() {
    final room = _room;
    if (room == null) return const [];
    final rows = <ParticipantRowData>[];
    final identities = <String>{};
    final local = room.localParticipant;
    if (local != null && identities.add(local.identity)) {
      final userId = _userIdFromIdentity(local.identity);
      final profile = userId == null ? null : _memberProfiles[userId];
      final requestFlags = _requestPendingFlagsForParticipant(local);
      final guestPermissionsReady =
          userId == null ? _participantPermissionsReady(local) : false;
      final guestAllowSelfUnmute = userId == null
          ? (guestPermissionsReady
              ? _participantCanPublishSource(
                  local,
                  _microphoneTrackSourceValue,
                )
              : _allowSelfUnmute)
          : null;
      final guestAllowMemberVideo = userId == null
          ? (guestPermissionsReady
              ? _participantCanPublishSource(
                  local,
                  _cameraTrackSourceValue,
                )
              : _allowMemberVideo)
          : null;
      final guestAllowChat = userId == null
          ? (guestPermissionsReady
              ? _participantCanPublishChat(local)
              : _allowChat)
          : null;
      final guestAllowScreenShare = userId == null
          ? (guestPermissionsReady
              ? (_participantCanPublishSource(
                    local,
                    _screenShareTrackSourceValue,
                  ) ||
                  _participantCanPublishSource(
                    local,
                    _screenShareAudioTrackSourceValue,
                  ))
              : _allowScreenShare)
          : null;
      final roleKey = (profile?.role ?? _currentUserRole).trim().isEmpty
          ? 'participant'
          : (profile?.role ?? _currentUserRole).trim();
      rows.add(
        ParticipantRowData(
          identity: local.identity,
          userId: userId,
          isRealtimeBot: false,
          displayName: _displayNameForIdentity(
            local.identity,
            fallback: local.name.trim().isNotEmpty
                ? local.name
                : (_meetingDisplayName.trim().isEmpty
                    ? local.identity
                    : _meetingDisplayName),
          ),
          avatarUrl: _avatarUrlForIdentity(local.identity),
          role: _roleLabel(roleKey),
          roleKey: roleKey,
          isSpeaking: local.isSpeaking,
          audioLevel: _normalizedAudioLevel(local.audioLevel),
          micEnabled: local.isMicrophoneEnabled(),
          cameraEnabled: local.isCameraEnabled(),
          mutedByHost: profile?.mutedByHost ?? !local.isMicrophoneEnabled(),
          videoBlockedByHost:
              profile?.videoBlockedByHost ?? !local.isCameraEnabled(),
          allowSelfUnmute: profile?.allowSelfUnmute ??
              guestAllowSelfUnmute ??
              (_isModerator || _allowSelfUnmute),
          allowMemberVideo: profile?.allowMemberVideo ??
              guestAllowMemberVideo ??
              (_isModerator || _allowMemberVideo),
          allowChat: profile?.allowChat ??
              guestAllowChat ??
              (_isModerator || _allowChat),
          allowScreenShare: profile?.allowScreenShare ??
              guestAllowScreenShare ??
              (_isModerator || _allowScreenShare),
          micRequestPending:
              (profile?.micRequestPending ?? false) || requestFlags.micPending,
          videoRequestPending: (profile?.videoRequestPending ?? false) ||
              requestFlags.videoPending,
          screenShareRequestPending: requestFlags.screenSharePending,
          isScreenSharing: _isScreenSharing(local),
        ),
      );
    }
    for (final p in room.remoteParticipants.values) {
      if (!identities.add(p.identity)) {
        continue;
      }
      final userId = _userIdFromIdentity(p.identity);
      final profile = userId == null ? null : _memberProfiles[userId];
      final requestFlags = _requestPendingFlagsForParticipant(p);
      final guestPermissionsReady =
          userId == null ? _participantPermissionsReady(p) : false;
      final guestAllowSelfUnmute = userId == null
          ? (guestPermissionsReady
              ? _participantCanPublishSource(
                  p,
                  _microphoneTrackSourceValue,
                )
              : _allowSelfUnmute)
          : null;
      final guestAllowMemberVideo = userId == null
          ? (guestPermissionsReady
              ? _participantCanPublishSource(
                  p,
                  _cameraTrackSourceValue,
                )
              : _allowMemberVideo)
          : null;
      final guestAllowChat = userId == null
          ? (guestPermissionsReady ? _participantCanPublishChat(p) : _allowChat)
          : null;
      final guestAllowScreenShare = userId == null
          ? (guestPermissionsReady
              ? (_participantCanPublishSource(
                    p,
                    _screenShareTrackSourceValue,
                  ) ||
                  _participantCanPublishSource(
                    p,
                    _screenShareAudioTrackSourceValue,
                  ))
              : _allowScreenShare)
          : null;
      final roleKey = (profile?.role ?? 'participant').trim().isEmpty
          ? 'participant'
          : (profile?.role ?? 'participant').trim();
      rows.add(
        ParticipantRowData(
          identity: p.identity,
          userId: userId,
          isRealtimeBot: false,
          displayName: _displayNameForIdentity(
            p.identity,
            fallback: p.name.trim().isEmpty ? p.identity : p.name,
          ),
          avatarUrl: _avatarUrlForIdentity(p.identity),
          role: _roleLabel(roleKey),
          roleKey: roleKey,
          isSpeaking: p.isSpeaking,
          audioLevel: _normalizedAudioLevel(p.audioLevel),
          micEnabled: p.isMicrophoneEnabled(),
          cameraEnabled: p.isCameraEnabled(),
          mutedByHost: profile?.mutedByHost ?? !p.isMicrophoneEnabled(),
          videoBlockedByHost:
              profile?.videoBlockedByHost ?? !p.isCameraEnabled(),
          allowSelfUnmute: profile?.allowSelfUnmute ??
              guestAllowSelfUnmute ??
              (roleKey == 'host' || roleKey == 'cohost' || _allowSelfUnmute),
          allowMemberVideo: profile?.allowMemberVideo ??
              guestAllowMemberVideo ??
              (roleKey == 'host' || roleKey == 'cohost' || _allowMemberVideo),
          allowChat: profile?.allowChat ??
              guestAllowChat ??
              (roleKey == 'host' || roleKey == 'cohost' || _allowChat),
          allowScreenShare: profile?.allowScreenShare ??
              guestAllowScreenShare ??
              (roleKey == 'host' || roleKey == 'cohost' || _allowScreenShare),
          micRequestPending:
              (profile?.micRequestPending ?? false) || requestFlags.micPending,
          videoRequestPending: (profile?.videoRequestPending ?? false) ||
              requestFlags.videoPending,
          screenShareRequestPending: requestFlags.screenSharePending,
          isScreenSharing: _isScreenSharing(p),
        ),
      );
    }
    if (_realtimeBotEnabled &&
        !rows.any((row) => row.identity == _realtimeBotVirtualIdentity())) {
      rows.add(
        ParticipantRowData(
          identity: _realtimeBotVirtualIdentity(),
          userId: _realtimeBotUserId,
          isRealtimeBot: true,
          displayName: _realtimeBotDisplayName.trim().isEmpty
              ? '实时语音助手'
              : _realtimeBotDisplayName.trim(),
          avatarUrl: '',
          role: 'AI成员',
          roleKey: 'ai',
          isSpeaking: false,
          audioLevel: 0,
          micEnabled: !_realtimeBotMuted,
          cameraEnabled: false,
          mutedByHost: _realtimeBotMuted,
          videoBlockedByHost: true,
          allowSelfUnmute: !_realtimeBotMuted,
          allowMemberVideo: false,
          allowChat: _allowChat,
          allowScreenShare: false,
          micRequestPending: false,
          videoRequestPending: false,
          screenShareRequestPending: false,
          isScreenSharing: false,
        ),
      );
    }
    return rows;
  }

  Future<void> _requestCoreMediaPermissions() async {
    final denied = await _ensurePermissionsForJoin(
      enableMic: true,
      enableCamera: true,
    );
    if (!mounted) return;
    if (denied.isEmpty) {
      _setStatus('麦克风和摄像头权限已就绪');
      return;
    }
    await _showPermissionDeniedDialog(denied);
  }

  Future<void> _handleMobileMenuAction(String action) async {
    switch (action) {
      case 'join':
        if (!(_connected || _joining || _waitingForAdmission)) {
          await _openJoinSetupDialog();
        }
        return;
      case 'moderator':
        if (_canUseModeratorControls) {
          await _openModeratorControlDialog();
        }
        return;
      case 'ai_control':
        if (_canUseModeratorControls) {
          await _openAiControlDialog();
        }
        return;
      case 'display_name':
        await _openMeetingDisplayNameDialog();
        return;
      case 'media':
        await _openMediaSettingsDialog();
        return;
      case 'permissions':
        await _requestCoreMediaPermissions();
        return;
      case 'share':
        await _openMeetingShareDialog();
        return;
      case 'copy_room':
        await _copyMeetingNumber();
        return;
      case 'back':
        html.window.location.assign(_isShareEntry ? '/' : '/dashboard');
        return;
      default:
        return;
    }
  }

  Widget _buildMobileTopAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(11),
        border:
            Border.all(color: _palette.heroMutedText.withValues(alpha: 0.27)),
      ),
      child: IconButton(
        tooltip: tooltip,
        visualDensity: VisualDensity.compact,
        iconSize: 19,
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white),
      ),
    );
  }

  PopupMenuEntry<String> _buildMobileMenuItem({
    required String value,
    required IconData icon,
    required String title,
    required String subtitle,
    bool danger = false,
  }) {
    final iconBg = danger ? _palette.dangerSurface : _palette.primarySoft;
    final iconFg = danger ? _palette.danger : _palette.primaryStrong;
    final titleColor = danger ? _palette.danger : _palette.textPrimary;
    final subtitleColor = danger ? _palette.danger : _palette.textMuted;
    return PopupMenuItem<String>(
      value: value,
      child: SizedBox(
        width: 228,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 18, color: iconFg),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: titleColor,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: subtitleColor,
                      fontSize: 11.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileMoreAction() {
    final hasNotice = _canUseModeratorControls && _hasNewWaitingRoomNotice;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      child: PopupMenuButton<String>(
        tooltip: '更多操作',
        onSelected: _handleMobileMenuAction,
        offset: const Offset(-8, 48),
        elevation: 12,
        color: _palette.surface,
        surfaceTintColor: _palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _palette.panelBorder),
        ),
        itemBuilder: (_) {
          final entries = <PopupMenuEntry<String>>[];
          if (!(_connected || _joining || _waitingForAdmission)) {
            entries.add(
              _buildMobileMenuItem(
                value: 'join',
                icon: Icons.login_rounded,
                title: '加入会议',
                subtitle: '打开入会前设置',
              ),
            );
          }
          entries.add(
            _buildMobileMenuItem(
              value: 'permissions',
              icon: Icons.perm_camera_mic_outlined,
              title: '请求设备权限',
              subtitle: '申请麦克风和摄像头访问',
            ),
          );
          entries.add(
            _buildMobileMenuItem(
              value: 'display_name',
              icon: Icons.badge_outlined,
              title: '修改显示名',
              subtitle: '设置本场会议中的昵称',
            ),
          );
          entries.add(
            _buildMobileMenuItem(
              value: 'copy_room',
              icon: Icons.copy_outlined,
              title: '复制会议号',
              subtitle: '复制当前会议号到剪贴板',
            ),
          );
          entries.add(
            _buildMobileMenuItem(
              value: 'share',
              icon: Icons.share_outlined,
              title: '会议分享',
              subtitle: '复制邀请链接或完整会议信息',
            ),
          );
          if (_canUseModeratorControls) {
            entries.add(const PopupMenuDivider(height: 6));
            entries.add(
              _buildMobileMenuItem(
                value: 'moderator',
                icon: Icons.admin_panel_settings_outlined,
                title: '会议管控',
                subtitle: '成员权限、等候室与主持控制',
              ),
            );
            entries.add(
              _buildMobileMenuItem(
                value: 'ai_control',
                icon: Icons.smart_toy_outlined,
                title: 'AI管控',
                subtitle: '实时语音模型配置与连通性测试',
              ),
            );
          }
          entries.add(const PopupMenuDivider(height: 6));
          entries.add(
            _buildMobileMenuItem(
              value: 'media',
              icon: Icons.tune_rounded,
              title: '音视频设置',
              subtitle: '摄像头、麦克风与清晰度设置',
            ),
          );
          entries.add(
            _buildMobileMenuItem(
              value: 'back',
              icon: Icons.arrow_back_rounded,
              title: _isShareEntry ? '返回首页' : '返回控制台',
              subtitle: _isShareEntry ? '离开会议页面' : '返回会议控制台',
              danger: true,
            ),
          );
          return entries;
        },
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: _palette.heroMutedText.withValues(alpha: 0.27),
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.more_horiz_rounded,
                  color: Colors.white, size: 20),
              if (hasNotice)
                Positioned(
                  top: -3,
                  right: -3,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _palette.danger,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileTopBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _palette.heroBorder),
        gradient: LinearGradient(
          colors: [_palette.heroGradientStart, _palette.heroGradientEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _meetingTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '会议号：$_roomNumber',
                  style: TextStyle(
                    color: _palette.heroMutedText,
                    fontSize: 12.5,
                  ),
                ),
                Text(
                  _meetingDisplayName.isEmpty
                      ? _defaultDisplayName
                      : _meetingDisplayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _palette.heroMutedText,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          _buildMobileTopAction(
            tooltip: '会议分享',
            icon: Icons.share_outlined,
            onPressed: _openMeetingShareDialog,
          ),
          _buildMobileTopAction(
            tooltip: '音视频设置',
            icon: Icons.tune,
            onPressed: _openMediaSettingsDialog,
          ),
          _buildMobileMoreAction(),
        ],
      ),
    );
  }

  Widget _buildStageCard({double radius = 16}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _palette.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: _palette.panelBorder),
      ),
      child: _buildStage(),
    );
  }

  bool get _isTileFullscreenActive =>
      _fullscreenIdentity != null && html.document.fullscreenElement != null;

  ParticipantTileData? _fullscreenTileData() {
    final identity = _fullscreenIdentity;
    if (identity == null) return null;
    for (final tile in _collectTiles()) {
      if (tile.identity == identity) {
        return tile;
      }
    }
    return null;
  }

  Widget _buildFullscreenTileScaffold() {
    final tile = _fullscreenTileData();
    if (tile == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: FilledButton.icon(
            onPressed: () {
              html.document.exitFullscreen();
            },
            icon: const Icon(Icons.fullscreen_exit),
            label: const Text('Exit Fullscreen'),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(
          child: _buildVideoTile(tile),
        ),
      ),
    );
  }

  Widget _buildMobileControlButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    Color? foregroundColor,
    Color? backgroundColor,
  }) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: FilledButton(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 10),
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
          ),
          onPressed: onPressed,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileDock() {
    final canSelfUnmute = _localCanSelfUnmute;
    final canOpenVideo = _localCanMemberVideo;
    final canShareScreen = _localCanScreenShare;
    final canRecord = _canRecordMeeting && !_recordingUploading;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: _palette.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _palette.panelBorder),
      ),
      child: Row(
        children: [
          _buildMobileControlButton(
            icon: _micEnabled ? Icons.mic : Icons.mic_off,
            label: _micEnabled ? '静音' : '取消静音',
            onPressed: (_connected && (_micEnabled || canSelfUnmute))
                ? _toggleMic
                : null,
          ),
          _buildMobileControlButton(
            icon: _cameraEnabled ? Icons.videocam : Icons.videocam_off,
            label: _cameraEnabled ? '关闭摄像头' : '开启摄像头',
            onPressed: (_connected && (_cameraEnabled || canOpenVideo))
                ? _toggleCamera
                : null,
          ),
          _buildMobileControlButton(
            icon: _screenShareEnabled
                ? Icons.stop_screen_share
                : Icons.screen_share_outlined,
            label: _screenShareEnabled ? '停止共享' : '共享屏幕',
            onPressed:
                (_connected && canShareScreen) ? _toggleScreenShare : null,
          ),
          _buildMobileControlButton(
            icon: _recordingUploading
                ? Icons.cloud_upload_outlined
                : (_recordingActive
                    ? Icons.stop_circle_outlined
                    : Icons.fiber_manual_record),
            label: _recordingUploading
                ? '上传中'
                : (_recordingActive ? '停止录制' : '开始录制'),
            onPressed: canRecord
                ? (_recordingActive
                    ? _stopMeetingRecording
                    : _startMeetingRecording)
                : null,
            backgroundColor:
                _recordingActive ? _palette.danger : _palette.primary,
          ),
          _buildMobileControlButton(
            icon: Icons.call_end,
            label: _isHost && _requiresAuth ? '结束会议' : '离开会议',
            onPressed: _connected ? _handleLeaveButtonPressed : null,
            backgroundColor: _palette.danger,
          ),
        ],
      ),
    );
  }

  Widget _buildRealtimeBotDebugChip({
    required String label,
    required String value,
    required bool dark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: dark ? Colors.white.withValues(alpha: 0.15) : _palette.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: dark
              ? _palette.heroMutedText.withValues(alpha: 0.35)
              : _palette.primaryBorder,
        ),
      ),
      child: MeetingMetaText(
        '$label: $value',
        style: TextStyle(
          color: dark ? _palette.heroMutedText : _palette.primaryStrong,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _buildRealtimeBotDebugPanel({bool dark = false}) {
    if (!_showRealtimeBotDebugPanel) {
      return const SizedBox.shrink();
    }
    final providerLabel =
        _realtimeBotProvider == 'volcengine' ? 'volcengine' : 'openai';
    final latencyText = _realtimeBotDebugLastUploadLatencyMs == null
        ? '-'
        : '${_realtimeBotDebugLastUploadLatencyMs.toString()} ms';
    final shouldRun = _shouldRunRealtimeBotAudioIngress();
    final blocker = _realtimeBotIngressBlocker();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color:
            dark ? Colors.white.withValues(alpha: 0.10) : _palette.primarySoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: dark
              ? _palette.heroMutedText.withValues(alpha: 0.35)
              : _palette.primaryBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.bug_report_outlined,
                size: 14,
                color: dark ? _palette.heroMutedText : _palette.primaryStrong,
              ),
              const SizedBox(width: 6),
              MeetingTitleText(
                'AI Debug',
                style: TextStyle(
                  color: dark ? _palette.heroMutedText : _palette.primaryStrong,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              MeetingMetaText(
                _realtimeBotDebugLastEvent,
                style: TextStyle(
                  color: dark ? _palette.heroMutedText : _palette.primaryStrong,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _buildRealtimeBotDebugChip(
                label: 'provider',
                value: providerLabel,
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'enabled',
                value: _realtimeBotEnabled ? 'on' : 'off',
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'auto_listen',
                value: _realtimeBotAutoListen ? 'on' : 'off',
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'connected',
                value: _connected ? 'yes' : 'no',
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'moderator',
                value: _isModerator ? 'yes' : 'no',
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'room',
                value: _room == null ? 'null' : 'ready',
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'should_run',
                value: shouldRun ? 'yes' : 'no',
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'listening',
                value: _realtimeBotListening ? 'on' : 'off',
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'starting',
                value: _realtimeBotCaptureStarting ? 'yes' : 'no',
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'uploading',
                value: _realtimeBotAudioUploading ? 'yes' : 'no',
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'ctx_state',
                value: _clipDebugText(
                  _realtimeBotDebugAudioContextState,
                  maxLength: 24,
                ),
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'sources',
                value: _realtimeBotDebugInputSourceCount.toString(),
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'fallback_mic',
                value: _realtimeBotDebugFallbackMicOpen ? 'on' : 'off',
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'voice',
                value: _realtimeBotDebugVoiceActive ? 'active' : 'idle',
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'rms',
                value: _realtimeBotDebugLastRms.toStringAsFixed(4),
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'process_count',
                value: _realtimeBotDebugProcessCount.toString(),
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'buffer',
                value: _realtimeBotDebugBufferedBytes.toString(),
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'last_chunk',
                value: _realtimeBotDebugLastUploadBytes.toString(),
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'uploads',
                value: _realtimeBotDebugUploadCount.toString(),
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'latency',
                value: latencyText,
                dark: dark,
              ),
              _buildRealtimeBotDebugChip(
                label: 'last_upload',
                value: _formatDebugTime(_realtimeBotDebugLastUploadAt),
                dark: dark,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor:
                    dark ? _palette.heroMutedText : _palette.primaryStrong,
                side: BorderSide(
                  color: dark
                      ? _palette.heroMutedText.withValues(alpha: 0.35)
                      : _palette.primaryBorder,
                ),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _realtimeBotCaptureStarting
                  ? null
                  : () => unawaited(_forceRestartRealtimeBotAudioIngress()),
              icon: const Icon(Icons.restart_alt, size: 16),
              label: const Text('重启收音'),
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor:
                    dark ? _palette.heroMutedText : _palette.primaryStrong,
                side: BorderSide(
                  color: dark
                      ? _palette.heroMutedText.withValues(alpha: 0.35)
                      : _palette.primaryBorder,
                ),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _realtimeBotCaptureStarting
                  ? null
                  : () => unawaited(_enableRealtimeBotFallbackMicFromGesture()),
              icon: const Icon(Icons.mic, size: 16),
              label: const Text('启用麦克风采集'),
            ),
          ),
          const SizedBox(height: 6),
          MeetingDebugText(
            'preview: ${_clipDebugText(_realtimeBotDebugLastPreview)}',
            style: TextStyle(
              color: dark ? _palette.heroMutedText : _palette.primaryStrong,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 4),
          MeetingDebugText(
            'last_process: ${_formatDebugTime(_realtimeBotDebugLastProcessAt)}',
            style: TextStyle(
              color: dark ? _palette.heroMutedText : _palette.primaryStrong,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 4),
          MeetingDebugText(
            'blocker: ${_clipDebugText(blocker)}',
            style: TextStyle(
              color: dark ? _palette.heroMutedText : _palette.primaryStrong,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 4),
          MeetingErrorText(
            'error: ${_clipDebugText(_realtimeBotDebugLastError)}',
            style: TextStyle(
              color: dark ? _palette.dangerSoft : _palette.danger,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileMeetingScaffold() {
    return Scaffold(
      body: MeetingSelectableRegion(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [_palette.pageBackground, _palette.primarySoft],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
              child: Column(
                children: [
                  _buildMobileTopBar(),
                  const SizedBox(height: 8),
                  _buildMeetingMetricsStrip(),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: _palette.primarySoft,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _palette.primaryBorder),
                    ),
                    child: MeetingStatusText(
                      _status,
                      maxLines: 2,
                      style: TextStyle(
                        color: _palette.primaryStrong,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (_showRealtimeBotDebugPanel) ...[
                    const SizedBox(height: 8),
                    _buildRealtimeBotDebugPanel(),
                  ],
                  if ((_permissionWarning ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _buildPermissionBanner(),
                  ],
                  const SizedBox(height: 8),
                  Expanded(
                    child: DefaultTabController(
                      length: 4,
                      child: Column(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: _palette.surface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _palette.panelBorder,
                              ),
                            ),
                            child: const TabBar(
                              tabs: [
                                Tab(
                                  icon: Icon(Icons.grid_view_rounded),
                                  text: '舞台',
                                ),
                                Tab(
                                  icon: Icon(Icons.groups_outlined),
                                  text: '成员',
                                ),
                                Tab(
                                  icon: Icon(Icons.chat_bubble_outline),
                                  text: '聊天',
                                ),
                                Tab(
                                  icon: Icon(Icons.hub_outlined),
                                  text: '工作区',
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: TabBarView(
                              children: [
                                _buildStageCard(radius: 14),
                                _buildParticipantPanel(),
                                _buildChatPanel(
                                  headerActions: [
                                    MeetingPanelHeaderActionBar(
                                      panelLabel: '聊天',
                                      isFullscreen: false,
                                      onToggleFullscreen: () =>
                                          _openCommunicationPanelFullscreen(
                                        forChat: true,
                                      ),
                                    ),
                                  ],
                                ),
                                _buildWorkspacePanel(
                                  headerActions: [
                                    MeetingPanelHeaderActionBar(
                                      panelLabel: '工作区',
                                      isFullscreen: false,
                                      onToggleFullscreen: () =>
                                          _openCommunicationPanelFullscreen(
                                        forChat: false,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildMobileDock(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMeetingMetricsStrip() {
    final activeCount = _activeParticipantCount();
    final maxParticipants = _maxParticipants <= 0 ? 100 : _maxParticipants;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _palette.primarySoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _palette.primaryBorder),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _buildTopMetricChip(
            icon: _networkQualityIcon(),
            text: '网络：${_networkQualityLabel()}',
            accent: _networkQualityTint(),
          ),
          _buildTopMetricChip(
            icon: Icons.groups_rounded,
            text: '参会/预订：$activeCount/$maxParticipants',
            accent: _palette.primaryStrong,
          ),
          _buildTopMetricChip(
            icon: Icons.timer_outlined,
            text: '时长：${_meetingElapsedText()}',
            accent: _palette.primaryStrong,
          ),
          if (_recordingActive || _recordingUploading)
            _buildTopMetricChip(
              icon: _recordingUploading
                  ? Icons.cloud_upload_outlined
                  : Icons.fiber_manual_record,
              text: _recordingUploading ? '录制上传中' : '正在录制',
              accent: _palette.danger,
            ),
        ],
      ),
    );
  }

  Widget _buildDesktopHeaderAction({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool filled = false,
    Color? backgroundColor,
  }) {
    if (filled) {
      return FilledButton.icon(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          backgroundColor: backgroundColor,
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label),
      );
    }
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: _palette.heroMutedText),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }

  Widget _buildDesktopCompactHeader() {
    final activeCount = _activeParticipantCount();
    final maxParticipants = _maxParticipants <= 0 ? 100 : _maxParticipants;
    final displayName =
        _meetingDisplayName.isEmpty ? _defaultDisplayName : _meetingDisplayName;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _palette.heroBorder),
        gradient: LinearGradient(
          colors: [_palette.heroGradientStart, _palette.heroGradientEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MeetingTitleText(
                      _meetingTitle,
                      maxLines: 1,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        MeetingMetaText(
                          '会议号：$_roomNumber',
                          style: TextStyle(
                            color: _palette.heroMutedText,
                            fontSize: 12.5,
                          ),
                        ),
                        GestureDetector(
                          onDoubleTap: _openMeetingDisplayNameDialog,
                          child: MeetingMetaText(
                            '显示名：$displayName',
                            style: TextStyle(
                              color: _palette.heroMutedText,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: _palette.heroMutedText,
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: _copyMeetingNumber,
                          icon: const Icon(Icons.copy_outlined, size: 14),
                          label: const Text('复制会议号'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.end,
                    children: [
                      _buildDesktopHeaderAction(
                        label: '分享',
                        icon: Icons.share_outlined,
                        onPressed: _openMeetingShareDialog,
                      ),
                      _buildDesktopHeaderAction(
                        label: '音视频设置',
                        icon: Icons.tune,
                        onPressed: _openMediaSettingsDialog,
                      ),
                      if (_canUseModeratorControls)
                        _buildDesktopHeaderAction(
                          label: '会议管控',
                          icon: _waitingRoomEntries.isNotEmpty
                              ? Icons.notifications_active
                              : Icons.admin_panel_settings,
                          onPressed: _openModeratorControlDialog,
                        ),
                      if (_canUseModeratorControls)
                        _buildDesktopHeaderAction(
                          label: 'AI管控',
                          icon: Icons.smart_toy_outlined,
                          onPressed: _openAiControlDialog,
                        ),
                      _buildDesktopHeaderAction(
                        label: _isShareEntry ? '返回首页' : '返回控制台',
                        icon: Icons.arrow_back_rounded,
                        onPressed: () => html.window.location
                            .assign(_isShareEntry ? '/' : '/dashboard'),
                      ),
                      _buildDesktopHeaderAction(
                        label: _waitingForAdmission
                            ? '等候室等待中'
                            : (_joining ? '连接中...' : '加入会议'),
                        icon: _joining ? Icons.sync : Icons.login,
                        onPressed:
                            (_connected || _joining || _waitingForAdmission)
                                ? null
                                : _openJoinSetupDialog,
                        filled: true,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildTopMetricChip(
                icon: _networkQualityIcon(),
                text: '网络：${_networkQualityLabel()}',
                accent: _networkQualityTint(),
              ),
              _buildTopMetricChip(
                icon: Icons.groups_rounded,
                text: '参会/预订：$activeCount/$maxParticipants',
                accent: _palette.primaryStrong,
              ),
              _buildTopMetricChip(
                icon: Icons.timer_outlined,
                text: '时长：${_meetingElapsedText()}',
                accent: _palette.primaryStrong,
              ),
              if (_recordingActive || _recordingUploading)
                _buildTopMetricChip(
                  icon: _recordingUploading
                      ? Icons.cloud_upload_outlined
                      : Icons.fiber_manual_record,
                  text: _recordingUploading ? '录制上传中' : '正在录制',
                  accent: _palette.danger,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: _palette.heroMutedText.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: _palette.heroMutedText,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: MeetingStatusText(
                    _status,
                    maxLines: 1,
                    style: TextStyle(
                      color: _palette.heroMutedText,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_showRealtimeBotDebugPanel) ...[
            const SizedBox(height: 8),
            _buildRealtimeBotDebugPanel(dark: true),
          ],
        ],
      ),
    );
  }

  Widget _buildDesktopCollapsedRail({
    required String label,
    required IconData icon,
    required bool left,
    required String tooltip,
    required VoidCallback onToggle,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _palette.panelBorder),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: _palette.primaryStrong),
          const SizedBox(height: 8),
          RotatedBox(
            quarterTurns: 3,
            child: Text(
              label,
              style: TextStyle(
                color: _palette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Tooltip(
            message: tooltip,
            child: IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onToggle,
              icon: Icon(
                left ? Icons.chevron_right : Icons.chevron_left,
                color: _palette.primaryStrong,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopCollapsiblePanel({
    required bool collapsed,
    required bool left,
    required double expandedWidth,
    required String collapsedLabel,
    required IconData collapsedIcon,
    required String collapseTooltip,
    required String expandTooltip,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    return AnimatedContainer(
      duration: _desktopPanelAnimationDuration,
      curve: Curves.easeOutCubic,
      width: collapsed ? _desktopSideRailWidth : expandedWidth,
      child: collapsed
          ? _buildDesktopCollapsedRail(
              label: collapsedLabel,
              icon: collapsedIcon,
              left: left,
              tooltip: expandTooltip,
              onToggle: onToggle,
            )
          : Stack(
              children: [
                Positioned.fill(child: child),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Tooltip(
                    message: collapseTooltip,
                    child: Material(
                      color: _palette.surfaceMuted,
                      shape: const CircleBorder(),
                      elevation: 1,
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        splashRadius: 16,
                        onPressed: onToggle,
                        icon: Icon(
                          left ? Icons.chevron_left : Icons.chevron_right,
                          size: 18,
                          color: _palette.primaryStrong,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildDesktopMeetingContent(BoxConstraints constraints) {
    final participantWidth = constraints.maxWidth >= 1560
        ? 320.0
        : (constraints.maxWidth >= 1320 ? 286.0 : 250.0);
    final chatWidth = constraints.maxWidth >= 1560
        ? 392.0
        : (constraints.maxWidth >= 1320 ? 350.0 : 310.0);
    return Row(
      children: [
        _buildDesktopCollapsiblePanel(
          collapsed: _desktopParticipantsCollapsed,
          left: true,
          expandedWidth: participantWidth,
          collapsedLabel: '成员',
          collapsedIcon: Icons.groups_outlined,
          collapseTooltip: '折叠参会成员',
          expandTooltip: '展开参会成员',
          onToggle: () {
            setState(() {
              _desktopParticipantsCollapsed = !_desktopParticipantsCollapsed;
            });
          },
          child: _buildParticipantPanel(),
        ),
        const SizedBox(width: 10),
        Expanded(child: _buildStageCard()),
        const SizedBox(width: 10),
        _buildDesktopCollapsiblePanel(
          collapsed: _desktopChatCollapsed,
          left: false,
          expandedWidth: chatWidth,
          collapsedLabel: '协作',
          collapsedIcon: Icons.hub_outlined,
          collapseTooltip: '折叠协作面板',
          expandTooltip: '展开协作面板',
          onToggle: () {
            setState(() {
              _desktopChatCollapsed = !_desktopChatCollapsed;
            });
          },
          child: _buildCommunicationPanel(),
        ),
      ],
    );
  }

  Widget _buildVideoTile(ParticipantTileData tile) {
    final isFullscreen = _fullscreenIdentity == tile.identity &&
        html.document.fullscreenElement != null;
    final isSpotlight = _spotlightIdentity == tile.identity;
    final canZoom = tile.videoTrack != null && (isSpotlight || isFullscreen);
    final currentScale = _zoomScaleOf(tile.identity);
    Widget mediaLayer;
    if (tile.videoTrack != null) {
      mediaLayer = lk.VideoTrackRenderer(
        tile.videoTrack!,
        fit: _videoFitForTile(tile),
      );
      if (canZoom) {
        mediaLayer = InteractiveViewer(
          transformationController: _zoomControllerFor(tile.identity),
          minScale: _minTileZoomScale,
          maxScale: _maxTileZoomScale,
          panEnabled: true,
          scaleEnabled: true,
          boundaryMargin: const EdgeInsets.all(120),
          clipBehavior: Clip.hardEdge,
          child: SizedBox.expand(child: mediaLayer),
        );
      }
    } else {
      mediaLayer = Container(
        color: _palette.primarySoft,
        alignment: Alignment.center,
        child: _buildParticipantAvatar(
          displayName: tile.displayName,
          avatarUrl: tile.avatarUrl,
          radius: 24,
        ),
      );
    }
    return GestureDetector(
      onDoubleTap: () => _toggleSpotlight(tile.identity),
      child: Container(
        decoration: BoxDecoration(
          color: _palette.primarySoft,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: tile.isSpeaking ? _palette.primary : _palette.primaryBorder,
            width: tile.isSpeaking ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(child: mediaLayer),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                decoration: BoxDecoration(
                  color: _palette.primary.withValues(alpha: 0.67),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: IconButton(
                  tooltip: isFullscreen ? '退出全屏' : '全屏显示该画面',
                  onPressed: () => _toggleTileFullscreen(tile.identity),
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
                  identity: tile.identity,
                  scale: currentScale,
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: _palette.primary.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        tile.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12.5),
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
                    if (tile.isScreenShare)
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(
                          Icons.screen_share_rounded,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    Icon(
                      tile.micEnabled ? Icons.mic : Icons.mic_off,
                      size: 14,
                      color: tile.micEnabled
                          ? _palette.success
                          : _palette.dangerSoft,
                    ),
                    const SizedBox(width: 6),
                    ParticipantAudioLevelBar(
                      level: tile.audioLevel,
                      isActive: tile.micEnabled &&
                          (tile.isSpeaking || tile.audioLevel > 0.02),
                      width: 40,
                      height: 4,
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      tile.cameraEnabled ? Icons.videocam : Icons.videocam_off,
                      size: 14,
                      color: tile.cameraEnabled
                          ? _palette.heroMutedText
                          : _palette.dangerSoft,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
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

  Widget _buildStage() {
    final tiles = _collectTiles();
    if (tiles.isEmpty) {
      if (_waitingForAdmission) {
        return Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _palette.surfaceRaised,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _palette.panelBorder),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              const SizedBox(height: 10),
              Text(
                '已进入会议主界面，正在等候室等待主持人准入...',
                textAlign: TextAlign.center,
                style: TextStyle(color: _palette.textSecondary),
              ),
            ],
          ),
        );
      }
      final placeholder = _joining
          ? '正在连接会议，请稍候...'
          : (widget.autoJoin ? '自动入会未完成，可点击右上角“加入会议”重试' : '点击“加入会议”后开始音视频通话');
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _palette.surfaceRaised,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _palette.panelBorder),
        ),
        child: Text(
          placeholder,
          style: TextStyle(color: _palette.textSecondary),
        ),
      );
    }

    ParticipantTileData? spotlightTile;
    if (_spotlightIdentity != null) {
      for (final tile in tiles) {
        if (tile.identity == _spotlightIdentity) {
          spotlightTile = tile;
          break;
        }
      }
    }
    if (spotlightTile != null) {
      return Stack(
        children: [
          Positioned.fill(child: _buildVideoTile(spotlightTile)),
          Positioned(
            top: 56,
            left: 8,
            child: FilledButton.tonalIcon(
              onPressed: () => _toggleSpotlight(spotlightTile!.identity),
              icon: const Icon(Icons.grid_view),
              label: const Text('恢复宫格'),
            ),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        int crossAxisCount = 1;
        if (constraints.maxWidth >= 1100) {
          crossAxisCount = 3;
        } else if (constraints.maxWidth >= 700) {
          crossAxisCount = 2;
        }
        return GridView.builder(
          itemCount: tiles.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 16 / 10,
          ),
          itemBuilder: (context, index) => _buildVideoTile(tiles[index]),
        );
      },
    );
  }

  Widget _buildPermissionBanner() {
    final warning = _permissionWarning;
    if (warning == null || warning.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _palette.warningSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _palette.warningBorder),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: _palette.warning,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              warning,
              style: TextStyle(color: _palette.warning, fontSize: 12.5),
            ),
          ),
          TextButton(
            onPressed: _openMediaSettingsDialog,
            child: const Text('去设置'),
          ),
          IconButton(
            tooltip: '关闭提示',
            onPressed: () => setState(() => _permissionWarning = null),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildParticipantAvatar({
    required String displayName,
    required String avatarUrl,
    double radius = 12,
  }) {
    final trimmed = displayName.trim();
    final initial =
        trimmed.isEmpty ? '?' : trimmed.substring(0, 1).toUpperCase();
    if (avatarUrl.trim().isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: _palette.primarySoftAlt,
        foregroundColor: _palette.primaryStrong,
        child:
            Text(initial, style: const TextStyle(fontWeight: FontWeight.w700)),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: _palette.primarySoftAlt,
      backgroundImage: NetworkImage(avatarUrl),
      onBackgroundImageError: (_, __) {},
    );
  }

  Widget _buildPendingRequestChip({
    required String label,
    required VoidCallback onApprove,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onApprove,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: _palette.warningSurface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: _palette.warningBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.pan_tool_alt_rounded,
              size: 11,
              color: _palette.warning,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: _palette.warning,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.task_alt_rounded,
              size: 11,
              color: _palette.success,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleParticipantMenuAction(
    ParticipantRowData row,
    String action,
    bool isSelf,
  ) async {
    if (action == 'rename_self') {
      await _openMeetingDisplayNameDialog();
      return;
    }
    if (action == 'request_mic') {
      try {
        final submitted = await _submitPermissionRequest('mic');
        _setStatus(submitted ? '已提交开麦申请' : '开麦申请已提交，等待主持人批准');
        return;
      } catch (e) {
        _setStatus('提交开麦申请失败：${_friendlyError(e)}');
      }
      return;
    }
    if (action == 'request_video') {
      try {
        final submitted = await _submitPermissionRequest('video');
        _setStatus(submitted ? '已提交视频申请' : '视频申请已提交，等待主持人批准');
        return;
      } catch (e) {
        _setStatus('提交视频申请失败：${_friendlyError(e)}');
      }
      return;
    }
    if (action == 'request_share') {
      try {
        final submitted = await _submitPermissionRequest('screen_share');
        _setStatus(submitted ? '已提交屏幕共享申请' : '屏幕共享申请已提交，等待主持人批准');
      } catch (e) {
        _setStatus('提交屏幕共享申请失败：${_friendlyError(e)}');
      }
      return;
    }
    if (row.isRealtimeBot) {
      if (!_isModerator || !_hasPrivateMeetingApiScope) return;
      try {
        if (action == 'mute') {
          await _patchMeetingAiControls({'realtime_bot_muted': true});
          _setStatus('已将实时语音成员静音');
          return;
        }
        if (action == 'unmute') {
          await _patchMeetingAiControls({'realtime_bot_muted': false});
          _setStatus('已取消实时语音成员静音');
          return;
        }
        if (action == 'ai_control' || action == 'rename_member') {
          await _openAiControlDialog();
          return;
        }
      } catch (e) {
        _setStatus('AI成员控制失败：${_friendlyError(e)}');
        return;
      }
      return;
    }
    final userId = row.userId;
    final isGuest = userId == null;
    if (!_hasPrivateMeetingApiScope) return;
    if (isGuest &&
        (action == 'chat_permission_allow' ||
            action == 'chat_permission_block')) {
      _setStatus('访客聊天权限跟随会议设置，不能单独调整');
      return;
    }
    try {
      switch (action) {
        case 'mute':
          if (isGuest) {
            await _updateParticipantMuteByIdentity(row.identity, true);
          } else {
            await _updateMemberMute(userId, true);
          }
          _setStatus('已将成员静音');
          break;
        case 'unmute':
          if (isGuest) {
            await _updateParticipantMuteByIdentity(row.identity, false);
          } else {
            await _updateMemberMute(userId, false);
          }
          _setStatus('已允许成员开麦');
          break;
        case 'video_off':
          if (isGuest) {
            await _updateParticipantVideoByIdentity(row.identity, true);
          } else {
            await _updateMemberVideo(userId, true);
          }
          _setStatus('已关闭成员视频');
          break;
        case 'video_on':
          if (isGuest) {
            await _updateParticipantVideoByIdentity(row.identity, false);
          } else {
            await _updateMemberVideo(userId, false);
          }
          _setStatus('已允许成员开视频');
          break;
        case 'mic_permission_allow':
          if (isGuest) {
            await _updateParticipantMicPermissionByIdentity(row.identity, true);
          } else {
            await _updateMemberMicPermission(userId, true);
          }
          _setStatus('已允许该成员开麦');
          break;
        case 'mic_permission_block':
          if (isGuest) {
            await _updateParticipantMicPermissionByIdentity(
                row.identity, false);
          } else {
            await _updateMemberMicPermission(userId, false);
          }
          _setStatus('已禁止该成员开麦');
          break;
        case 'video_permission_allow':
          if (isGuest) {
            await _updateParticipantVideoPermissionByIdentity(
              row.identity,
              true,
            );
          } else {
            await _updateMemberVideoPermission(userId, true);
          }
          _setStatus('已允许该成员开视频');
          break;
        case 'video_permission_block':
          if (isGuest) {
            await _updateParticipantVideoPermissionByIdentity(
              row.identity,
              false,
            );
          } else {
            await _updateMemberVideoPermission(userId, false);
          }
          _setStatus('已禁止该成员开视频');
          break;
        case 'chat_permission_allow':
          if (isGuest) {
            await _updateParticipantChatPermissionByIdentity(
                row.identity, true);
          } else {
            await _updateMemberChatPermission(userId, true);
          }
          _setStatus('已允许该成员聊天');
          break;
        case 'chat_permission_block':
          if (isGuest) {
            await _updateParticipantChatPermissionByIdentity(
              row.identity,
              false,
            );
          } else {
            await _updateMemberChatPermission(userId, false);
          }
          _setStatus('已禁止该成员聊天');
          break;
        case 'share_permission_allow':
          if (isGuest) {
            await _updateParticipantScreenSharePermissionByIdentity(
              row.identity,
              true,
            );
          } else {
            await _updateMemberScreenSharePermission(userId, true);
          }
          _setStatus('已允许该成员屏幕共享');
          break;
        case 'share_permission_block':
          if (isGuest) {
            await _updateParticipantScreenSharePermissionByIdentity(
              row.identity,
              false,
            );
          } else {
            await _updateMemberScreenSharePermission(userId, false);
          }
          _setStatus('已禁止该成员屏幕共享');
          break;
        case 'stop_share':
          if (isGuest) {
            await _stopParticipantShareByIdentity(row.identity);
          } else {
            await _stopMemberShare(userId);
          }
          _setStatus('已结束成员屏幕共享');
          break;
        case 'set_cohost':
          if (isGuest) return;
          await _updateMemberRole(userId, 'cohost');
          _setStatus('已设为联席主持人');
          break;
        case 'set_participant':
          if (isGuest) return;
          await _updateMemberRole(userId, 'participant');
          _setStatus('已取消联席主持人');
          break;
        case 'rename_member':
          await _openRenameMemberDialog(row);
          break;
        case 'remove':
          if (isGuest) return;
          final removeOnlyConfirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('移出成员'),
                  content: Text('确认移出 ${row.displayName} 吗？移出后该成员可重新入会。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确认'),
                    ),
                  ],
                ),
              ) ??
              false;
          if (!removeOnlyConfirmed) return;
          await _removeMember(userId, banAfterRemove: false);
          _setStatus('已移出成员，可重新入会');
          break;
        case 'remove_ban':
          if (isGuest) return;
          final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('移出并封禁成员'),
                  content: Text('确认移出 ${row.displayName} 并禁止其再次入会吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确认'),
                    ),
                  ],
                ),
              ) ??
              false;
          if (!confirmed) return;
          await _removeAndBanMember(userId);
          _setStatus('已移出成员并禁止再次入会');
          break;
        case 'remove_guest':
          final guestConfirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('移出成员'),
                  content: Text('确认移出 ${row.displayName} 吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确认'),
                    ),
                  ],
                ),
              ) ??
              false;
          if (!guestConfirmed) return;
          await _removeParticipantByIdentity(row.identity);
          _setStatus('已移出访客成员');
          break;
      }
    } catch (e) {
      _setStatus('成员管控失败：${_friendlyError(e)}');
    }
  }

  // ignore: unused_element
  List<PopupMenuEntry<String>> _participantMenuItems(
    ParticipantRowData row,
    bool isSelf,
  ) {
    final items = <PopupMenuEntry<String>>[];
    if (isSelf) {
      items.add(
        const PopupMenuItem<String>(
          value: 'rename_self',
          child: Text('修改本次显示名'),
        ),
      );
      if (!row.allowSelfUnmute) {
        items.add(
          PopupMenuItem<String>(
            value: 'request_mic',
            enabled: !row.micRequestPending,
            child: Text(row.micRequestPending ? '开麦申请已提交' : '申请开麦'),
          ),
        );
      }
      if (!row.allowMemberVideo) {
        items.add(
          PopupMenuItem<String>(
            value: 'request_video',
            enabled: !row.videoRequestPending,
            child: Text(row.videoRequestPending ? '视频申请已提交' : '申请开视频'),
          ),
        );
      }
      if (!row.allowScreenShare) {
        items.add(
          _participantMenuActionItemRefined(
            value: 'request_share',
            title: row.screenShareRequestPending ? '屏幕共享申请已提交' : '申请屏幕共享',
            subtitle: row.screenShareRequestPending ? '等待主持人审批' : '提交后主持人可一键批准',
            icon: Icons.screen_share_outlined,
            enabled: !row.screenShareRequestPending,
          ),
        );
      }
      if (!row.allowScreenShare) {
        items.add(
          _participantMenuActionItemRefined(
            value: 'request_share',
            title: row.screenShareRequestPending ? '屏幕共享申请已提交' : '申请屏幕共享',
            subtitle: row.screenShareRequestPending ? '等待主持人审批' : '提交后主持人可一键批准',
            icon: Icons.screen_share_outlined,
            enabled: !row.screenShareRequestPending,
          ),
        );
      }
      return items;
    }

    final canModerateTarget = _isModerator && _hasPrivateMeetingApiScope;
    if (!canModerateTarget) {
      return items;
    }
    if (row.roleKey == 'host') {
      return items;
    }

    final muteAction = row.mutedByHost ? 'unmute' : 'mute';
    final muteLabel = row.mutedByHost ? '允许开麦（当前：主持人静音）' : '静音成员（当前：可开麦）';
    items.add(
      PopupMenuItem<String>(
        value: muteAction,
        child: Text(muteLabel),
      ),
    );
    final videoAction = row.videoBlockedByHost ? 'video_on' : 'video_off';
    final videoLabel =
        row.videoBlockedByHost ? '允许开视频（当前：主持人已关闭）' : '关闭成员视频（当前：允许开视频）';
    items.add(
      PopupMenuItem<String>(
        value: videoAction,
        child: Text(videoLabel),
      ),
    );
    if (row.isScreenSharing) {
      items.add(
        const PopupMenuItem<String>(
          value: 'stop_share',
          child: Text('结束屏幕共享'),
        ),
      );
    }
    if (row.userId == null) {
      items.add(
        const PopupMenuItem<String>(
          value: 'rename_member',
          child: Text('鎴愬憳鏀瑰悕'),
        ),
      );
      items.add(
        const PopupMenuItem<String>(
          value: 'remove_guest',
          child: Text('移出成员'),
        ),
      );
      return items;
    }
    items.add(
      PopupMenuItem<String>(
        value: row.allowSelfUnmute
            ? 'mic_permission_block'
            : 'mic_permission_allow',
        child: Text(row.allowSelfUnmute ? '禁止开麦（权限）' : '允许开麦（权限）'),
      ),
    );
    items.add(
      PopupMenuItem<String>(
        value: row.allowMemberVideo
            ? 'video_permission_block'
            : 'video_permission_allow',
        child: Text(row.allowMemberVideo ? '禁止开视频（权限）' : '允许开视频（权限）'),
      ),
    );
    items.add(
      PopupMenuItem<String>(
        value:
            row.allowChat ? 'chat_permission_block' : 'chat_permission_allow',
        child: Text(row.allowChat ? '禁止聊天（权限）' : '允许聊天（权限）'),
      ),
    );
    items.add(
      PopupMenuItem<String>(
        value: row.allowScreenShare
            ? 'share_permission_block'
            : 'share_permission_allow',
        child: Text(row.allowScreenShare ? '禁止屏幕共享（权限）' : '允许屏幕共享（权限）'),
      ),
    );
    if (row.micRequestPending && !row.allowSelfUnmute) {
      items.add(
        const PopupMenuItem<String>(
          value: 'mic_permission_allow',
          child: Text('通过开麦申请'),
        ),
      );
    }
    if (row.videoRequestPending && !row.allowMemberVideo) {
      items.add(
        const PopupMenuItem<String>(
          value: 'video_permission_allow',
          child: Text('通过视频申请'),
        ),
      );
    }
    if (row.roleKey == 'cohost') {
      items.add(
        const PopupMenuItem<String>(
          value: 'set_participant',
          child: Text('取消联席主持人'),
        ),
      );
    } else if (row.roleKey == 'participant') {
      items.add(
        const PopupMenuItem<String>(
          value: 'set_cohost',
          child: Text('设为联席主持人'),
        ),
      );
    }
    items.add(
      const PopupMenuItem<String>(
        value: 'rename_member',
        child: Text('成员改名'),
      ),
    );
    items.add(
      const PopupMenuItem<String>(
        value: 'remove',
        child: Text('移出成员（可重进）'),
      ),
    );
    items.add(
      const PopupMenuItem<String>(
        value: 'remove_ban',
        child: Text('移出并封禁'),
      ),
    );
    return items;
  }

  PopupMenuEntry<String> _participantMenuSectionRefined(String title) {
    return PopupMenuItem<String>(
      enabled: false,
      height: 24,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
      child: Text(
        title,
        style: TextStyle(
          color: _palette.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  IconData _participantMenuIconData(ParticipantMenuIcon icon) {
    switch (icon) {
      case ParticipantMenuIcon.badge:
        return Icons.badge_outlined;
      case ParticipantMenuIcon.mic:
        return Icons.mic;
      case ParticipantMenuIcon.micOff:
        return Icons.mic_off;
      case ParticipantMenuIcon.hand:
        return Icons.pan_tool_alt_outlined;
      case ParticipantMenuIcon.video:
        return Icons.videocam_outlined;
      case ParticipantMenuIcon.videoOff:
        return Icons.videocam_off;
      case ParticipantMenuIcon.screenShare:
        return Icons.screen_share_outlined;
      case ParticipantMenuIcon.stopScreenShare:
        return Icons.stop_screen_share;
      case ParticipantMenuIcon.robot:
        return Icons.smart_toy_outlined;
      case ParticipantMenuIcon.keyboardVoice:
        return Icons.keyboard_voice_outlined;
      case ParticipantMenuIcon.cameraAlt:
        return Icons.camera_alt_outlined;
      case ParticipantMenuIcon.chatBubble:
        return Icons.chat_bubble_outline_rounded;
      case ParticipantMenuIcon.taskAlt:
        return Icons.task_alt_outlined;
      case ParticipantMenuIcon.adminPanel:
        return Icons.admin_panel_settings_outlined;
      case ParticipantMenuIcon.rename:
        return Icons.drive_file_rename_outline;
      case ParticipantMenuIcon.personRemove:
        return Icons.person_remove;
      case ParticipantMenuIcon.personRemoveAlt:
        return Icons.person_remove_alt_1_outlined;
      case ParticipantMenuIcon.personOff:
        return Icons.person_off_outlined;
    }
  }

  IconData _chatMessageMenuIconData(ChatMessageMenuIcon icon) {
    switch (icon) {
      case ChatMessageMenuIcon.copy:
        return Icons.content_copy_outlined;
      case ChatMessageMenuIcon.recall:
        return Icons.undo_outlined;
    }
  }

  PopupMenuEntry<String> _participantMenuActionItemRefined({
    required String value,
    required String title,
    required IconData icon,
    String? subtitle,
    bool enabled = true,
    bool danger = false,
  }) {
    final iconColor = danger ? _palette.danger : _palette.primaryStrong;
    final iconBg = danger ? _palette.dangerSurface : _palette.primarySoft;
    final titleColor = danger ? _palette.danger : _palette.textPrimary;
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      height: subtitle == null ? 44 : 54,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: Opacity(
        opacity: enabled ? 1 : 0.56,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 14, color: iconColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: _palette.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<PopupMenuEntry<String>> _participantMenuItemsRefined(
    ParticipantRowData row,
    bool isSelf,
  ) {
    final specs = buildParticipantMenuSpecs(
      ParticipantMenuBuilderInput(
        isSelf: isSelf,
        isModerator: _isModerator,
        hasPrivateMeetingApiScope: _hasPrivateMeetingApiScope,
        userId: row.userId,
        isRealtimeBot: row.isRealtimeBot,
        roleKey: row.roleKey,
        micEnabled: row.micEnabled,
        cameraEnabled: row.cameraEnabled,
        mutedByHost: row.mutedByHost,
        videoBlockedByHost: row.videoBlockedByHost,
        allowSelfUnmute: row.allowSelfUnmute,
        allowMemberVideo: row.allowMemberVideo,
        allowChat: row.allowChat,
        allowScreenShare: row.allowScreenShare,
        micRequestPending: row.micRequestPending,
        videoRequestPending: row.videoRequestPending,
        screenShareRequestPending: row.screenShareRequestPending,
        isScreenSharing: row.isScreenSharing,
      ),
    );
    return specs.map((spec) {
      switch (spec.kind) {
        case ParticipantMenuEntryKind.section:
          return _participantMenuSectionRefined(spec.title);
        case ParticipantMenuEntryKind.divider:
          return const PopupMenuDivider(height: 8);
        case ParticipantMenuEntryKind.action:
          return _participantMenuActionItemRefined(
            value: spec.value!,
            title: spec.title,
            icon: _participantMenuIconData(spec.icon!),
            subtitle: spec.subtitle,
            enabled: spec.enabled,
            danger: spec.danger,
          );
      }
    }).toList();
  }

  Future<void> _quickReviewWaitingEntry(
    WaitingRoomEntry entry,
    String status,
  ) async {
    try {
      await _reviewWaitingRoomEntry(entry.userId, status);
      await _loadWaitingRoomEntriesForModerator(silent: true);
      _setStatus(
        status == 'approved'
            ? '已通过 ${entry.displayName} 的入会申请'
            : '已拒绝 ${entry.displayName} 的入会申请',
      );
    } catch (e) {
      _setStatus('等候室审核失败：${_friendlyError(e)}');
    }
  }

  Future<void> _copyChatMessage(ChatMessage message) async {
    final text = message.content.trim();
    if (text.isEmpty) {
      _setStatus('当前消息为空，无法复制');
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: message.content));
      _setStatus('消息已复制');
    } catch (_) {
      _setStatus('复制失败，请检查浏览器剪贴板权限');
    }
  }

  PopupMenuEntry<String> _chatMessageMenuActionItemRefined({
    required String value,
    required String title,
    required IconData icon,
    String? subtitle,
    bool enabled = true,
    bool danger = false,
  }) {
    final iconColor = danger ? _palette.danger : _palette.primaryStrong;
    final iconBg = danger ? _palette.dangerSurface : _palette.primarySoft;
    final titleColor = danger ? _palette.danger : _palette.textPrimary;
    return PopupMenuItem<String>(
      value: value,
      enabled: enabled,
      height: subtitle == null ? 44 : 54,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: Opacity(
        opacity: enabled ? 1 : 0.56,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 14, color: iconColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: _palette.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isTileFullscreenActive) {
      return _buildFullscreenTileScaffold();
    }
    final useMobileLayout = widget.preferMobileLayout ||
        DeviceProfile.isPhoneWidth(context, breakpoint: 880);
    if (useMobileLayout) {
      return _buildMobileMeetingScaffold();
    }
    return Scaffold(
      body: MeetingSelectableRegion(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [_palette.pageBackground, _palette.primarySoft],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: [
                  _buildDesktopCompactHeader(),
                  if ((_permissionWarning ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _buildPermissionBanner(),
                  ],
                  const SizedBox(height: 10),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return _buildDesktopMeetingContent(constraints);
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildDock(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
