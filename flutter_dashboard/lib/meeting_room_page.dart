import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'device_profile.dart';

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
  String _realtimeBotBaseUrl = 'https://api.openai.com';
  String _realtimeBotModel = 'gpt-realtime';
  String _realtimeBotVoice = 'marin';
  String _realtimeBotDisplayName = '实时语音助手';
  String _realtimeBotIdentity = '';
  bool _realtimeBotApiKeySet = false;
  int? _realtimeBotUserId;
  String _currentUserRole = '';
  String _resolvedMeetingRef = '';
  bool _recordingActive = false;
  bool _recordingUploading = false;
  DateTime? _recordingStartedAt;
  String _activeEgressId = '';
  html.MediaRecorder? _meetingRecorder;
  html.MediaStream? _meetingRecordingStream;
  final List<html.Blob> _meetingRecordingChunks = <html.Blob>[];
  StreamSubscription<html.BlobEvent>? _meetingRecordingDataSubscription;
  StreamSubscription<html.Event>? _meetingRecordingStopSubscription;
  Completer<void>? _meetingRecordingFinalizeCompleter;

  bool _echoCancellation = true;
  bool _noiseSuppression = true;
  bool _autoGainControl = true;

  String? _selectedAudioInputId;
  String? _selectedAudioOutputId;
  String? _selectedVideoInputId;
  List<lk.MediaDevice> _audioInputs = const [];
  List<lk.MediaDevice> _audioOutputs = const [];
  List<lk.MediaDevice> _videoInputs = const [];
  _CameraResolutionPreset _cameraResolutionPreset =
      _CameraResolutionPreset.p2160;
  _ScreenShareResolutionPreset _screenShareResolutionPreset =
      _ScreenShareResolutionPreset.p2160;
  bool _adaptiveStreamEnabled = false;
  bool _dynacastEnabled = false;
  _RemoteShareViewMode _remoteCameraViewMode = _RemoteShareViewMode.original;
  _RemoteShareViewMode _remoteShareViewMode = _RemoteShareViewMode.original;
  final Map<String, TransformationController> _tileZoomControllers =
      <String, TransformationController>{};
  bool _desktopParticipantsCollapsed = false;
  bool _desktopChatCollapsed = false;

  static const double _minTileZoomScale = 1.0;
  static const double _maxTileZoomScale = 5.0;
  static const double _desktopSideRailWidth = 56.0;
  static const Duration _desktopPanelAnimationDuration =
      Duration(milliseconds: 180);
  static const int _cameraTrackSourceValue = 1;
  static const int _microphoneTrackSourceValue = 2;
  static const int _screenShareTrackSourceValue = 3;
  static const int _screenShareAudioTrackSourceValue = 4;
  static const html.EventStreamProvider<html.BlobEvent>
      _mediaRecorderDataAvailableEvent =
      html.EventStreamProvider<html.BlobEvent>('dataavailable');
  static const html.EventStreamProvider<html.Event> _mediaRecorderStopEvent =
      html.EventStreamProvider<html.Event>('stop');
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
  static const Duration _permissionRequestTimeout = Duration(seconds: 8);
  static const Duration _roomConnectTimeout = Duration(seconds: 20);

  String? _spotlightIdentity;
  String? _fullscreenIdentity;

  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _roomListener;
  Timer? _meetingElapsedTimer;
  Timer? _chatTimer;
  Timer? _memberTimer;
  Timer? _waitingRoomTimer;
  Timer? _recordingStatusTimer;
  StreamSubscription<html.Event>? _fullscreenSubscription;
  int _latestMessageId = 0;
  final List<_ChatMessage> _messages = [];
  final Set<int> _playedRealtimeBotAudioMessageIds = <int>{};
  final Set<int> _recallingMessageIds = <int>{};
  Map<int, _MeetingMemberProfile> _memberProfiles = {};
  final Map<String, String> _runtimeDisplayNamesByIdentity = <String, String>{};
  final Map<String, int> _guestDisplayNameVersionsByIdentity = <String, int>{};
  bool _updatingLocalRequestMetadata = false;
  String? _lastHandledHostForceMicNonce;
  String? _lastHandledHostForceVideoNonce;
  bool _handlingHostForceOpen = false;
  List<_WaitingRoomEntry> _waitingRoomEntries = const [];
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

  _MeetingMemberProfile? get _localMemberProfile {
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

  String _meetingControlsApiPath() => '${_privateMeetingApiBase()}/controls';
  String _meetingAiControlsApiPath() => '${_privateMeetingApiBase()}/ai-controls';
  String _meetingAiControlsTestApiPath() =>
      '${_privateMeetingApiBase()}/ai-controls/test';

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
    _chatController.dispose();
    _chatScrollController.dispose();
    _meetingElapsedTimer?.cancel();
    _meetingElapsedTimer = null;
    _stopChatPolling();
    _stopMemberPolling();
    _stopWaitingRoomPolling();
    _fullscreenSubscription?.cancel();
    _disposeAllZoomControllers();
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
    if (!_isModerator || _isShareEntry) {
      _setStatus('仅主持人或联席主持人可导出入会名单');
      return;
    }
    final rows = _collectParticipantRows();
    if (rows.isEmpty) {
      _setStatus('当前暂无在会成员可导出');
      return;
    }
    final sortedRows = List<_ParticipantRowData>.from(rows)
      ..sort((a, b) {
        final typeOrder =
            (a.userId == null ? 1 : 0).compareTo(b.userId == null ? 1 : 0);
        if (typeOrder != 0) return typeOrder;
        final roleOrder = _participantRoleWeight(a.roleKey)
            .compareTo(_participantRoleWeight(b.roleKey));
        if (roleOrder != 0) return roleOrder;
        return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
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
    final buffer = StringBuffer()
      ..writeln(headers.map(_csvEscape).join(','));
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
        backgroundColor: const Color(0xFFFCFDFF),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFD6E4FF)),
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
                color: const Color(0xFFEAF1FF),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(
                Icons.share_outlined,
                size: 16,
                color: Color(0xFF175CD3),
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              '会议分享',
              style: TextStyle(
                color: Color(0xFF101828),
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
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFDDE6FF)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '邀请链接',
                            style: TextStyle(
                              color: Color(0xFF101828),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF175CD3),
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
                      style: const TextStyle(
                        color: Color(0xFF344054),
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
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFDDE6FF)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '完整会议信息',
                            style: TextStyle(
                              color: Color(0xFF101828),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF175CD3),
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
                      style: const TextStyle(
                        color: Color(0xFF344054),
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

  _MeetingMemberProfile? _profileForIdentity(String identity) {
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

  _MeetingMemberProfile _memberProfileWithDisplayName(
    _MeetingMemberProfile profile,
    String displayName, {
    int? displayNameVersion,
  }) {
    return _MeetingMemberProfile(
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
          _memberProfiles = <int, _MeetingMemberProfile>{
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

  _RequestPendingFlags _requestPendingFlagsForParticipant(
      lk.Participant participant) {
    final payload = _participantMetadataAsMap(participant);
    return _RequestPendingFlags(
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
    if (error is _ApiException) {
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
    if (error is! _ApiException) return false;
    final status = (error.payload?['waiting_room_status'] ?? '').toString();
    return error.statusCode == 403 && status == 'pending';
  }

  bool _isWaitingRoomRejectedError(Object error) {
    if (error is! _ApiException) return false;
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
    if (!_connected) return const Color(0xFF98A2B3);
    final quality = _room?.localParticipant?.connectionQuality;
    switch (quality) {
      case lk.ConnectionQuality.excellent:
      case lk.ConnectionQuality.good:
        return const Color(0xFF6CE9A6);
      case lk.ConnectionQuality.poor:
        return const Color(0xFFFDB022);
      case lk.ConnectionQuality.lost:
        return const Color(0xFFF97066);
      case lk.ConnectionQuality.unknown:
      case null:
        return const Color(0xFFD1E0FF);
    }
  }

  Widget _buildTopMetricChip({
    required IconData icon,
    required String text,
    Color accent = const Color(0xFFD1E0FF),
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFCCDBFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: accent),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              color: Color(0xFF175CD3),
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
      case _CameraResolutionPreset.p720:
        return lk.VideoParametersPresets.h720_169;
      case _CameraResolutionPreset.p1080:
        return lk.VideoParametersPresets.h1080_169;
      case _CameraResolutionPreset.p1440:
        return lk.VideoParametersPresets.h1440_169;
      case _CameraResolutionPreset.p2160:
        return lk.VideoParametersPresets.h2160_169;
    }
  }

  lk.VideoParameters _screenShareVideoParameters() {
    switch (_screenShareResolutionPreset) {
      case _ScreenShareResolutionPreset.p720:
        return lk.VideoParametersPresets.screenShareH720FPS15;
      case _ScreenShareResolutionPreset.p1080:
        return lk.VideoParametersPresets.screenShareH1080FPS15;
      case _ScreenShareResolutionPreset.p1440:
        return lk.VideoParametersPresets.screenShareH1440FPS30;
      case _ScreenShareResolutionPreset.p2160:
        return lk.VideoParametersPresets.screenShareH2160FPS30;
    }
  }

  String _cameraResolutionLabel(_CameraResolutionPreset preset) {
    switch (preset) {
      case _CameraResolutionPreset.p720:
        return '1280 x 720';
      case _CameraResolutionPreset.p1080:
        return '1920 x 1080';
      case _CameraResolutionPreset.p1440:
        return '2560 x 1440';
      case _CameraResolutionPreset.p2160:
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

  String _screenShareResolutionLabel(_ScreenShareResolutionPreset preset) {
    switch (preset) {
      case _ScreenShareResolutionPreset.p720:
        return '1280 x 720';
      case _ScreenShareResolutionPreset.p1080:
        return '1920 x 1080';
      case _ScreenShareResolutionPreset.p1440:
        return '2560 x 1440';
      case _ScreenShareResolutionPreset.p2160:
        return '3840 x 2160';
    }
  }

  String _remoteShareViewModeLabel(_RemoteShareViewMode mode) {
    if (mode == _RemoteShareViewMode.original) {
      return '保持原比例';
    }
    if (mode == _RemoteShareViewMode.stretch) {
      return '拉伸';
    }
    switch (mode) {
      case _RemoteShareViewMode.original:
        return '保持原比例';
      case _RemoteShareViewMode.stretch:
      // ignore: unreachable_switch_default
      default:
        return '拉伸';
    }
  }

  lk.VideoViewFit _videoFitForTile(_ParticipantTileData tile) {
    final mode =
        tile.isScreenShare ? _remoteShareViewMode : _remoteCameraViewMode;
    switch (mode) {
      case _RemoteShareViewMode.original:
        return lk.VideoViewFit.contain;
      case _RemoteShareViewMode.stretch:
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
    var testing = false;
    var testResult = '';

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

              Future<void> runMicTest() async {
                setDialogState(() {
                  testing = true;
                  testResult = '';
                });
                final ok = await _requestBrowserPermissionWithRetry(
                  audio: true,
                  video: false,
                );
                if (!mounted) return;
                setDialogState(() {
                  testing = false;
                  testResult = ok ? '麦克风测试成功' : '麦克风权限被禁用';
                });
              }

              Future<void> runCameraTest() async {
                setDialogState(() {
                  testing = true;
                  testResult = '';
                });
                final ok = await _requestBrowserPermissionWithRetry(
                  audio: false,
                  video: true,
                );
                if (!mounted) return;
                setDialogState(() {
                  testing = false;
                  testResult = ok ? '摄像头测试成功' : '摄像头权限被禁用';
                });
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
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: testing ? null : runMicTest,
                                icon: const Icon(Icons.mic),
                                label: const Text('测试麦克风'),
                              ),
                              OutlinedButton.icon(
                                onPressed: testing ? null : runCameraTest,
                                icon: const Icon(Icons.videocam),
                                label: const Text('测试摄像头'),
                              ),
                            ],
                          ),
                          if (testResult.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: testResult.contains('成功')
                                    ? const Color(0xFFECFDF3)
                                    : const Color(0xFFFEF3F2),
                                border: Border.all(
                                  color: testResult.contains('成功')
                                      ? const Color(0xFFABEFC6)
                                      : const Color(0xFFFDA29B),
                                ),
                              ),
                              child: Text(
                                testResult,
                                style: TextStyle(
                                  color: testResult.contains('成功')
                                      ? const Color(0xFF067647)
                                      : const Color(0xFFB42318),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          const Divider(height: 1),
                          const SizedBox(height: 14),
                          const Text('画面与传输',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<_CameraResolutionPreset>(
                            value: cameraResolutionPreset,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '本机摄像头分辨率'),
                            items: _CameraResolutionPreset.values
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
                          DropdownButtonFormField<_ScreenShareResolutionPreset>(
                            value: screenShareResolutionPreset,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '本机共享分辨率'),
                            items: _ScreenShareResolutionPreset.values
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
                          DropdownButtonFormField<_RemoteShareViewMode>(
                            value: remoteCameraViewMode,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '观看成员摄像头画面'),
                            items: _RemoteShareViewMode.values
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
                          DropdownButtonFormField<_RemoteShareViewMode>(
                            value: remoteShareViewMode,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '观看成员共享画面'),
                            items: _RemoteShareViewMode.values
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
                          const Text(
                            '拉伸会铺满窗口并可能裁剪边缘；保持原比例会完整显示并可能留黑边。',
                            style: TextStyle(
                                color: Color(0xFF667085), fontSize: 12.5),
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
                                color: const Color(0xFFFFFAEB),
                                border:
                                    Border.all(color: const Color(0xFFFEC84B)),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    size: 18,
                                    color: Color(0xFFB54708),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      permissionWarning,
                                      style: const TextStyle(
                                        color: Color(0xFFB54708),
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

  Future<void> _bootstrap() async {
    try {
      if (_requiresAuth) {
        await _ensureJwt(force: true);
        await _loadProfile();
      } else {
        await _loadOptionalProfile();
      }
      await _loadMediaDevices();
      await _loadMeetingInfo();
      await _loadMeetingMembers();
      if (_requiresAuth && _isModerator) {
        await _loadWaitingRoomEntriesForModerator(silent: true);
      }
      if (_defaultDisplayName.trim().isEmpty) {
        final guestName = '访客-${DateTime.now().millisecondsSinceEpoch % 10000}';
        if (mounted) {
          setState(() {
            _defaultDisplayName = guestName;
            _meetingDisplayName = guestName;
          });
        }
      }
      if (widget.autoJoin && mounted) {
        await _openJoinSetupDialog();
      }
    } catch (e) {
      _setStatus('初始化失败：${_friendlyError(e)}');
    }
  }

  Future<String> _ensureJwt({bool force = false}) async {
    if (!force && _accessToken.isNotEmpty) return _accessToken;
    final res = await http.get(_uri('/auth/jwt'));
    if (res.statusCode >= 400) {
      throw Exception('登录会话已失效，请重新登录');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    _accessToken = (data['access_token'] ?? '').toString();
    if (_accessToken.isEmpty) {
      throw Exception('无法获取访问令牌');
    }
    return _accessToken;
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool requireAuth = true,
    bool retry = true,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    var hasAuthHeader = false;
    if (requireAuth) {
      final token = await _ensureJwt();
      headers['Authorization'] = 'Bearer $token';
      hasAuthHeader = true;
    } else if (_accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_accessToken';
      hasAuthHeader = true;
    }
    final uri = _uri(path);
    http.Response res;
    switch (method) {
      case 'POST':
        res = await http.post(uri,
            headers: headers, body: jsonEncode(body ?? {}));
        break;
      case 'PATCH':
        res = await http.patch(uri,
            headers: headers, body: jsonEncode(body ?? {}));
        break;
      case 'DELETE':
        res = await http.delete(uri, headers: headers);
        break;
      default:
        res = await http.get(uri, headers: headers);
        break;
    }
    if ((requireAuth || hasAuthHeader) && res.statusCode == 401 && retry) {
      await _ensureJwt(force: true);
      return _request(
        method,
        path,
        body: body,
        requireAuth: requireAuth,
        retry: false,
      );
    }
    return res;
  }

  Future<dynamic> _jsonOrThrow(http.Response response) async {
    if (response.statusCode >= 400) {
      String detail = '请求失败（${response.statusCode}）';
      Map<String, dynamic>? payloadMap;
      if (response.body.isNotEmpty) {
        try {
          final payload = jsonDecode(response.body);
          if (payload is Map<String, dynamic> && payload['detail'] != null) {
            payloadMap = payload;
            detail = payload['detail'].toString();
          } else {
            detail = response.body;
          }
        } catch (_) {
          detail = response.body;
        }
      }
      throw _ApiException(
        statusCode: response.statusCode,
        detail: detail,
        payload: payloadMap,
      );
    }
    if (response.body.isEmpty) return {};
    return jsonDecode(response.body);
  }

  Future<void> _loadProfile() async {
    final res = await _request('GET', '/api/profile');
    final data = await _jsonOrThrow(res) as Map<String, dynamic>;
    final defaultDisplayName =
        (data['default_display_name'] ?? '').toString().trim();
    final username = (data['username'] ?? '').toString().trim();
    final nextDisplayName =
        defaultDisplayName.isEmpty ? username : defaultDisplayName;
    if (!mounted) return;
    setState(() {
      _defaultDisplayName = nextDisplayName;
      _meetingDisplayName = _meetingDisplayName.trim().isEmpty
          ? nextDisplayName
          : _meetingDisplayName.trim();
      _profileAvatarUrl = (data['avatar_url'] ?? '').toString();
    });
  }

  Future<void> _loadOptionalProfile() async {
    try {
      await _ensureJwt(force: true);
      await _loadProfile();
    } catch (_) {
      // Unauthenticated share-entry is expected.
    }
  }

  Future<void> _loadMeetingMembers() async {
    try {
      final res = await _request(
        'GET',
        _meetingMembersApiPath(),
        requireAuth: _requiresAuth,
      );
      final list = await _jsonOrThrow(res) as List<dynamic>;
      final next = <int, _MeetingMemberProfile>{};
      for (final row in list) {
        final item =
            _MeetingMemberProfile.fromJson(row as Map<String, dynamic>);
        next[item.userId] = item;
      }
      if (!mounted) return;
      setState(() {
        final merged = <int, _MeetingMemberProfile>{...next};
        for (final entry in _memberProfiles.entries) {
          final incoming = merged[entry.key];
          if (incoming == null ||
              incoming.displayNameVersion < entry.value.displayNameVersion) {
            merged[entry.key] = entry.value;
          }
        }
        _memberProfiles = merged;
        final room = _room;
        if (room != null) {
          final local = room.localParticipant;
          if (local != null) {
            final localUserIdFromIdentity = _userIdFromIdentity(local.identity);
            if (localUserIdFromIdentity != null) {
              final profile = merged[localUserIdFromIdentity];
              if (profile != null && profile.displayName.trim().isNotEmpty) {
                _runtimeDisplayNamesByIdentity[local.identity] =
                    profile.displayName.trim();
              }
            }
          }
          for (final participant in room.remoteParticipants.values) {
            final userIdFromIdentity =
                _userIdFromIdentity(participant.identity);
            if (userIdFromIdentity == null) continue;
            final profile = merged[userIdFromIdentity];
            if (profile == null || profile.displayName.trim().isEmpty) continue;
            _runtimeDisplayNamesByIdentity[participant.identity] =
                profile.displayName.trim();
          }
        }
        final localUserId = _localUserId;
        if (localUserId != null && merged.containsKey(localUserId)) {
          final localProfile = merged[localUserId]!;
          _currentUserRole = localProfile.role;
          final syncedDisplayName = localProfile.displayName.trim();
          if (syncedDisplayName.isNotEmpty &&
              (_meetingDisplayName.trim().isEmpty ||
                  _meetingDisplayName.trim() != syncedDisplayName)) {
            _meetingDisplayName = syncedDisplayName;
          }
        }
      });
    } catch (_) {}
  }

  void _startMemberPolling() {
    _memberTimer?.cancel();
    _memberTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) {
        unawaited(_loadMeetingMembers());
        if (_requiresAuth) {
          unawaited(_loadMeetingInfo());
          if (_isModerator) {
            unawaited(_loadWaitingRoomEntriesForModerator(silent: true));
          }
        }
      },
    );
  }

  void _stopMemberPolling() {
    _memberTimer?.cancel();
    _memberTimer = null;
  }

  void _startWaitingRoomPolling() {
    _waitingRoomTimer?.cancel();
    _waitingRoomTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_pollWaitingRoomAdmission()),
    );
  }

  void _stopWaitingRoomPolling() {
    _waitingRoomTimer?.cancel();
    _waitingRoomTimer = null;
  }

  Future<void> _updateMyMeetingDisplayName(String displayName) async {
    final name = displayName.trim();
    if (name.isEmpty) return;
    final localParticipant = _room?.localParticipant;
    final localIdentity = localParticipant?.identity;
    final localUserId = _localUserId;
    if (_hasPrivateMeetingApiScope) {
      var expectedVersion = _localMemberProfile?.displayNameVersion;
      if (expectedVersion == null) {
        await _loadMeetingMembers();
        expectedVersion = _localMemberProfile?.displayNameVersion;
      }
      try {
        final res = await _request(
          'PATCH',
          '${_privateMeetingApiBase()}/my-display-name',
          body: {
            'display_name': name,
            if (expectedVersion != null)
              'expected_display_name_version': expectedVersion,
          },
        );
        final payload = await _jsonOrThrow(res);
        final resolvedName = payload is Map<String, dynamic>
            ? (payload['display_name'] ?? name).toString().trim()
            : name;
        final nextName = resolvedName.isEmpty ? name : resolvedName;
        final resolvedVersion = payload is Map<String, dynamic>
            ? _intFromJson(
                payload['display_name_version'],
                expectedVersion ?? 1,
              )
            : (expectedVersion ?? 1);
        if (localIdentity != null) {
          _applyIdentityDisplayNameLocally(
            localIdentity,
            nextName,
            userId: localUserId,
            displayNameVersion: resolvedVersion > 0 ? resolvedVersion : null,
          );
        } else if (mounted) {
          setState(() {
            _meetingDisplayName = nextName;
          });
        }
      } on _ApiException catch (e) {
        if (e.statusCode == 409 && e.payload != null) {
          final payload = e.payload!;
          final currentName =
              (payload['current_display_name'] ?? '').toString().trim();
          final currentVersion = _intFromJson(
            payload['current_display_name_version'],
            expectedVersion ?? 1,
          );
          if (currentName.isNotEmpty) {
            if (localIdentity != null) {
              _applyIdentityDisplayNameLocally(
                localIdentity,
                currentName,
                userId: localUserId,
                displayNameVersion: currentVersion > 0 ? currentVersion : null,
              );
            } else if (mounted) {
              setState(() {
                _meetingDisplayName = currentName;
              });
            }
          }
        }
        rethrow;
      }
      return;
    }

    if (localParticipant != null) {
      try {
        await localParticipant.setName(name);
      } catch (_) {
        // Keep UI state update even if SDK rename fails.
      }
    }
    if (localIdentity != null) {
      _applyIdentityDisplayNameLocally(
        localIdentity,
        name,
        userId: localUserId,
      );
      return;
    }
    if (mounted) {
      setState(() {
        _meetingDisplayName = name;
      });
    }
  }

  Future<void> _refreshModerationState({bool reloadMessages = false}) async {
    await _loadMeetingInfo();
    await _loadMeetingMembers();
    if (_requiresAuth && _isModerator) {
      await _loadWaitingRoomEntriesForModerator(silent: true);
    }
    if (_allowChat) {
      if (!_connected) return;
      if (reloadMessages) {
        await _loadMessages();
      }
      _startChatPolling();
    } else {
      _stopChatPolling();
      if (mounted) {
        setState(() {
          _messages.clear();
          _latestMessageId = 0;
        });
      }
    }
  }

  Future<void> _patchMeetingControls(Map<String, dynamic> payload) async {
    if (_isShareEntry || payload.isEmpty) return;
    final res = await _request(
      'PATCH',
      _meetingControlsApiPath(),
      body: payload,
    );
    await _jsonOrThrow(res);
    await _refreshModerationState(reloadMessages: true);
  }

  Future<void> _patchMeetingAiControls(Map<String, dynamic> payload) async {
    if (_isShareEntry || payload.isEmpty) return;
    final res = await _request(
      'PATCH',
      _meetingAiControlsApiPath(),
      body: payload,
    );
    await _jsonOrThrow(res);
    await _refreshModerationState(reloadMessages: true);
  }

  Future<Map<String, dynamic>> _testMeetingAiConnectivity({
    required String baseUrl,
    required String model,
    required String voice,
    String apiKey = '',
    String? prompt,
  }) async {
    final key = apiKey.trim();
    final res = await _request(
      'POST',
      _meetingAiControlsTestApiPath(),
      body: <String, dynamic>{
        'base_url': baseUrl,
        'model': model,
        'voice': voice,
        if (key.isNotEmpty) 'api_key': key,
        if ((prompt ?? '').trim().isNotEmpty) 'prompt': prompt!.trim(),
      },
    );
    final payload = await _jsonOrThrow(res) as Map<String, dynamic>;
    return payload;
  }

  Future<void> _muteAllMembers() async {
    if (_isShareEntry) return;
    final res = await _request(
      'POST',
      _meetingMuteAllApiPath(),
      body: const <String, dynamic>{},
    );
    final data = await _jsonOrThrow(res) as Map<String, dynamic>;
    await _refreshModerationState();
    _setStatus('已执行全员静音：${(data['muted_count'] ?? 0).toString()} 人');
  }

  Future<void> _updateMemberMute(int userId, bool muted) async {
    final res = await _request(
      'PATCH',
      _meetingMemberActionApiPath(userId, 'mute'),
      body: {'muted': muted},
    );
    await _jsonOrThrow(res);
    await _loadMeetingMembers();
  }

  Future<void> _updateParticipantMuteByIdentity(
      String identity, bool muted) async {
    final res = await _request(
      'PATCH',
      _meetingParticipantActionApiPath(identity, 'mute'),
      body: {'muted': muted},
    );
    await _jsonOrThrow(res);
  }

  Future<void> _updateMemberVideo(int userId, bool disabled) async {
    final res = await _request(
      'PATCH',
      _meetingMemberActionApiPath(userId, 'video'),
      body: {'disabled': disabled},
    );
    await _jsonOrThrow(res);
    await _loadMeetingMembers();
  }

  Future<void> _updateParticipantVideoByIdentity(
      String identity, bool disabled) async {
    final res = await _request(
      'PATCH',
      _meetingParticipantActionApiPath(identity, 'video'),
      body: {'disabled': disabled},
    );
    await _jsonOrThrow(res);
  }

  Future<void> _updateParticipantMicPermissionByIdentity(
    String identity,
    bool allowed,
  ) async {
    final res = await _request(
      'PATCH',
      _meetingParticipantActionApiPath(identity, 'mic-permission'),
      body: {'allowed': allowed},
    );
    await _jsonOrThrow(res);
  }

  Future<void> _updateParticipantVideoPermissionByIdentity(
    String identity,
    bool allowed,
  ) async {
    final res = await _request(
      'PATCH',
      _meetingParticipantActionApiPath(identity, 'video-permission'),
      body: {'allowed': allowed},
    );
    await _jsonOrThrow(res);
  }

  Future<void> _updateParticipantChatPermissionByIdentity(
    String identity,
    bool allowed,
  ) async {
    final res = await _request(
      'PATCH',
      _meetingParticipantActionApiPath(identity, 'chat-permission'),
      body: {'allowed': allowed},
    );
    await _jsonOrThrow(res);
  }

  Future<void> _updateParticipantScreenSharePermissionByIdentity(
    String identity,
    bool allowed,
  ) async {
    final res = await _request(
      'PATCH',
      _meetingParticipantActionApiPath(identity, 'screen-share-permission'),
      body: {'allowed': allowed},
    );
    await _jsonOrThrow(res);
  }

  Future<void> _updateMemberMicPermission(int userId, bool allowed) async {
    final res = await _request(
      'PATCH',
      _meetingMemberActionApiPath(userId, 'mic-permission'),
      body: {'allowed': allowed},
    );
    await _jsonOrThrow(res);
    await _loadMeetingMembers();
  }

  Future<void> _updateMemberVideoPermission(int userId, bool allowed) async {
    final res = await _request(
      'PATCH',
      _meetingMemberActionApiPath(userId, 'video-permission'),
      body: {'allowed': allowed},
    );
    await _jsonOrThrow(res);
    await _loadMeetingMembers();
  }

  Future<void> _updateMemberChatPermission(int userId, bool allowed) async {
    final res = await _request(
      'PATCH',
      _meetingMemberActionApiPath(userId, 'chat-permission'),
      body: {'allowed': allowed},
    );
    await _jsonOrThrow(res);
    await _loadMeetingMembers();
  }

  Future<void> _updateMemberScreenSharePermission(
    int userId,
    bool allowed,
  ) async {
    final res = await _request(
      'PATCH',
      _meetingMemberActionApiPath(userId, 'screen-share-permission'),
      body: {'allowed': allowed},
    );
    await _jsonOrThrow(res);
    await _loadMeetingMembers();
  }

  Future<void> _stopMemberShare(int userId) async {
    final res = await _request(
      'POST',
      _meetingMemberActionApiPath(userId, 'stop-share'),
      body: const <String, dynamic>{},
    );
    await _jsonOrThrow(res);
  }

  Future<void> _stopParticipantShareByIdentity(String identity) async {
    final res = await _request(
      'POST',
      _meetingParticipantActionApiPath(identity, 'stop-share'),
      body: const <String, dynamic>{},
    );
    await _jsonOrThrow(res);
  }

  Future<void> _updateMemberRole(int userId, String role) async {
    final res = await _request(
      'PATCH',
      _meetingMemberActionApiPath(userId, 'role'),
      body: {'role': role},
    );
    await _jsonOrThrow(res);
    await _refreshModerationState();
  }

  Future<void> _renameMember(int userId, String displayName) async {
    final nextName = displayName.trim();
    if (nextName.isEmpty) {
      throw Exception('显示名称不能为空');
    }
    var expectedVersion = _memberProfiles[userId]?.displayNameVersion;
    if (expectedVersion == null) {
      await _loadMeetingMembers();
      expectedVersion = _memberProfiles[userId]?.displayNameVersion;
    }
    try {
      final res = await _request(
        'PATCH',
        _meetingMemberActionApiPath(userId, 'display-name'),
        body: {
          'display_name': nextName,
          if (expectedVersion != null)
            'expected_display_name_version': expectedVersion,
        },
      );
      final payload = await _jsonOrThrow(res);
      if (payload is Map<String, dynamic>) {
        final profile = _MeetingMemberProfile.fromJson(payload);
        if (mounted) {
          setState(() {
            _memberProfiles = <int, _MeetingMemberProfile>{
              ..._memberProfiles,
              profile.userId: profile,
            };
            final identity = _connectedIdentityForUserId(profile.userId);
            if (identity != null && profile.displayName.trim().isNotEmpty) {
              _runtimeDisplayNamesByIdentity[identity] =
                  profile.displayName.trim();
            }
            final localUserId = _localUserId;
            if (localUserId != null &&
                localUserId == profile.userId &&
                profile.displayName.trim().isNotEmpty) {
              _meetingDisplayName = profile.displayName.trim();
            }
          });
        }
        return;
      }
      if (mounted) {
        final profile = _memberProfiles[userId];
        if (profile != null) {
          setState(() {
            _memberProfiles = <int, _MeetingMemberProfile>{
              ..._memberProfiles,
              userId: _memberProfileWithDisplayName(profile, nextName),
            };
            final identity = _connectedIdentityForUserId(userId);
            if (identity != null) {
              _runtimeDisplayNamesByIdentity[identity] = nextName;
            }
          });
        }
      }
    } on _ApiException catch (e) {
      if (e.statusCode == 409 && e.payload != null && mounted) {
        final payload = e.payload!;
        final currentName =
            (payload['current_display_name'] ?? '').toString().trim();
        final currentVersion = _intFromJson(
            payload['current_display_name_version'], expectedVersion ?? 1);
        final profile = _memberProfiles[userId];
        if (profile != null && currentName.isNotEmpty) {
          setState(() {
            _memberProfiles = <int, _MeetingMemberProfile>{
              ..._memberProfiles,
              userId: _memberProfileWithDisplayName(
                profile,
                currentName,
                displayNameVersion: currentVersion > 0 ? currentVersion : null,
              ),
            };
            final identity = _connectedIdentityForUserId(userId);
            if (identity != null) {
              _runtimeDisplayNamesByIdentity[identity] = currentName;
            }
          });
        }
      }
      rethrow;
    }
  }

  Future<void> _renameParticipantByIdentity(
      String identity, String displayName) async {
    final nextName = displayName.trim();
    if (nextName.isEmpty) {
      throw Exception('显示名称不能为空');
    }
    var expectedVersion = _guestDisplayNameVersionsByIdentity[identity];
    if (expectedVersion == null) {
      try {
        final detailRes = await _request(
          'GET',
          _meetingParticipantItemApiPath(identity),
        );
        final detailPayload = await _jsonOrThrow(detailRes);
        if (detailPayload is Map<String, dynamic>) {
          final currentVersion =
              _intFromJson(detailPayload['display_name_version'], 0);
          if (currentVersion > 0) {
            expectedVersion = currentVersion;
          }
          final currentName =
              (detailPayload['display_name'] ?? '').toString().trim();
          if (currentName.isNotEmpty && currentName != nextName) {
            _applyIdentityDisplayNameLocally(identity, currentName);
          }
        }
      } catch (_) {
        // Keep rename attempt even when version prefetch is unavailable.
      }
    }
    try {
      final res = await _request(
        'PATCH',
        _meetingParticipantActionApiPath(identity, 'display-name'),
        body: {
          'display_name': nextName,
          if (expectedVersion != null)
            'expected_display_name_version': expectedVersion,
        },
      );
      final payload = await _jsonOrThrow(res);
      final nextDisplayName = payload is Map<String, dynamic>
          ? (payload['display_name'] ?? nextName).toString().trim()
          : nextName;
      final resolvedName = nextDisplayName.isEmpty ? nextName : nextDisplayName;
      final resolvedVersion = payload is Map<String, dynamic>
          ? _intFromJson(
              payload['display_name_version'],
              expectedVersion ?? 1,
            )
          : (expectedVersion ?? 1);
      if (mounted && resolvedVersion > 0) {
        setState(() {
          _guestDisplayNameVersionsByIdentity[identity] = resolvedVersion;
        });
      }
      _applyIdentityDisplayNameLocally(
        identity,
        resolvedName,
      );
    } on _ApiException catch (e) {
      if (e.statusCode == 409 && e.payload != null) {
        final payload = e.payload!;
        final currentName =
            (payload['current_display_name'] ?? '').toString().trim();
        final currentVersion = _intFromJson(
            payload['current_display_name_version'], expectedVersion ?? 1);
        if (mounted && currentVersion > 0) {
          setState(() {
            _guestDisplayNameVersionsByIdentity[identity] = currentVersion;
          });
        }
        if (currentName.isNotEmpty) {
          _applyIdentityDisplayNameLocally(identity, currentName);
        }
      }
      rethrow;
    }
  }

  Future<void> _requestRaiseHand(String requestType) async {
    if (!_hasPrivateMeetingApiScope) return;
    final res = await _request(
      'POST',
      _meetingRaiseHandApiPath(),
      body: {'request': requestType},
    );
    await _jsonOrThrow(res);
    await _loadMeetingMembers();
  }

  Future<void> _removeMember(
    int userId, {
    required bool banAfterRemove,
  }) async {
    final banValue = banAfterRemove ? 'true' : 'false';
    final res = await _request(
      'DELETE',
      '${_privateMeetingApiBase()}/members/$userId?ban=$banValue',
      requireAuth: true,
    );
    await _jsonOrThrow(res);
    await _loadMeetingMembers();
  }

  Future<void> _removeAndBanMember(int userId) async {
    await _removeMember(userId, banAfterRemove: true);
  }

  Future<void> _removeParticipantByIdentity(String identity) async {
    final res = await _request(
      'DELETE',
      _meetingParticipantItemApiPath(identity),
      requireAuth: true,
    );
    await _jsonOrThrow(res);
  }

  Future<void> _hostLeaveWithTransfer(int transferUserId) async {
    final res = await _request(
      'POST',
      _meetingHostLeaveApiPath(),
      body: {'transfer_user_id': transferUserId},
      requireAuth: true,
    );
    await _jsonOrThrow(res);
  }

  Future<void> _endMeetingForAll() async {
    final res = await _request(
      'DELETE',
      _privateMeetingApiBase(),
      requireAuth: true,
    );
    await _jsonOrThrow(res);
  }

  Future<void> _handleLeaveButtonPressed() async {
    if (!_connected) return;
    if (_isHost && _requiresAuth) {
      await _openHostEndMeetingDialog();
      return;
    }
    await _leaveRoom();
  }

  Future<void> _openHostEndMeetingDialog() async {
    await _loadMeetingMembers();
    if (!mounted) return;

    final localUserId = _localUserId;
    final connectedUserIds = _connectedUserIdsInRoom();
    final candidates = _memberProfiles.values
        .where(
          (row) =>
              row.userId != localUserId &&
              connectedUserIds.contains(row.userId),
        )
        .toList()
      ..sort((a, b) {
        int priority(String role) {
          if (role == 'cohost') return 0;
          if (role == 'participant') return 1;
          return 2;
        }

        final roleCompare = priority(a.role).compareTo(priority(b.role));
        if (roleCompare != 0) return roleCompare;
        return a.displayName.compareTo(b.displayName);
      });

    var leaveAndTransfer = candidates.isNotEmpty;
    int? transferUserId =
        candidates.isNotEmpty ? candidates.first.userId : null;

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: const Text('结束会议'),
                content: SizedBox(
                  width: 520,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RadioListTile<bool>(
                        value: true,
                        groupValue: leaveAndTransfer,
                        onChanged: candidates.isEmpty
                            ? null
                            : (value) => setDialogState(() {
                                  leaveAndTransfer = value ?? true;
                                }),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('离开会议并转交主持人'),
                        subtitle: Text(
                          candidates.isEmpty ? '当前无可转交成员' : '会议继续进行，需要选择新的主持人',
                        ),
                      ),
                      if (leaveAndTransfer && candidates.isNotEmpty)
                        DropdownButtonFormField<int>(
                          value: transferUserId,
                          decoration: const InputDecoration(
                            labelText: '新主持人',
                          ),
                          items: candidates
                              .map(
                                (row) => DropdownMenuItem<int>(
                                  value: row.userId,
                                  child: Text(
                                    '${row.displayName}（${_roleLabel(row.role)}）',
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) =>
                              setDialogState(() => transferUserId = value),
                        ),
                      const SizedBox(height: 8),
                      RadioListTile<bool>(
                        value: false,
                        groupValue: leaveAndTransfer,
                        onChanged: (value) => setDialogState(
                          () => leaveAndTransfer = value ?? false,
                        ),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('全体成员退会并结束会议'),
                        subtitle: const Text('会议将结束，成员全部退会，并从系统删除'),
                      ),
                    ],
                  ),
                ),
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
              );
            },
          ),
        ) ??
        false;

    if (!confirmed) return;
    if (leaveAndTransfer && transferUserId == null) {
      _setStatus('请选择新的主持人');
      return;
    }

    try {
      if (leaveAndTransfer) {
        await _hostLeaveWithTransfer(transferUserId!);
        _setStatus('已转交主持人并离开会议');
      } else {
        await _endMeetingForAll();
        _setStatus('会议已结束，所有成员已退会');
      }
      await _leaveRoom();
    } catch (e) {
      _setStatus('结束会议失败：${_friendlyError(e)}');
    }
  }

  Future<List<_WaitingRoomEntry>> _loadWaitingRoomEntries() async {
    final res = await _request(
      'GET',
      _meetingWaitingRoomApiPath(),
    );
    final list = await _jsonOrThrow(res) as List<dynamic>;
    return list
        .map((item) => _WaitingRoomEntry.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> _loadWaitingRoomEntriesForModerator(
      {bool silent = false}) async {
    if (_isShareEntry || !_requiresAuth || !_isModerator) {
      if (!mounted) return;
      if (_waitingRoomEntries.isNotEmpty) {
        setState(() {
          _waitingRoomEntries = const [];
          _lastWaitingRoomCount = 0;
          _hasNewWaitingRoomNotice = false;
        });
      }
      return;
    }
    try {
      final rows = await _loadWaitingRoomEntries();
      if (!mounted) return;
      final previous = _lastWaitingRoomCount;
      final nextCount = rows.length;
      final hasNew = nextCount > previous;
      setState(() {
        _waitingRoomEntries = rows;
        _lastWaitingRoomCount = nextCount;
        if (nextCount == 0) {
          _hasNewWaitingRoomNotice = false;
        } else if (hasNew) {
          _hasNewWaitingRoomNotice = true;
        }
      });
      if (hasNew) {
        _setStatus('等候室有 $nextCount 人等待审核');
      }
    } catch (e) {
      if (!silent) {
        _setStatus('读取等候室失败：${_friendlyError(e)}');
      }
    }
  }

  Future<void> _reviewWaitingRoomEntry(int userId, String status) async {
    final res = await _request(
      'PATCH',
      '${_meetingWaitingRoomApiPath()}/$userId',
      body: {'status': status},
    );
    await _jsonOrThrow(res);
    await _refreshModerationState();
  }

  Future<void> _openRenameMemberDialog(_ParticipantRowData row) async {
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
    if (!_isModerator || _isShareEntry) return;
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
    var waitingEntries = <_WaitingRoomEntry>[];
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
                        style: const TextStyle(
                          color: Color(0xFFB42318),
                          fontSize: 12.5,
                        ),
                      ),
                    if (waitingEntries.isEmpty)
                      const Text(
                        '暂无待审核成员',
                        style: TextStyle(color: Color(0xFF667085)),
                      )
                    else
                      ...waitingEntries.map(
                        (entry) => Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFFDDE6FF)),
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
    if (!_isModerator || _isShareEntry) return;
    var enabled = _realtimeBotEnabled;
    var muted = _realtimeBotMuted;
    var apiKeySet = _realtimeBotApiKeySet;
    final baseUrlController = TextEditingController(text: _realtimeBotBaseUrl);
    final modelController = TextEditingController(text: _realtimeBotModel);
    final voiceController = TextEditingController(text: _realtimeBotVoice);
    final displayNameController =
        TextEditingController(text: _realtimeBotDisplayName);
    final apiKeyController = TextEditingController();
    var busy = false;
    String? errorMessage;
    String? testMessage;

    Future<void> saveConfig(StateSetter setDialogState) async {
      if (busy) return;
      final baseUrl = baseUrlController.text.trim();
      final model = modelController.text.trim();
      final voice = voiceController.text.trim();
      final displayName = displayNameController.text.trim();
      final keyInput = apiKeyController.text.trim();
      if (baseUrl.isEmpty || model.isEmpty || voice.isEmpty || displayName.isEmpty) {
        setDialogState(() => errorMessage = '实时语音配置项不能为空');
        return;
      }
      if (enabled && !apiKeySet && keyInput.isEmpty) {
        setDialogState(() => errorMessage = '启用实时语音前请填写 API Key');
        return;
      }
      final payload = <String, dynamic>{
        'realtime_bot_enabled': enabled,
        'realtime_bot_muted': muted,
        'realtime_bot_base_url': baseUrl,
        'realtime_bot_model': model,
        'realtime_bot_voice': voice,
        'realtime_bot_display_name': displayName,
      };
      if (keyInput.isNotEmpty) {
        payload['realtime_bot_api_key'] = keyInput;
      }
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
          apiKeySet = _realtimeBotApiKeySet;
          baseUrlController.text = _realtimeBotBaseUrl;
          modelController.text = _realtimeBotModel;
          voiceController.text = _realtimeBotVoice;
          displayNameController.text = _realtimeBotDisplayName;
          apiKeyController.clear();
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
      final model = modelController.text.trim();
      final voice = voiceController.text.trim();
      final keyInput = apiKeyController.text.trim();
      if (baseUrl.isEmpty || model.isEmpty || voice.isEmpty) {
        setDialogState(() => errorMessage = '请先填写 Base URL、Model 和 Voice');
        return;
      }
      if (!apiKeySet && keyInput.isEmpty) {
        setDialogState(() => errorMessage = '测试连通性需要 API Key（可先填后测）');
        return;
      }
      setDialogState(() {
        busy = true;
        errorMessage = null;
        testMessage = null;
      });
      try {
        final result = await _testMeetingAiConnectivity(
          baseUrl: baseUrl,
          model: model,
          voice: voice,
          apiKey: keyInput,
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
                        onChanged: busy ? null : (v) => setDialogState(() => enabled = v),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('启用实时语音成员'),
                      ),
                      SwitchListTile.adaptive(
                        value: muted,
                        onChanged: busy ? null : (v) => setDialogState(() => muted = v),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('静音实时语音成员'),
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
                      const SizedBox(height: 8),
                      TextField(
                        controller: baseUrlController,
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: 'Base URL',
                          hintText: 'https://api.openai.com',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: modelController,
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: 'Model',
                          hintText: 'gpt-realtime',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: voiceController,
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
                          labelText: apiKeySet ? 'API Key（留空表示沿用已保存）' : 'API Key',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: busy ? null : () => unawaited(saveConfig(setDialogState)),
                            icon: const Icon(Icons.save_outlined),
                            label: const Text('保存配置'),
                          ),
                          OutlinedButton.icon(
                            onPressed: busy ? null : () => unawaited(testConnectivity(setDialogState)),
                            icon: const Icon(Icons.network_check_outlined),
                            label: const Text('测试连通性'),
                          ),
                        ],
                      ),
                      if ((testMessage ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          testMessage!,
                          style: const TextStyle(
                            color: Color(0xFF067647),
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                      if ((errorMessage ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          errorMessage!,
                          style: const TextStyle(
                            color: Color(0xFFB42318),
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
      modelController.dispose();
      voiceController.dispose();
      displayNameController.dispose();
      apiKeyController.dispose();
    }
  }

  Future<void> _loadMeetingInfo() async {
    final res = await _request(
      'GET',
      _meetingInfoApiPath(),
      requireAuth: _requiresAuth,
    );
    final data = await _jsonOrThrow(res) as Map<String, dynamic>;
    if (!mounted) return;
    final nextShareUrl = (data['share_url'] ?? '').toString().trim();
    final waitingRoomEnabled =
        _boolFromJson(data['waiting_room_enabled'], false);
    final maxParticipants =
        _intFromJson(data['max_participants'], _maxParticipants);
    final actualStartedAt = _dateTimeFromJson(data['actual_started_at']);
    final muteOnEntry = _boolFromJson(data['mute_on_entry'], false);
    final allowGuestLinkJoin =
        _boolFromJson(data['allow_guest_link_join'], true);
    final allowRecording = _boolFromJson(data['allow_recording'], true);
    final allowScreenShare = _boolFromJson(data['allow_screen_share'], true);
    final allowChat = _boolFromJson(data['allow_chat'], true);
    final allowSelfUnmute = _boolFromJson(data['allow_self_unmute'], true);
    final allowMemberVideo = _boolFromJson(data['allow_member_video'], true);
    final realtimeBotEnabled = _boolFromJson(data['realtime_bot_enabled'], false);
    final realtimeBotMuted = _boolFromJson(data['realtime_bot_muted'], false);
    final realtimeBotBaseUrl =
        (data['realtime_bot_base_url'] ?? 'https://api.openai.com')
            .toString()
            .trim();
    final realtimeBotModel =
        (data['realtime_bot_model'] ?? 'gpt-realtime').toString().trim();
    final realtimeBotVoice =
        (data['realtime_bot_voice'] ?? 'marin').toString().trim();
    final realtimeBotDisplayName =
        (data['realtime_bot_display_name'] ?? '实时语音助手')
            .toString()
            .trim();
    final realtimeBotApiKeySet =
        _boolFromJson(data['realtime_bot_api_key_set'], false);
    final realtimeBotUserId = _intFromJson(data['realtime_bot_user_id'], 0);
    final realtimeBotIdentity =
        (data['realtime_bot_identity'] ?? '').toString().trim();
    final currentUserRole = (data['current_user_role'] ?? '').toString();
    final meetingRefFromApi = (data['meeting_ref'] ?? '').toString().trim();
    setState(() {
      _meetingTitle = (data['title'] ?? '会议').toString();
      _roomNumber = (data['room_name'] ?? '-').toString();
      _shareUrl = nextShareUrl;
      _waitingRoomEnabled = waitingRoomEnabled;
      _maxParticipants = maxParticipants <= 0 ? 100 : maxParticipants;
      _actualStartedAt = actualStartedAt;
      _elapsedNow = DateTime.now();
      _muteOnEntry = muteOnEntry;
      _allowGuestLinkJoin = allowGuestLinkJoin;
      _allowRecording = allowRecording;
      _allowScreenShare = allowScreenShare;
      _allowChat = allowChat;
      _allowSelfUnmute = allowSelfUnmute;
      _allowMemberVideo = allowMemberVideo;
      _realtimeBotEnabled = realtimeBotEnabled;
      _realtimeBotMuted = realtimeBotMuted;
      _realtimeBotBaseUrl = realtimeBotBaseUrl.isEmpty
          ? 'https://api.openai.com'
          : realtimeBotBaseUrl;
      _realtimeBotModel =
          realtimeBotModel.isEmpty ? 'gpt-realtime' : realtimeBotModel;
      _realtimeBotVoice = realtimeBotVoice.isEmpty ? 'marin' : realtimeBotVoice;
      _realtimeBotDisplayName = realtimeBotDisplayName.isEmpty
          ? '实时语音助手'
          : realtimeBotDisplayName;
      _realtimeBotIdentity = realtimeBotIdentity;
      _realtimeBotApiKeySet = realtimeBotApiKeySet;
      _realtimeBotUserId = realtimeBotUserId > 0 ? realtimeBotUserId : null;
      _currentUserRole = currentUserRole;
      if (meetingRefFromApi.isNotEmpty) {
        _resolvedMeetingRef = meetingRefFromApi;
      }
    });
    if (!allowRecording && _recordingActive) {
      unawaited(_stopMeetingRecording());
    }
    _refreshElapsedTicker();
    if (_connected &&
        _isModerator &&
        _hasPrivateMeetingApiScope &&
        allowRecording) {
      unawaited(_syncMeetingRecordingEgressStatus(silent: true));
    } else if (!_recordingActive) {
      _stopRecordingStatusPolling();
    }
  }

  Future<void> _loadMessages() async {
    final localProfile = _localMemberProfile;
    final canChat = _isModerator || (localProfile?.allowChat ?? _allowChat);
    if (!canChat) {
      if (!mounted) return;
      setState(() {
        _messages.clear();
        _latestMessageId = 0;
        _playedRealtimeBotAudioMessageIds.clear();
        _recallingMessageIds.clear();
      });
      return;
    }
    final res = await _request(
      'GET',
      _meetingMessagesApiPath(limit: 100),
      requireAuth: _requiresAuth,
    );
    final list = await _jsonOrThrow(res) as List<dynamic>;
    final rows = list
        .map((e) => _ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
    if (!mounted) return;
    final previousLatest = _latestMessageId;
    setState(() {
      _messages
        ..clear()
        ..addAll(rows);
      _latestMessageId = _messages.isEmpty ? 0 : _messages.last.id;
      _playedRealtimeBotAudioMessageIds.removeWhere(
        (messageId) => !_messages.any((message) => message.id == messageId),
      );
      _recallingMessageIds.removeWhere(
        (messageId) => !_messages.any((message) => message.id == messageId),
      );
    });
    _playRealtimeBotAudioForNewMessages(rows, previousLatest);
    if (_latestMessageId > previousLatest) {
      _scrollChatToBottom();
    }
  }

  Future<void> _pollMessages() async {
    if (!_connected || !_allowChat) return;
    try {
      final res = await _request(
        'GET',
        _meetingMessagesApiPath(limit: 100),
        requireAuth: _requiresAuth,
      );
      final list = await _jsonOrThrow(res) as List<dynamic>;
      final rows = list
          .map((e) => _ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted || _sameMessageSnapshot(rows)) return;
      final previousLatest = _latestMessageId;
      setState(() {
        _messages
          ..clear()
          ..addAll(rows);
        _latestMessageId = _messages.isEmpty ? 0 : _messages.last.id;
        _playedRealtimeBotAudioMessageIds.removeWhere(
          (messageId) => !_messages.any((message) => message.id == messageId),
        );
        _recallingMessageIds.removeWhere(
          (messageId) => !_messages.any((message) => message.id == messageId),
        );
      });
      _playRealtimeBotAudioForNewMessages(rows, previousLatest);
      if (_latestMessageId > previousLatest) {
        _scrollChatToBottom();
      }
    } catch (_) {}
  }

  bool _sameMessageSnapshot(List<_ChatMessage> rows) {
    if (rows.length != _messages.length) return false;
    for (var i = 0; i < rows.length; i++) {
      final current = _messages[i];
      final next = rows[i];
      if (current.id != next.id) return false;
      if (current.senderUserId != next.senderUserId) return false;
      if (current.senderDisplayName != next.senderDisplayName) return false;
      if (current.content != next.content) return false;
      if (current.isRealtimeBot != next.isRealtimeBot) return false;
      if (current.audioMimeType != next.audioMimeType) return false;
      if (current.audioBase64 != next.audioBase64) return false;
      if (current.createdAt != next.createdAt) return false;
    }
    return true;
  }

  bool _isRealtimeBotMutedForPlayback() {
    if (_realtimeBotMuted) return true;
    final botUserId = _realtimeBotUserId;
    if (botUserId == null) return false;
    final profile = _memberProfiles[botUserId];
    if (profile == null) return false;
    return profile.mutedByHost;
  }

  bool _isRealtimeBotMessage(_ChatMessage message) {
    if (message.isRealtimeBot) return true;
    final botUserId = _realtimeBotUserId;
    if (botUserId == null) return false;
    return message.senderUserId == botUserId;
  }

  Future<void> _playRealtimeBotAudio(_ChatMessage message) async {
    if (!_isRealtimeBotMessage(message)) return;
    if (_isRealtimeBotMutedForPlayback()) return;
    if (_playedRealtimeBotAudioMessageIds.contains(message.id)) return;
    final audioBase64 = message.audioBase64.trim();
    if (audioBase64.isEmpty) return;
    try {
      final bytes = base64Decode(audioBase64);
      final mimeType =
          message.audioMimeType.trim().isEmpty ? 'audio/wav' : message.audioMimeType.trim();
      final blob = html.Blob(<dynamic>[bytes], mimeType);
      final url = html.Url.createObjectUrlFromBlob(blob);
      final audio = html.AudioElement(url)
        ..autoplay = true
        ..preload = 'auto';
      audio.onEnded.first.then((_) {
        html.Url.revokeObjectUrl(url);
        audio.remove();
      });
      audio.onError.first.then((_) {
        html.Url.revokeObjectUrl(url);
        audio.remove();
      });
      await audio.play();
      _playedRealtimeBotAudioMessageIds.add(message.id);
    } catch (_) {}
  }

  void _playRealtimeBotAudioForNewMessages(List<_ChatMessage> rows, int previousLatest) {
    if (previousLatest <= 0) return;
    if (_isRealtimeBotMutedForPlayback()) return;
    for (final message in rows) {
      if (message.id <= previousLatest) continue;
      if (!_isRealtimeBotMessage(message)) continue;
      if (message.audioBase64.trim().isEmpty) continue;
      unawaited(_playRealtimeBotAudio(message));
    }
  }

  void _startChatPolling() {
    _stopChatPolling();
    _chatTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_pollMessages());
    });
  }

  void _stopChatPolling() {
    _chatTimer?.cancel();
    _chatTimer = null;
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScrollController.hasClients) return;
      _chatScrollController.animateTo(
        _chatScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<_JoinTokenPayload> _fetchJoinToken() async {
    if (_isShareEntry && _accessToken.isEmpty) {
      try {
        await _ensureJwt(force: true);
      } catch (_) {
        // Keep guest-link fallback if user is not signed in.
      }
    }
    final shouldRequireAuth =
        _requiresAuth || (_isShareEntry && _accessToken.isNotEmpty);
    final displayName = _meetingDisplayName.trim();
    final res = await _request(
      'POST',
      _meetingJoinTokenApiPath(),
      body: <String, dynamic>{
        if (displayName.isNotEmpty) 'display_name': displayName,
        if (_meetingPassword.trim().isNotEmpty)
          'meeting_password': _meetingPassword.trim(),
      },
      requireAuth: shouldRequireAuth,
    );
    final data = await _jsonOrThrow(res) as Map<String, dynamic>;
    return _JoinTokenPayload.fromJson(data);
  }

  void _onRoomUpdated() {
    final room = _room;
    final local = room?.localParticipant;
    final nextRuntimeNames = <String, String>{};
    final previousRuntimeNames = <String, String>{
      ..._runtimeDisplayNamesByIdentity,
    };
    final connectedIdentities = <String>{};
    if (room != null) {
      if (local != null) {
        connectedIdentities.add(local.identity);
        final localProfile = _profileForIdentity(local.identity);
        final cachedLocalName =
            (previousRuntimeNames[local.identity] ?? '').trim();
        final localName = _meetingDisplayName.trim().isNotEmpty
            ? _meetingDisplayName.trim()
            : (localProfile?.displayName.trim().isNotEmpty ?? false)
                ? localProfile!.displayName.trim()
                : cachedLocalName.isNotEmpty
                    ? cachedLocalName
                    : local.name.trim();
        if (localName.isNotEmpty) {
          nextRuntimeNames[local.identity] = localName;
        }
      }
      for (final participant in room.remoteParticipants.values) {
        connectedIdentities.add(participant.identity);
        final profile = _profileForIdentity(participant.identity);
        final cachedParticipantName =
            (previousRuntimeNames[participant.identity] ?? '').trim();
        final participantName =
            (profile?.displayName.trim().isNotEmpty ?? false)
                ? profile!.displayName.trim()
                : cachedParticipantName.isNotEmpty
                    ? cachedParticipantName
                    : participant.name.trim();
        if (participantName.isNotEmpty) {
          nextRuntimeNames[participant.identity] = participantName;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      if (local != null) {
        _micEnabled = local.isMicrophoneEnabled();
        _cameraEnabled = local.isCameraEnabled();
        _screenShareEnabled = local.isScreenShareEnabled();
        _screenShareAudioEnabled = local.isScreenShareAudioEnabled();
      }
      _runtimeDisplayNamesByIdentity.removeWhere(
        (identity, _) => !connectedIdentities.contains(identity),
      );
      _runtimeDisplayNamesByIdentity.addAll(nextRuntimeNames);
      _guestDisplayNameVersionsByIdentity.removeWhere(
        (identity, _) => !connectedIdentities.contains(identity),
      );
      if (local != null) {
        final localName =
            _runtimeDisplayNamesByIdentity[local.identity]?.trim();
        if (localName != null && localName.isNotEmpty) {
          _meetingDisplayName = localName;
        }
      }
    });
    unawaited(_reconcileLocalRequestMetadataWithPermissions());
    unawaited(_handleHostForceOpenCommands());
  }

  Future<void> _joinRoom({bool fromWaitingPoll = false}) async {
    if (_connected || _joining) return;
    setState(() {
      _joining = true;
      _status = fromWaitingPoll ? '等待主持人准入中...' : '正在连接会议...';
    });
    try {
      var deniedPermissions = <String>[];
      if (!fromWaitingPoll) {
        deniedPermissions = await _ensurePermissionsForJoin(
          enableMic: _micEnabled,
          enableCamera: _cameraEnabled,
        );
      }
      if (!fromWaitingPoll && deniedPermissions.isNotEmpty) {
        _setStatus('部分权限受限：${deniedPermissions.join('、')}');
        await _showPermissionDeniedDialog(deniedPermissions);
      }
      final token = await _fetchJoinToken();
      final room = lk.Room(
        roomOptions: lk.RoomOptions(
          adaptiveStream: _adaptiveStreamEnabled,
          dynacast: _dynacastEnabled,
          defaultAudioCaptureOptions: _buildAudioCaptureOptions(),
          defaultCameraCaptureOptions: _buildCameraCaptureOptions(),
          defaultScreenShareCaptureOptions: _buildScreenShareCaptureOptions(),
          defaultAudioOutputOptions:
              lk.AudioOutputOptions(deviceId: _selectedAudioOutputId),
        ),
      );

      room.addListener(_onRoomUpdated);
      final listener = room.createListener()
        ..on<lk.RoomDisconnectedEvent>((event) async {
          if (!mounted) return;
          _setStatus('连接已断开');
          setState(() {
            _connected = false;
            _joining = false;
            _waitingForAdmission = false;
            _screenShareEnabled = false;
            _screenShareAudioEnabled = false;
            _runtimeDisplayNamesByIdentity.clear();
            _guestDisplayNameVersionsByIdentity.clear();
            _lastHandledHostForceMicNonce = null;
            _lastHandledHostForceVideoNonce = null;
          });
          _stopChatPolling();
          _stopMemberPolling();
          _stopWaitingRoomPolling();
          _stopRecordingStatusPolling();
        })
        ..on<lk.ParticipantEvent>((event) {
          _onRoomUpdated();
        })
        ..on<lk.ParticipantMetadataUpdatedEvent>((event) {
          _onRoomUpdated();
        })
        ..on<lk.ParticipantNameUpdatedEvent>((event) {
          _onRoomUpdated();
        })
        ..on<lk.TrackSubscribedEvent>((event) {
          _onRoomUpdated();
        })
        ..on<lk.TrackUnsubscribedEvent>((event) {
          _onRoomUpdated();
        })
        ..on<lk.AudioPlaybackStatusChanged>((event) async {
          if (!room.canPlaybackAudio) {
            await room.startAudio();
          }
        });

      await room
          .connect(
            token.livekitUrl,
            token.token,
            connectOptions: const lk.ConnectOptions(
              autoSubscribe: true,
            ),
          )
          .timeout(_roomConnectTimeout);
      var nextMicEnabled = _micEnabled && _micPermissionGranted;
      if (token.muteOnEntry && !_isModerator) {
        nextMicEnabled = false;
      }
      try {
        await room.localParticipant?.setMicrophoneEnabled(
          nextMicEnabled,
          audioCaptureOptions: _buildAudioCaptureOptions(),
        );
      } catch (_) {
        nextMicEnabled = false;
        try {
          await room.localParticipant?.setMicrophoneEnabled(
            false,
            audioCaptureOptions: _buildAudioCaptureOptions(),
          );
        } catch (_) {}
      }

      var nextCameraEnabled = _cameraEnabled && _cameraPermissionGranted;
      try {
        await room.localParticipant?.setCameraEnabled(
          nextCameraEnabled,
          cameraCaptureOptions: _buildCameraCaptureOptions(),
        );
      } catch (_) {
        nextCameraEnabled = false;
        try {
          await room.localParticipant?.setCameraEnabled(
            false,
            cameraCaptureOptions: _buildCameraCaptureOptions(),
          );
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _room = room;
        _roomListener = listener;
        _connected = true;
        _joining = false;
        _waitingForAdmission = false;
        if (token.meetingRef.isNotEmpty) {
          _resolvedMeetingRef = token.meetingRef;
        }
        _roomNumber = token.roomName;
        _status = '已加入会议';
        _waitingRoomEnabled = token.waitingRoomEnabled;
        _maxParticipants = token.maxParticipants <= 0
            ? _maxParticipants
            : token.maxParticipants;
        _actualStartedAt = token.actualStartedAt ?? _actualStartedAt;
        _elapsedNow = DateTime.now();
        _muteOnEntry = token.muteOnEntry;
        _allowGuestLinkJoin = token.allowGuestLinkJoin;
        _allowRecording = token.allowRecording;
        _allowScreenShare = token.allowScreenShare;
        _allowChat = token.allowChat;
        _allowSelfUnmute = token.allowSelfUnmute;
        _allowMemberVideo = token.allowMemberVideo;
        _micEnabled = nextMicEnabled;
        _cameraEnabled = nextCameraEnabled;
        if (!token.canPublish) {
          _micEnabled = false;
          _cameraEnabled = false;
        }
        if (deniedPermissions.isEmpty) {
          _permissionWarning = null;
        }
      });
      _refreshElapsedTicker();
      _stopWaitingRoomPolling();
      _onRoomUpdated();
      await _applyMediaSettingsToRoom(republishIfEnabled: false);
      await _loadMeetingMembers();
      if (_isModerator) {
        await _loadWaitingRoomEntriesForModerator(silent: true);
      }
      await _loadMessages();
      if (_allowChat) {
        _startChatPolling();
      } else {
        _stopChatPolling();
      }
      _startMemberPolling();
      if (_isModerator && _hasPrivateMeetingApiScope) {
        await _syncMeetingRecordingEgressStatus(silent: true);
      } else {
        _stopRecordingStatusPolling();
      }
    } catch (e) {
      if (_isWaitingRoomPendingError(e)) {
        if (mounted) {
          setState(() {
            _joining = false;
            _waitingForAdmission = true;
            _status = '已进入等候室，等待主持人准入...';
          });
        }
        if (!fromWaitingPoll) {
          _startWaitingRoomPolling();
        }
        return;
      }
      if (_isWaitingRoomRejectedError(e)) {
        _stopWaitingRoomPolling();
        if (mounted) {
          setState(() {
            _joining = false;
            _waitingForAdmission = false;
            _status = '等候室申请被拒绝';
          });
        }
        return;
      }
      final message = e is TimeoutException
          ? 'Joining meeting timed out. Check network and browser media permissions, then retry.'
          : _friendlyError(e);
      _setStatus('加入会议失败：$message');
      if (_isPermissionErrorText(message)) {
        final deniedPermissions = await _ensurePermissionsForJoin(
          enableMic: _micEnabled,
          enableCamera: _cameraEnabled,
        );
        if (deniedPermissions.isEmpty) {
          _setStatus('设备权限已恢复，请重新点击“加入会议”');
        } else {
          await _showPermissionDeniedDialog(deniedPermissions);
        }
      }
      if (mounted) {
        setState(() => _joining = false);
      }
    }
  }

  Future<void> _pollWaitingRoomAdmission() async {
    if (!_waitingForAdmission || _connected || _joining) return;
    try {
      await _joinRoom(fromWaitingPoll: true);
    } catch (_) {}
  }

  Future<void> _disposeRoom() async {
    final room = _room;
    final listener = _roomListener;
    if (room == null) return;
    room.removeListener(_onRoomUpdated);
    _room = null;
    _roomListener = null;
    try {
      await room.disconnect();
    } catch (_) {}
    try {
      await listener?.dispose();
    } catch (_) {}
    try {
      await room.dispose();
    } catch (_) {}
  }

  Future<void> _leaveRoom() async {
    _setStatus('正在离开会议...');
    if (_recordingActive) {
      await _stopMeetingRecording();
    }
    _stopRecordingStatusPolling();
    _stopChatPolling();
    _stopMemberPolling();
    _stopWaitingRoomPolling();
    await _disposeRoom();
    if (!mounted) return;
    setState(() {
      _connected = false;
      _joining = false;
      _waitingForAdmission = false;
      _micEnabled = true;
      _cameraEnabled = true;
      _screenShareEnabled = false;
      _screenShareAudioEnabled = false;
      _runtimeDisplayNamesByIdentity.clear();
      _guestDisplayNameVersionsByIdentity.clear();
      _lastHandledHostForceMicNonce = null;
      _lastHandledHostForceVideoNonce = null;
      _status = '正在返回会议控制台...';
    });
    html.window.location.assign('/dashboard');
  }

  Future<void> _toggleMic() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    final next = !_micEnabled;
    final canSelfUnmute = _localCanSelfUnmute;
    if (next && !canSelfUnmute) {
      try {
        final submitted = await _submitPermissionRequest('mic');
        _setStatus(submitted ? '当前无开麦权限，已提交开麦申请' : '开麦申请已提交，等待主持人批准');
      } catch (e) {
        _setStatus('当前无开麦权限，提交申请失败：${_friendlyError(e)}');
      }
      return;
    }
    try {
      if (next && !_micPermissionGranted) {
        final granted =
            await _requestBrowserPermissionWithRetry(audio: true, video: false);
        if (!granted) {
          _setStatus('麦克风权限被禁用');
          await _showPermissionDeniedDialog(const ['麦克风']);
          return;
        }
        if (mounted) {
          setState(() {
            _micPermissionGranted = true;
            _permissionWarning = null;
          });
        }
      }
      await local.setMicrophoneEnabled(
        next,
        audioCaptureOptions: _buildAudioCaptureOptions(),
      );
      if (!mounted) return;
      setState(() => _micEnabled = next);
    } catch (e) {
      _setStatus('麦克风切换失败：${_friendlyError(e)}');
    }
  }

  Future<void> _toggleCamera() async {
    final local = _room?.localParticipant;
    if (local == null) return;
    final next = !_cameraEnabled;
    final canOpenVideo = _localCanMemberVideo;
    if (next && !canOpenVideo) {
      try {
        final submitted = await _submitPermissionRequest('video');
        _setStatus(submitted ? '当前无开视频权限，已提交视频申请' : '视频申请已提交，等待主持人批准');
      } catch (e) {
        _setStatus('当前无开视频权限，提交申请失败：${_friendlyError(e)}');
      }
      return;
    }
    try {
      if (next && !_cameraPermissionGranted) {
        final granted =
            await _requestBrowserPermissionWithRetry(audio: false, video: true);
        if (!granted) {
          _setStatus('摄像头权限被禁用');
          await _showPermissionDeniedDialog(const ['摄像头']);
          return;
        }
        if (mounted) {
          setState(() {
            _cameraPermissionGranted = true;
            _permissionWarning = null;
          });
        }
      }
      await local.setCameraEnabled(
        next,
        cameraCaptureOptions: _buildCameraCaptureOptions(),
      );
      if (!mounted) return;
      setState(() => _cameraEnabled = next);
    } catch (e) {
      _setStatus('摄像头切换失败：${_friendlyError(e)}');
    }
  }

  Future<bool?> _openScreenShareAudioOptionDialog() async {
    var shareWithAudio = _shareScreenWithAudioPreference;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('共享屏幕'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('开始共享前，可选择是否同步扬声器声音。'),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  value: shareWithAudio,
                  onChanged: (value) =>
                      setDialogState(() => shareWithAudio = value),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('同步扬声器声音'),
                  subtitle: const Text('开启后，参会成员可听到你设备播放的系统声音。'),
                ),
                const SizedBox(height: 6),
                const Text(
                  '说明：部分浏览器或共享模式可能不支持系统声音。',
                  style: TextStyle(color: Color(0xFF667085), fontSize: 12.5),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, shareWithAudio),
              child: const Text('开始共享'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleScreenShare() async {
    final canShareScreen = _localCanScreenShare;
    if (!canShareScreen) {
      try {
        final submitted = await _submitPermissionRequest('screen_share');
        _setStatus(
          submitted ? '当前无屏幕共享权限，已提交共享申请' : '共享申请已提交，等待主持人批准',
        );
      } catch (e) {
        _setStatus('当前无屏幕共享权限，提交申请失败：${_friendlyError(e)}');
      }
      return;
    }
    final local = _room?.localParticipant;
    if (local == null) return;
    final next = !_screenShareEnabled;
    if (next) {
      if (!mounted) return;
      final shareWithAudio = await _openScreenShareAudioOptionDialog();
      if (shareWithAudio == null) {
        return;
      }
      try {
        await local.setScreenShareEnabled(
          true,
          screenShareCaptureOptions: _buildScreenShareCaptureOptions(
            captureScreenAudio: shareWithAudio,
          ),
        );
        if (!mounted) return;
        setState(() {
          _screenShareEnabled = true;
          _screenShareAudioEnabled = shareWithAudio;
          _shareScreenWithAudioPreference = shareWithAudio;
        });
        _setStatus(
          shareWithAudio ? '已开始共享屏幕（含扬声器声音）' : '已开始共享屏幕',
        );
      } catch (e) {
        if (shareWithAudio) {
          try {
            await local.setScreenShareEnabled(
              true,
              screenShareCaptureOptions: _buildScreenShareCaptureOptions(
                captureScreenAudio: false,
              ),
            );
            if (!mounted) return;
            setState(() {
              _screenShareEnabled = true;
              _screenShareAudioEnabled = false;
              _shareScreenWithAudioPreference = shareWithAudio;
            });
            _setStatus('当前浏览器不支持系统声音共享，已切换为仅共享屏幕画面');
            return;
          } catch (_) {}
        }
        _setStatus('共享切换失败：${_friendlyError(e)}');
      }
      return;
    }
    try {
      await local.setScreenShareEnabled(false);
      if (!mounted) return;
      setState(() {
        _screenShareEnabled = false;
        _screenShareAudioEnabled = false;
      });
      _setStatus('已停止共享屏幕');
    } catch (e) {
      _setStatus('共享切换失败：${_friendlyError(e)}');
    }
  }

  void _startRecordingStatusPolling() {
    if (_recordingStatusTimer != null) return;
    _recordingStatusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_connected || !_isModerator || !_hasPrivateMeetingApiScope) return;
      unawaited(_syncMeetingRecordingEgressStatus(silent: true));
    });
  }

  void _stopRecordingStatusPolling() {
    _recordingStatusTimer?.cancel();
    _recordingStatusTimer = null;
  }

  void _applyMeetingRecordingEgressPayload(
    Map<String, dynamic> payload, {
    bool silent = true,
  }) {
    final active = _boolFromJson(payload['active'], false);
    final startedAt = _dateTimeFromJson(payload['started_at']);
    final egressId = (payload['egress_id'] ?? '').toString().trim();
    final statusKey = (payload['status'] ?? '').toString().trim().toLowerCase();
    final errorText = (payload['error'] ?? '').toString().trim();
    final fileName = (payload['file_name'] ?? '').toString().trim();
    final recording = payload['recording'];

    if (mounted) {
      setState(() {
        _recordingActive = active;
        _recordingStartedAt = startedAt;
        _activeEgressId = active ? egressId : '';
      });
    } else {
      _recordingActive = active;
      _recordingStartedAt = startedAt;
      _activeEgressId = active ? egressId : '';
    }

    if (active) {
      _startRecordingStatusPolling();
      return;
    }
    _stopRecordingStatusPolling();

    if (silent) return;
    if (statusKey == 'complete') {
      var savedName = fileName;
      if (savedName.isEmpty && recording is Map<String, dynamic>) {
        savedName = (recording['file_name'] ?? '').toString().trim();
      }
      if (savedName.isEmpty) {
        _setStatus('会议录制已完成并保存');
      } else {
        _setStatus('会议录制已保存：$savedName');
      }
      return;
    }
    if (errorText.isNotEmpty) {
      _setStatus('会议录制失败：$errorText');
      return;
    }
    if (statusKey == 'idle') {
      _setStatus('当前没有进行中的会议录制');
      return;
    }
    _setStatus('会议录制已停止');
  }

  Future<void> _syncMeetingRecordingEgressStatus({
    bool silent = false,
    int waitSeconds = 0,
  }) async {
    if (!_hasPrivateMeetingApiScope || !_isModerator) return;
    final safeWait = waitSeconds.clamp(0, 30);
    final path = safeWait > 0
        ? '${_meetingRecordingEgressApiPath()}?wait_seconds=$safeWait'
        : _meetingRecordingEgressApiPath();
    try {
      final res = await _request('GET', path);
      final payload = await _jsonOrThrow(res);
      if (payload is! Map<String, dynamic>) return;
      _applyMeetingRecordingEgressPayload(payload, silent: silent);
    } catch (e) {
      if (!silent) {
        _setStatus('获取录制状态失败：${_friendlyError(e)}');
      }
    }
  }

  String _recordingExtensionFromMime(String mimeType) {
    final lower = mimeType.toLowerCase();
    if (lower.contains('mp4')) return '.mp4';
    return '.webm';
  }

  String _pickMeetingRecordingMimeType() {
    return 'video/webm';
  }

  String _buildRecordingFileName(String mimeType) {
    final now = DateTime.now();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${twoDigits(now.month)}${twoDigits(now.day)}_${twoDigits(now.hour)}${twoDigits(now.minute)}${twoDigits(now.second)}';
    return 'meeting_recording_$stamp${_recordingExtensionFromMime(mimeType)}';
  }

  void _disposeMeetingRecorderState({bool clearChunks = false}) {
    _meetingRecordingDataSubscription?.cancel();
    _meetingRecordingDataSubscription = null;
    _meetingRecordingStopSubscription?.cancel();
    _meetingRecordingStopSubscription = null;
    _meetingRecorder = null;
    _meetingRecordingStream = null;
    if (clearChunks) {
      _meetingRecordingChunks.clear();
    }
  }

  Future<Uint8List> _blobToBytes(html.Blob blob) async {
    throw UnsupportedError('Legacy browser recorder path is disabled.');
  }

  Future<http.Response> _uploadMeetingRecordingMultipart({
    required Uint8List bytes,
    required String fileName,
    required int durationSeconds,
    bool retry = true,
  }) async {
    throw UnsupportedError('Legacy browser recorder path is disabled.');
  }

  Future<html.MediaStream> _requestDisplayMediaStream() async {
    final dynamic mediaDevices = html.window.navigator.mediaDevices;
    if (mediaDevices == null) {
      throw Exception('当前浏览器不支持屏幕捕获');
    }
    try {
      final dynamic stream = await mediaDevices.getDisplayMedia(
        <String, dynamic>{
          // 只采集屏幕/标签页及其输出音频，不回退到摄像头和麦克风。
          'video': <String, dynamic>{
            'displaySurface': 'browser',
            'cursor': 'always',
            'frameRate': 30,
          },
          'audio': <String, dynamic>{
            'echoCancellation': false,
            'noiseSuppression': false,
            'autoGainControl': false,
            'suppressLocalAudioPlayback': false,
          },
          'preferCurrentTab': true,
          'selfBrowserSurface': 'include',
          'surfaceSwitching': 'include',
        },
      );
      if (stream is html.MediaStream) {
        final hasAudioTrack = stream.getAudioTracks().isNotEmpty;
        if (!hasAudioTrack) {
          for (final track in stream.getTracks()) {
            try {
              track.stop();
            } catch (_) {}
          }
          throw Exception('未采集到浏览器输出音频。请在共享对话框选择“标签页/窗口”并勾选“共享音频”后重试');
        }
        return stream;
      }
      throw Exception('当前浏览器不支持会议录制');
    } on NoSuchMethodError {
      throw Exception('当前浏览器不支持会议录制');
    } catch (e) {
      throw Exception('无法开始录制：$e');
    }
  }

  Future<void> _handleMeetingRecorderStopped() async {
    final completer = _meetingRecordingFinalizeCompleter;
    final startedAt = _recordingStartedAt;
    final chunks = List<html.Blob>.from(_meetingRecordingChunks);
    final recorderMime = (_meetingRecorder?.mimeType ?? '').trim();
    final mimeType = recorderMime.isNotEmpty
        ? recorderMime
        : _pickMeetingRecordingMimeType();
    try {
      if (chunks.isEmpty) {
        _setStatus('录制已停止，但没有可上传的视频数据');
        return;
      }
      final blob = html.Blob(chunks, mimeType);
      final bytes = await _blobToBytes(blob);
      final duration = startedAt == null
          ? 0
          : DateTime.now()
              .difference(startedAt)
              .inSeconds
              .clamp(0, 864000)
              .toInt();
      final fileName = _buildRecordingFileName(mimeType);
      final response = await _uploadMeetingRecordingMultipart(
        bytes: bytes,
        fileName: fileName,
        durationSeconds: duration,
      );
      final payload = await _jsonOrThrow(response) as Map<String, dynamic>;
      final savedName = (payload['file_name'] ?? fileName).toString();
      _setStatus('会议录制已保存：$savedName');
    } catch (e) {
      _setStatus('会议录制上传失败：${_friendlyError(e)}');
    } finally {
      _meetingRecordingChunks.clear();
      _recordingStartedAt = null;
      _disposeMeetingRecorderState();
      if (mounted) {
        setState(() {
          _recordingUploading = false;
          _recordingActive = false;
        });
      }
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      if (identical(_meetingRecordingFinalizeCompleter, completer)) {
        _meetingRecordingFinalizeCompleter = null;
      }
    }
  }

  Future<void> _startMeetingRecording() async {
    if (_recordingActive || _recordingUploading) return;
    if (!_connected) {
      _setStatus('请先加入会议后再录制');
      return;
    }
    if (!_hasPrivateMeetingApiScope) {
      _setStatus('当前入口无法发起录制，请从控制台进入会议后重试');
      return;
    }
    if (!_isModerator) {
      _setStatus('仅主持人和联席主持人可以录制会议');
      return;
    }
    if (!_allowRecording) {
      _setStatus('当前会议已禁用录制');
      return;
    }

    if (mounted) {
      setState(() {
        _recordingUploading = true;
      });
    }
    try {
      final res = await _request(
        'POST',
        _meetingRecordingEgressStartApiPath(),
        body: {'layout': 'grid'},
      );
      final payload = await _jsonOrThrow(res);
      if (payload is! Map<String, dynamic>) {
        throw Exception('Invalid recording response');
      }
      final active = _boolFromJson(payload['active'], false);
      if (active) {
        _applyMeetingRecordingEgressPayload(payload, silent: true);
        _setStatus('会议录制已开始（LiveKit 云端录制）');
      } else {
        _applyMeetingRecordingEgressPayload(payload, silent: false);
      }
    } catch (e) {
      _setStatus('启动会议录制失败：${_friendlyError(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _recordingUploading = false;
        });
      }
    }
    return;

    if (_recordingActive || _recordingUploading) return;
    if (!_connected) {
      _setStatus('请先加入会议后再录制');
      return;
    }
    if (!_hasPrivateMeetingApiScope) {
      _setStatus('当前入口无法上传录制文件，请从控制台进入会议后再试');
      return;
    }
    if (!_isModerator) {
      _setStatus('仅主持人和联席主持人可以录制会议');
      return;
    }
    if (!_allowRecording) {
      _setStatus('当前会议已禁用录制');
      return;
    }

    try {
      await _ensureJwt();
      final stream = await _requestDisplayMediaStream();
      final mimeType = _pickMeetingRecordingMimeType();
      html.MediaRecorder recorder;
      try {
        recorder = html.MediaRecorder(
          stream,
          <String, dynamic>{'mimeType': mimeType},
        );
      } catch (_) {
        recorder = html.MediaRecorder(stream);
      }

      _meetingRecordingChunks.clear();
      _meetingRecordingStream = stream;
      _meetingRecorder = recorder;
      _meetingRecordingDataSubscription?.cancel();
      _meetingRecordingDataSubscription =
          _mediaRecorderDataAvailableEvent.forTarget(recorder).listen((event) {
        final data = event.data;
        if (data != null && data.size > 0) {
          _meetingRecordingChunks.add(data);
        }
      });
      _meetingRecordingStopSubscription?.cancel();
      _meetingRecordingStopSubscription =
          _mediaRecorderStopEvent.forTarget(recorder).listen((_) {
        unawaited(_handleMeetingRecorderStopped());
      });
      for (final track in stream.getTracks()) {
        track.onEnded.first.then((_) {
          if (_recordingActive) {
            unawaited(_stopMeetingRecording());
          }
        });
      }
      recorder.start(1000);
      if (!mounted) return;
      setState(() {
        _recordingActive = true;
        _recordingUploading = false;
        _recordingStartedAt = DateTime.now();
      });
      _setStatus('会议录制已开始（屏幕画面 + 浏览器音频）');
    } catch (e) {
      _disposeMeetingRecorderState(clearChunks: true);
      _setStatus('启动会议录制失败：${_friendlyError(e)}');
    }
  }

  Future<void> _stopMeetingRecording() async {
    if (_recordingUploading) return;
    if (!_hasPrivateMeetingApiScope || !_isModerator) return;
    if (!_recordingActive && _activeEgressId.trim().isEmpty) {
      await _syncMeetingRecordingEgressStatus(silent: true);
      if (!_recordingActive && _activeEgressId.trim().isEmpty) {
        _setStatus('当前没有进行中的会议录制');
        return;
      }
    }

    if (mounted) {
      setState(() {
        _recordingUploading = true;
      });
    }
    try {
      final res = await _request(
        'POST',
        _meetingRecordingEgressStopApiPath(),
        body: <String, dynamic>{},
      );
      final payload = await _jsonOrThrow(res);
      if (payload is! Map<String, dynamic>) {
        throw Exception('Invalid recording response');
      }
      final active = _boolFromJson(payload['active'], false);
      if (active) {
        _applyMeetingRecordingEgressPayload(payload, silent: true);
        _setStatus('录制停止请求已提交，正在收尾...');
        await _syncMeetingRecordingEgressStatus(silent: false, waitSeconds: 20);
      } else {
        _applyMeetingRecordingEgressPayload(payload, silent: false);
      }
    } catch (e) {
      _setStatus('停止会议录制失败：${_friendlyError(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _recordingUploading = false;
        });
      }
    }
    return;

    if (_recordingUploading) return;
    if (!_recordingActive) return;
    final recorder = _meetingRecorder;
    if (recorder == null) {
      if (mounted) {
        setState(() {
          _recordingActive = false;
          _recordingUploading = false;
        });
      }
      return;
    }

    final finalizeCompleter = Completer<void>();
    _meetingRecordingFinalizeCompleter = finalizeCompleter;
    if (mounted) {
      setState(() {
        _recordingActive = false;
        _recordingUploading = true;
      });
    }
    try {
      if (recorder.state != 'inactive') {
        recorder.stop();
      } else {
        unawaited(_handleMeetingRecorderStopped());
      }
      await finalizeCompleter.future.timeout(const Duration(seconds: 60));
    } catch (_) {
      if (mounted) {
        setState(() {
          _recordingUploading = false;
        });
      }
    }
  }

  Future<void> _sendChat() async {
    final localProfile = _localMemberProfile;
    final canChat = _isModerator || (localProfile?.allowChat ?? _allowChat);
    if (!canChat) {
      _setStatus('当前会议已禁用聊天');
      return;
    }
    if (_isShareEntry && _accessToken.isEmpty) {
      try {
        await _ensureJwt(force: true);
      } catch (_) {
        // Keep guest fallback when session is not available.
      }
    }
    if (_isShareEntry && _localUserId == null && _accessToken.isEmpty) {
      _setStatus('访客链接模式下暂不支持发送聊天消息');
      return;
    }
    final content = _chatController.text.trim();
    if (content.isEmpty) return;
    try {
      final path = _isShareEntry
          ? '${_publicMeetingApiBase()}/messages'
          : '${_privateMeetingApiBase()}/messages';
      final res = await _request(
        'POST',
        path,
        body: {'content': content},
        requireAuth: _isShareEntry,
      );
      final data = await _jsonOrThrow(res) as Map<String, dynamic>;
      final msg = _ChatMessage.fromJson(data);
      if (!mounted) return;
      setState(() {
        _messages.add(msg);
        _latestMessageId = msg.id;
        _chatController.clear();
      });
      if (_isRealtimeBotMessage(msg)) {
        unawaited(_playRealtimeBotAudio(msg));
      }
      _scrollChatToBottom();
    } catch (e) {
      _setStatus('发送消息失败：${_friendlyError(e)}');
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
        style: const TextStyle(
          color: Color(0xFF98A2B3),
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
              color: const Color(0xFFEAF1FF),
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
              style: const TextStyle(
                color: Color(0xFF101828),
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

  bool _isMyMessage(_ChatMessage message) {
    final localUserId = _localUserId;
    if (localUserId == null) return false;
    return message.senderUserId == localUserId;
  }

  bool _canRecallMessage(_ChatMessage message) {
    if (!_connected) return false;
    if (_isShareEntry && _localUserId == null) return false;
    if (_isModerator) return true;
    if (!_isMyMessage(message)) return false;
    final createdAt = message.createdAt;
    if (createdAt == null) return false;
    return DateTime.now().difference(createdAt) <= const Duration(minutes: 3);
  }

  String _displayNameForMessage(_ChatMessage message) {
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

  Future<void> _confirmRecallMessage(_ChatMessage message) async {
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

  Future<void> _recallMessage(_ChatMessage message) async {
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

  _PreferredVideoSelection _findPreferredVideoTrack(
      lk.Participant participant) {
    final screenPub = participant
        .getTrackPublicationBySource(lk.TrackSource.screenShareVideo);
    if (screenPub != null &&
        screenPub.track is lk.VideoTrack &&
        !screenPub.muted) {
      return _PreferredVideoSelection(
        track: screenPub.track as lk.VideoTrack,
        isScreenShare: true,
      );
    }
    final camPub =
        participant.getTrackPublicationBySource(lk.TrackSource.camera);
    if (camPub != null && camPub.track is lk.VideoTrack && !camPub.muted) {
      return _PreferredVideoSelection(
        track: camPub.track as lk.VideoTrack,
        isScreenShare: false,
      );
    }
    for (final pub in participant.videoTrackPublications) {
      if (pub.track is lk.VideoTrack && !pub.muted) {
        return _PreferredVideoSelection(
          track: pub.track as lk.VideoTrack,
          isScreenShare: pub.source == lk.TrackSource.screenShareVideo,
        );
      }
    }
    return const _PreferredVideoSelection(track: null, isScreenShare: false);
  }

  List<_ParticipantTileData> _collectTiles() {
    final room = _room;
    if (room == null) return const [];
    final output = <_ParticipantTileData>[];
    final identities = <String>{};
    final local = room.localParticipant;
    if (local != null && identities.add(local.identity)) {
      final localVideo = _findPreferredVideoTrack(local);
      output.add(
        _ParticipantTileData(
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
        _ParticipantTileData(
          identity: p.identity,
          displayName: _displayNameForIdentity(
            p.identity,
            fallback: p.name.trim().isEmpty ? p.identity : p.name,
          ),
          avatarUrl: _avatarUrlForIdentity(p.identity),
          isLocal: false,
          isSpeaking: p.isSpeaking,
          micEnabled: p.isMicrophoneEnabled(),
          cameraEnabled: p.isCameraEnabled(),
          videoTrack: remoteVideo.track,
          isScreenShare: remoteVideo.isScreenShare,
        ),
      );
    }
    return output;
  }

  List<_ParticipantRowData> _collectParticipantRows() {
    final room = _room;
    if (room == null) return const [];
    final rows = <_ParticipantRowData>[];
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
        _ParticipantRowData(
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
        _ParticipantRowData(
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
        _ParticipantRowData(
          identity: _realtimeBotVirtualIdentity(),
          userId: _realtimeBotUserId,
          isRealtimeBot: true,
          displayName: _realtimeBotDisplayName.trim().isEmpty
              ? '实时语音助手'
              : _realtimeBotDisplayName.trim(),
          avatarUrl: '',
          role: 'AI成员',
          roleKey: 'ai',
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
        if (_isModerator && !_isShareEntry) {
          await _openModeratorControlDialog();
        }
        return;
      case 'ai_control':
        if (_isModerator && !_isShareEntry) {
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
        color: const Color(0x26FFFFFF),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0x44D1E0FF)),
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
    final iconBg = danger ? const Color(0xFFFEE4E2) : const Color(0xFFEFF4FF);
    final iconFg = danger ? const Color(0xFFB42318) : const Color(0xFF175CD3);
    final titleColor =
        danger ? const Color(0xFFB42318) : const Color(0xFF101828);
    final subtitleColor =
        danger ? const Color(0xFFB42318) : const Color(0xFF667085);
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
    final hasNotice =
        _isModerator && _hasNewWaitingRoomNotice && !_isShareEntry;
    return Container(
      margin: const EdgeInsets.only(left: 6),
      child: PopupMenuButton<String>(
        tooltip: '更多操作',
        onSelected: _handleMobileMenuAction,
        offset: const Offset(-8, 48),
        elevation: 12,
        color: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFDDE6FF)),
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
          if (_isModerator && !_isShareEntry) {
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
            color: const Color(0x26FFFFFF),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: const Color(0x44D1E0FF)),
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
                      color: const Color(0xFFEF4444),
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
        border: Border.all(color: const Color(0xFF9BB8FF)),
        gradient: const LinearGradient(
          colors: [Color(0xFF155EEF), Color(0xFF175CD3)],
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
                  style:
                      const TextStyle(color: Color(0xFFD1E0FF), fontSize: 12.5),
                ),
                Text(
                  _meetingDisplayName.isEmpty
                      ? _defaultDisplayName
                      : _meetingDisplayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: Color(0xFFD1E0FF), fontSize: 11.5),
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: const Color(0xFFDDE6FF)),
      ),
      child: _buildStage(),
    );
  }

  bool get _isTileFullscreenActive =>
      _fullscreenIdentity != null && html.document.fullscreenElement != null;

  _ParticipantTileData? _fullscreenTileData() {
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDDE6FF)),
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
            backgroundColor: _recordingActive
                ? const Color(0xFFB42318)
                : const Color(0xFF155EEF),
          ),
          _buildMobileControlButton(
            icon: Icons.call_end,
            label: _isHost && _requiresAuth ? '结束会议' : '离开会议',
            onPressed: _connected ? _handleLeaveButtonPressed : null,
            backgroundColor: const Color(0xFFB42318),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileMeetingScaffold() {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF5F8FF), Color(0xFFEEF4FF)],
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF4FF),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFCCDBFF)),
                  ),
                  child: Text(
                    _status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Color(0xFF175CD3), fontSize: 12),
                  ),
                ),
                if ((_permissionWarning ?? '').isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildPermissionBanner(),
                ],
                const SizedBox(height: 8),
                Expanded(
                  child: DefaultTabController(
                    length: 3,
                    child: Column(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFFDDE6FF)),
                          ),
                          child: const TabBar(
                            tabs: [
                              Tab(
                                  icon: Icon(Icons.grid_view_rounded),
                                  text: '舞台'),
                              Tab(
                                  icon: Icon(Icons.groups_outlined),
                                  text: '成员'),
                              Tab(
                                  icon: Icon(Icons.chat_bubble_outline),
                                  text: '聊天'),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: TabBarView(
                            children: [
                              _buildStageCard(radius: 14),
                              _buildParticipantPanel(),
                              _buildChatPanel(),
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
    );
  }

  Widget _buildMeetingMetricsStrip() {
    final activeCount = _activeParticipantCount();
    final maxParticipants = _maxParticipants <= 0 ? 100 : _maxParticipants;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF4FF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFCCDBFF)),
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
            accent: const Color(0xFF175CD3),
          ),
          _buildTopMetricChip(
            icon: Icons.timer_outlined,
            text: '时长：${_meetingElapsedText()}',
            accent: const Color(0xFF175CD3),
          ),
          if (_recordingActive || _recordingUploading)
            _buildTopMetricChip(
              icon: _recordingUploading
                  ? Icons.cloud_upload_outlined
                  : Icons.fiber_manual_record,
              text: _recordingUploading ? '录制上传中' : '正在录制',
              accent: const Color(0xFFB42318),
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
        side: const BorderSide(color: Color(0xFFD1E0FF)),
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
        border: Border.all(color: const Color(0xFF9BB8FF)),
        gradient: const LinearGradient(
          colors: [Color(0xFF155EEF), Color(0xFF175CD3)],
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
                    Text(
                      _meetingTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                        Text(
                          '会议号：$_roomNumber',
                          style: const TextStyle(
                            color: Color(0xFFD1E0FF),
                            fontSize: 12.5,
                          ),
                        ),
                        GestureDetector(
                          onDoubleTap: _openMeetingDisplayNameDialog,
                          child: Text(
                            '显示名：$displayName',
                            style: const TextStyle(
                              color: Color(0xFFD1E0FF),
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFD1E0FF),
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
                      if (_isModerator && !_isShareEntry)
                        _buildDesktopHeaderAction(
                          label: '会议管控',
                          icon: _waitingRoomEntries.isNotEmpty
                              ? Icons.notifications_active
                              : Icons.admin_panel_settings,
                          onPressed: _openModeratorControlDialog,
                        ),
                      if (_isModerator && !_isShareEntry)
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
                accent: const Color(0xFF175CD3),
              ),
              _buildTopMetricChip(
                icon: Icons.timer_outlined,
                text: '时长：${_meetingElapsedText()}',
                accent: const Color(0xFF175CD3),
              ),
              if (_recordingActive || _recordingUploading)
                _buildTopMetricChip(
                  icon: _recordingUploading
                      ? Icons.cloud_upload_outlined
                      : Icons.fiber_manual_record,
                  text: _recordingUploading ? '录制上传中' : '正在录制',
                  accent: const Color(0xFFB42318),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0x26FFFFFF),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: const Color(0x55D1E0FF)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 14,
                  color: Color(0xFFD1E0FF),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFD1E0FF),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDDE6FF)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF175CD3)),
          const SizedBox(height: 8),
          RotatedBox(
            quarterTurns: 3,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF344054),
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
                color: const Color(0xFF175CD3),
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
                      color: const Color(0xFFF7FAFF),
                      shape: const CircleBorder(),
                      elevation: 1,
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        splashRadius: 16,
                        onPressed: onToggle,
                        icon: Icon(
                          left ? Icons.chevron_left : Icons.chevron_right,
                          size: 18,
                          color: const Color(0xFF175CD3),
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
        ? 360.0
        : (constraints.maxWidth >= 1320 ? 326.0 : 286.0);
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
          collapsedLabel: '聊天',
          collapsedIcon: Icons.chat_bubble_outline,
          collapseTooltip: '折叠会议聊天',
          expandTooltip: '展开会议聊天',
          onToggle: () {
            setState(() {
              _desktopChatCollapsed = !_desktopChatCollapsed;
            });
          },
          child: _buildChatPanel(),
        ),
      ],
    );
  }

  Widget _buildVideoTile(_ParticipantTileData tile) {
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
        color: const Color(0xFFEAF2FF),
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
          color: const Color(0xFFEAF2FF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: tile.isSpeaking
                ? const Color(0xFF155EEF)
                : const Color(0xFFCCDBFF),
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
                  color: const Color(0xAA155EEF),
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
                  color: const Color(0xCC155EEF),
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
                          ? const Color(0xFF86EFAC)
                          : const Color(0xFFFCA5A5),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      tile.cameraEnabled ? Icons.videocam : Icons.videocam_off,
                      size: 14,
                      color: tile.cameraEnabled
                          ? const Color(0xFF93C5FD)
                          : const Color(0xFFFCA5A5),
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
        color: const Color(0xAA155EEF),
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
            color: const Color(0xFFF9FBFF),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFDDE6FF)),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
              SizedBox(height: 10),
              Text(
                '已进入会议主界面，正在等候室等待主持人准入...',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF475467)),
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
          color: const Color(0xFFF9FBFF),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFDDE6FF)),
        ),
        child: Text(
          placeholder,
          style: const TextStyle(color: Color(0xFF475467)),
        ),
      );
    }

    _ParticipantTileData? spotlightTile;
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
        color: const Color(0xFFFFF4E8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFEC84B)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Color(0xFFB54708), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              warning,
              style: const TextStyle(color: Color(0xFF7A2E0E), fontSize: 12.5),
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
        backgroundColor: const Color(0xFFD9E6FF),
        foregroundColor: const Color(0xFF175CD3),
        child:
            Text(initial, style: const TextStyle(fontWeight: FontWeight.w700)),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFFD9E6FF),
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
          color: const Color(0xFFFFF4E8),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFFFDB022)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.pan_tool_alt_rounded,
              size: 11,
              color: Color(0xFFB54708),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFFB54708),
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.task_alt_rounded,
              size: 11,
              color: Color(0xFF15803D),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleParticipantMenuAction(
    _ParticipantRowData row,
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
    _ParticipantRowData row,
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
        style: const TextStyle(
          color: Color(0xFF98A2B3),
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  PopupMenuEntry<String> _participantMenuActionItemRefined({
    required String value,
    required String title,
    required IconData icon,
    String? subtitle,
    bool enabled = true,
    bool danger = false,
  }) {
    final iconColor =
        danger ? const Color(0xFFB42318) : const Color(0xFF175CD3);
    final iconBg = danger ? const Color(0xFFFEE4E2) : const Color(0xFFEAF1FF);
    final titleColor =
        danger ? const Color(0xFFB42318) : const Color(0xFF101828);
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
                      style: const TextStyle(
                        color: Color(0xFF98A2B3),
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
    _ParticipantRowData row,
    bool isSelf,
  ) {
    final items = <PopupMenuEntry<String>>[];
    if (isSelf) {
      items.add(_participantMenuSectionRefined('我的控制'));
      items.add(
        _participantMenuActionItemRefined(
          value: 'rename_self',
          title: '修改本次显示名',
          icon: Icons.badge_outlined,
        ),
      );
      if (!row.allowSelfUnmute) {
        items.add(
          _participantMenuActionItemRefined(
            value: 'request_mic',
            title: row.micRequestPending ? '开麦申请已提交' : '申请开麦',
            subtitle: row.micRequestPending ? '等待主持人审批' : '提交后主持人可一键批准',
            icon: Icons.pan_tool_alt_outlined,
            enabled: !row.micRequestPending,
          ),
        );
      }
      if (!row.allowMemberVideo) {
        items.add(
          _participantMenuActionItemRefined(
            value: 'request_video',
            title: row.videoRequestPending ? '开视频申请已提交' : '申请开视频',
            subtitle: row.videoRequestPending ? '等待主持人审批' : '提交后主持人可一键批准',
            icon: Icons.videocam_outlined,
            enabled: !row.videoRequestPending,
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
    if (row.isRealtimeBot) {
      items.add(_participantMenuSectionRefined('AI 控制'));
      items.add(
        _participantMenuActionItemRefined(
          value: row.mutedByHost ? 'unmute' : 'mute',
          title: row.mutedByHost ? '允许 AI 发言' : '静音 AI 发言',
          subtitle: row.mutedByHost ? '当前：已静音' : '当前：可发言',
          icon: row.mutedByHost ? Icons.mic : Icons.mic_off,
        ),
      );
      items.add(
        _participantMenuActionItemRefined(
          value: 'ai_control',
          title: '打开 AI 管控',
          subtitle: '配置模型参数并测试连通性',
          icon: Icons.smart_toy_outlined,
        ),
      );
      return items;
    }
    if (row.roleKey == 'host') {
      return items;
    }
    final isGuest = row.userId == null;
    final String muteSubtitle;
    final String videoSubtitle;
    if (isGuest) {
      muteSubtitle = row.micEnabled ? '当前：麦克风开启' : '当前：麦克风关闭';
      videoSubtitle = row.cameraEnabled ? '当前：摄像头开启' : '当前：摄像头关闭';
    } else {
      muteSubtitle = row.mutedByHost ? '当前：主持人已静音' : '当前：成员可发言';
      videoSubtitle = row.videoBlockedByHost ? '当前：主持人已关闭视频' : '当前：成员可开视频';
    }

    items.add(_participantMenuSectionRefined('即时控制'));
    items.add(
      _participantMenuActionItemRefined(
        value: row.mutedByHost ? 'unmute' : 'mute',
        title: row.mutedByHost ? '允许开麦' : '静音成员',
        subtitle: muteSubtitle,
        icon: row.mutedByHost ? Icons.mic : Icons.mic_off,
      ),
    );
    items.add(
      _participantMenuActionItemRefined(
        value: row.videoBlockedByHost ? 'video_on' : 'video_off',
        title: row.videoBlockedByHost ? '允许开视频' : '关闭成员视频',
        subtitle: videoSubtitle,
        icon: row.videoBlockedByHost ? Icons.videocam : Icons.videocam_off,
      ),
    );
    if (row.isScreenSharing) {
      items.add(
        _participantMenuActionItemRefined(
          value: 'stop_share',
          title: '结束屏幕共享',
          icon: Icons.stop_screen_share,
        ),
      );
    }

    items.add(const PopupMenuDivider(height: 8));
    items.add(_participantMenuSectionRefined('权限设置'));
    items.add(
      _participantMenuActionItemRefined(
        value: row.allowSelfUnmute
            ? 'mic_permission_block'
            : 'mic_permission_allow',
        title: row.allowSelfUnmute ? '禁止开麦（权限）' : '允许开麦（权限）',
        icon: Icons.keyboard_voice_outlined,
      ),
    );
    items.add(
      _participantMenuActionItemRefined(
        value: row.allowMemberVideo
            ? 'video_permission_block'
            : 'video_permission_allow',
        title: row.allowMemberVideo ? '禁止开视频（权限）' : '允许开视频（权限）',
        icon: Icons.camera_alt_outlined,
      ),
    );
    items.add(
      _participantMenuActionItemRefined(
        value:
            row.allowChat ? 'chat_permission_block' : 'chat_permission_allow',
        title: row.allowChat ? '禁止聊天（权限）' : '允许聊天（权限）',
        icon: Icons.chat_bubble_outline_rounded,
        subtitle: isGuest ? '访客聊天权限跟随会议设置' : null,
        enabled: !isGuest,
      ),
    );
    items.add(
      _participantMenuActionItemRefined(
        value: row.allowScreenShare
            ? 'share_permission_block'
            : 'share_permission_allow',
        title: row.allowScreenShare ? '禁止共享（权限）' : '允许共享（权限）',
        icon: Icons.screen_share_outlined,
      ),
    );
    if (row.micRequestPending && !row.allowSelfUnmute) {
      items.add(
        _participantMenuActionItemRefined(
          value: 'mic_permission_allow',
          title: '通过开麦申请',
          icon: Icons.task_alt_outlined,
        ),
      );
    }
    if (row.videoRequestPending && !row.allowMemberVideo) {
      items.add(
        _participantMenuActionItemRefined(
          value: 'video_permission_allow',
          title: '通过视频申请',
          icon: Icons.task_alt_outlined,
        ),
      );
    }

    items.add(const PopupMenuDivider(height: 8));
    if (row.screenShareRequestPending && !row.allowScreenShare) {
      items.add(
        _participantMenuActionItemRefined(
          value: 'share_permission_allow',
          title: '通过屏幕共享申请',
          icon: Icons.task_alt_outlined,
        ),
      );
    }
    items.add(_participantMenuSectionRefined('成员管理'));
    if (!isGuest) {
      if (row.roleKey == 'cohost') {
        items.add(
          _participantMenuActionItemRefined(
            value: 'set_participant',
            title: '取消联席主持人',
            icon: Icons.person_remove_alt_1_outlined,
          ),
        );
      } else if (row.roleKey == 'participant') {
        items.add(
          _participantMenuActionItemRefined(
            value: 'set_cohost',
            title: '设为联席主持人',
            icon: Icons.admin_panel_settings_outlined,
          ),
        );
      }
    }
    items.add(
      _participantMenuActionItemRefined(
        value: 'rename_member',
        title: '成员改名',
        icon: Icons.drive_file_rename_outline,
      ),
    );
    if (isGuest) {
      items.add(
        _participantMenuActionItemRefined(
          value: 'remove_guest',
          title: '移出成员',
          icon: Icons.person_remove,
          danger: true,
        ),
      );
    } else {
      items.add(
        _participantMenuActionItemRefined(
          value: 'remove',
          title: '移出成员',
          subtitle: '仅移出，允许重新加入会议',
          icon: Icons.person_remove_alt_1_rounded,
          danger: true,
        ),
      );
      items.add(
        _participantMenuActionItemRefined(
          value: 'remove_ban',
          title: '移出并封禁',
          subtitle: '移出后禁止再次进入本会议',
          icon: Icons.person_off_outlined,
          danger: true,
        ),
      );
    }
    return items;
  }

  Future<void> _quickReviewWaitingEntry(
    _WaitingRoomEntry entry,
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

  Widget _buildParticipantExportButton() {
    return Tooltip(
      message: '导出当前在会成员（已注册成员与访客）',
      child: TextButton.icon(
        onPressed: _exportParticipantRosterCsv,
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: const Color(0xFF175CD3),
          backgroundColor: const Color(0xFFEAF1FF),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: const BorderSide(color: Color(0xFFCFE0FF)),
          ),
        ),
        icon: const Icon(Icons.download_outlined, size: 15),
        label: const Text(
          '导出名单',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildParticipantPanel() {
    final rows = _collectParticipantRows();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDDE6FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '参会成员',
            style: TextStyle(
                color: Color(0xFF101828), fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '${rows.length} 人在线',
            style: const TextStyle(color: Color(0xFF475467), fontSize: 12.5),
          ),
          const SizedBox(height: 2),
          const Text(
            '双击成员可放大对应画面',
            style: TextStyle(color: Color(0xFF667085), fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          if (_isModerator && !_isShareEntry) ...[
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _exportParticipantRosterCsv,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: const Color(0xFF175CD3),
                  backgroundColor: const Color(0xFFEAF1FF),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                    side: const BorderSide(color: Color(0xFFCFE0FF)),
                  ),
                ),
                icon: const Icon(Icons.download_outlined, size: 15),
                label: const Text('导出入会名单'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_isModerator) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: _waitingRoomEntries.isEmpty
                    ? const Color(0xFFF5F8FF)
                    : const Color(0xFFFFF4E8),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _waitingRoomEntries.isEmpty
                      ? const Color(0xFFDDE6FF)
                      : const Color(0xFFFEC84B),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _waitingRoomEntries.isEmpty
                        ? Icons.meeting_room_outlined
                        : Icons.notifications_active,
                    size: 16,
                    color: _waitingRoomEntries.isEmpty
                        ? const Color(0xFF175CD3)
                        : const Color(0xFFB54708),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _waitingRoomEntries.isEmpty
                          ? '等候室暂无待审核成员'
                          : '等候室有 ${_waitingRoomEntries.length} 人等待审核',
                      style: const TextStyle(
                        color: Color(0xFF475467),
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                  if (_waitingRoomEntries.isNotEmpty)
                    TextButton(
                      onPressed: _openModeratorControlDialog,
                      child: const Text('立即处理'),
                    ),
                ],
              ),
            ),
            if (_waitingRoomEntries.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: _waitingRoomEntries.length > 2 ? 104 : 52,
                child: ListView.builder(
                  itemCount: _waitingRoomEntries.length,
                  itemBuilder: (_, index) {
                    final entry = _waitingRoomEntries[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFDDE6FF)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              entry.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                          TextButton(
                            onPressed: () => unawaited(
                              _quickReviewWaitingEntry(entry, 'rejected'),
                            ),
                            child: const Text('拒绝'),
                          ),
                          FilledButton(
                            onPressed: () => unawaited(
                              _quickReviewWaitingEntry(entry, 'approved'),
                            ),
                            child: const Text('通过'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      _waitingForAdmission ? '等候室等待中，主持人审核后自动入会' : '尚未连接',
                      style: TextStyle(
                        color: _waitingForAdmission
                            ? const Color(0xFFB54708)
                            : const Color(0xFF64748B),
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) =>
                        const Divider(color: Color(0xFFDDE6FF), height: 12),
                    itemBuilder: (_, i) {
                      final row = rows[i];
                      final highlighted = row.identity == _spotlightIdentity;
                      final localIdentity = _room?.localParticipant?.identity;
                      final isSelf = localIdentity != null &&
                          localIdentity == row.identity;
                      final menuItems =
                          _participantMenuItemsRefined(row, isSelf);
                      final pendingActionChips = <Widget>[];
                      if (_isModerator && !isSelf && !row.isRealtimeBot) {
                        if (row.micRequestPending && !row.allowSelfUnmute) {
                          pendingActionChips.add(
                            _buildPendingRequestChip(
                              label: '开麦申请',
                              onApprove: () => unawaited(
                                _handleParticipantMenuAction(
                                  row,
                                  'mic_permission_allow',
                                  isSelf,
                                ),
                              ),
                            ),
                          );
                        }
                        if (row.videoRequestPending && !row.allowMemberVideo) {
                          pendingActionChips.add(
                            _buildPendingRequestChip(
                              label: '视频申请',
                              onApprove: () => unawaited(
                                _handleParticipantMenuAction(
                                  row,
                                  'video_permission_allow',
                                  isSelf,
                                ),
                              ),
                            ),
                          );
                        }
                        if (row.screenShareRequestPending &&
                            !row.allowScreenShare) {
                          pendingActionChips.add(
                            _buildPendingRequestChip(
                              label: '共享申请',
                              onApprove: () => unawaited(
                                _handleParticipantMenuAction(
                                  row,
                                  'share_permission_allow',
                                  isSelf,
                                ),
                              ),
                            ),
                          );
                        }
                      }
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onDoubleTap: row.isRealtimeBot
                            ? null
                            : () => _focusParticipantTile(
                                  row.identity,
                                  allowToggle: false,
                                ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: highlighted
                                ? const Color(0xFFEFF4FF)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              _buildParticipantAvatar(
                                displayName: row.displayName,
                                avatarUrl: row.avatarUrl,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      row.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Color(0xFF101828),
                                          fontSize: 13),
                                    ),
                                    if (pendingActionChips.isNotEmpty) ...[
                                      const SizedBox(height: 3),
                                      Wrap(
                                        spacing: 4,
                                        runSpacing: 3,
                                        children: pendingActionChips,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              Text(
                                row.role,
                                style: const TextStyle(
                                    color: Color(0xFF93C5FD), fontSize: 11.5),
                              ),
                              if (menuItems.isNotEmpty)
                                PopupMenuButton<String>(
                                  tooltip: '成员菜单',
                                  color: const Color(0xFFFCFDFF),
                                  elevation: 10,
                                  position: PopupMenuPosition.under,
                                  offset: const Offset(-10, 8),
                                  constraints: const BoxConstraints(
                                    minWidth: 240,
                                    maxWidth: 288,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                    side: const BorderSide(
                                      color: Color(0xFFD6E4FF),
                                    ),
                                  ),
                                  padding: EdgeInsets.zero,
                                  icon: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFEAF1FF),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Icon(
                                      Icons.more_horiz,
                                      size: 17,
                                      color: Color(0xFF175CD3),
                                    ),
                                  ),
                                  onSelected: (value) {
                                    unawaited(
                                      _handleParticipantMenuAction(
                                        row,
                                        value,
                                        isSelf,
                                      ),
                                    );
                                  },
                                  itemBuilder: (context) => menuItems,
                                ),
                              const SizedBox(width: 8),
                              Icon(
                                row.micEnabled ? Icons.mic : Icons.mic_off,
                                size: 13,
                                color: row.micEnabled
                                    ? const Color(0xFF86EFAC)
                                    : const Color(0xFFFCA5A5),
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                row.cameraEnabled
                                    ? Icons.videocam
                                    : Icons.videocam_off,
                                size: 13,
                                color: row.cameraEnabled
                                    ? const Color(0xFF86EFAC)
                                    : const Color(0xFFFCA5A5),
                              ),
                              if (row.isScreenSharing) ...[
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.screen_share,
                                  size: 13,
                                  color: Color(0xFFF59E0B),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyChatMessage(_ChatMessage message) async {
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
    final iconColor =
        danger ? const Color(0xFFB42318) : const Color(0xFF175CD3);
    final iconBg = danger ? const Color(0xFFFEE4E2) : const Color(0xFFEAF1FF);
    final titleColor =
        danger ? const Color(0xFFB42318) : const Color(0xFF101828);
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
                      style: const TextStyle(
                        color: Color(0xFF98A2B3),
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

  List<PopupMenuEntry<String>> _chatMessageMenuItems({
    required bool canRecall,
    required bool isRecalling,
  }) {
    final items = <PopupMenuEntry<String>>[
      _chatMessageMenuActionItemRefined(
        value: 'copy',
        title: '复制消息',
        subtitle: '复制该条聊天内容',
        icon: Icons.content_copy_outlined,
      ),
    ];
    if (canRecall || isRecalling) {
      items.add(
        _chatMessageMenuActionItemRefined(
          value: 'recall',
          title: isRecalling ? '撤回中...' : '撤回消息',
          subtitle: '从会议聊天中撤回该条消息',
          icon: Icons.undo_outlined,
          enabled: !isRecalling,
          danger: true,
        ),
      );
    }
    return items;
  }

  Widget _buildChatMessageBubble(_ChatMessage message) {
    final isMine = _isMyMessage(message);
    final senderName = _displayNameForMessage(message);
    final canRecall = _canRecallMessage(message);
    final isRecalling = _recallingMessageIds.contains(message.id);
    final bubbleColor = isMine ? const Color(0xFF95EC69) : Colors.white;
    final borderColor =
        isMine ? const Color(0xFF7BD453) : const Color(0xFFDDE6FF);
    final timeLabel = _messageTimeLabel(message.createdAt);
    final nameColor =
        isMine ? const Color(0xFF175CD3) : const Color(0xFF667085);
    final avatarBg = isMine ? const Color(0xFFCFF8B1) : const Color(0xFFE8EEFF);
    final avatarFg = isMine ? const Color(0xFF175CD3) : const Color(0xFF344054);

    Widget buildAvatar() {
      return CircleAvatar(
        radius: 14,
        backgroundColor: avatarBg,
        foregroundColor: avatarFg,
        child: Text(
          _initialForName(senderName),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      );
    }

    Widget buildMessageMenu() {
      return PopupMenuButton<String>(
        tooltip: '消息菜单',
        color: const Color(0xFFFCFDFF),
        elevation: 10,
        position: PopupMenuPosition.under,
        offset: const Offset(-10, 8),
        constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFFD6E4FF)),
        ),
        padding: EdgeInsets.zero,
        icon: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: const Color(0xFFEAF1FF),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.more_horiz,
            size: 17,
            color:
                isRecalling ? const Color(0xFF98A2B3) : const Color(0xFF175CD3),
          ),
        ),
        onSelected: (value) {
          if (value == 'copy') {
            unawaited(_copyChatMessage(message));
            return;
          }
          if (value == 'recall') {
            unawaited(_confirmRecallMessage(message));
          }
        },
        itemBuilder: (context) => _chatMessageMenuItems(
          canRecall: canRecall,
          isRecalling: isRecalling,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isMine) ...[
            buildAvatar(),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!isMine)
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 3),
                    child: Text(
                      senderName,
                      style: TextStyle(
                        color: nameColor,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (isMine) buildMessageMenu(),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: bubbleColor,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(14),
                            topRight: const Radius.circular(14),
                            bottomLeft: Radius.circular(isMine ? 14 : 4),
                            bottomRight: Radius.circular(isMine ? 4 : 14),
                          ),
                          border: Border.all(color: borderColor),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x12000000),
                              blurRadius: 8,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Text(
                          message.content,
                          style: const TextStyle(
                            color: Color(0xFF101828),
                            fontSize: 13.5,
                            height: 1.38,
                          ),
                        ),
                      ),
                    ),
                    if (!isMine) buildMessageMenu(),
                  ],
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
            buildAvatar(),
          ],
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _buildChatPanelLegacy() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDDE6FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '会议聊天',
            style: TextStyle(
                color: Color(0xFF101828), fontWeight: FontWeight.w700),
          ),
          if (!_allowChat) ...[
            const SizedBox(height: 4),
            const Text(
              '当前会议已禁用聊天',
              style: TextStyle(color: Color(0xFF667085), fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              controller: _chatScrollController,
              itemCount: _messages.length,
              itemBuilder: (_, i) {
                final m = _messages[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F8FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFDDE6FF)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.senderUsername,
                        style: const TextStyle(
                            color: Color(0xFF93C5FD), fontSize: 11.5),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        m.content,
                        style: const TextStyle(
                            color: Color(0xFF101828), fontSize: 13),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  enabled: _connected && _chatWriteEnabled,
                  style: const TextStyle(color: Color(0xFF101828)),
                  decoration: const InputDecoration(
                    labelText: '输入消息',
                    labelStyle: TextStyle(color: Color(0xFF475467)),
                    filled: true,
                    fillColor: Color(0xFFF8FAFF),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) {
                    if (_chatWriteEnabled) {
                      _sendChat();
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: (_connected && _chatWriteEnabled) ? _sendChat : null,
                child: const Text('发送'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChatPanel() {
    final chatEnabled = _connected && _chatWriteEnabled;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDDE6FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '会议聊天',
            style: TextStyle(
              color: Color(0xFF101828),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '成员可撤回 3 分钟内消息，主持人与联席主持人可撤回任意消息',
            style: TextStyle(color: Color(0xFF667085), fontSize: 11.5),
          ),
          if (!_allowChat) ...[
            const SizedBox(height: 4),
            const Text(
              '当前会议已禁用聊天',
              style: TextStyle(color: Color(0xFF667085), fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF7FAFF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFDDE6FF)),
              ),
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
              child: _messages.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无聊天消息',
                        style:
                            TextStyle(color: Color(0xFF98A2B3), fontSize: 12.5),
                      ),
                    )
                  : ListView.builder(
                      controller: _chatScrollController,
                      itemCount: _messages.length,
                      itemBuilder: (_, index) =>
                          _buildChatMessageBubble(_messages[index]),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              PopupMenuButton<String>(
                tooltip: '发送表情',
                enabled: chatEnabled,
                onSelected: _appendEmoji,
                color: const Color(0xFFFCFDFF),
                surfaceTintColor: Colors.transparent,
                elevation: 8,
                shadowColor: const Color(0x1A101828),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFFD6E4FF)),
                ),
                constraints: const BoxConstraints(minWidth: 186, maxWidth: 220),
                itemBuilder: (context) => _chatEmojiMenuItems(),
                icon: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: chatEnabled
                        ? const Color(0xFFEAF1FF)
                        : const Color(0xFFF2F4F7),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: chatEnabled
                          ? const Color(0xFFD6E4FF)
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
                  controller: _chatController,
                  enabled: chatEnabled,
                  style: const TextStyle(color: Color(0xFF101828)),
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(
                    hintText: '输入消息，支持表情',
                    hintStyle:
                        TextStyle(color: Color(0xFF98A2B3), fontSize: 12.5),
                    filled: true,
                    fillColor: Color(0xFFF8FAFF),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) {
                    if (chatEnabled) {
                      _sendChat();
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: chatEnabled ? _sendChat : null,
                child: const Text('发送'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDock() {
    final canSelfUnmute = _localCanSelfUnmute;
    final canOpenVideo = _localCanMemberVideo;
    final canShareScreen = _localCanScreenShare;
    final canRecord = _canRecordMeeting && !_recordingUploading;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDDE6FF)),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        alignment: WrapAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: (_connected && (_micEnabled || canSelfUnmute))
                ? _toggleMic
                : null,
            icon: Icon(_micEnabled ? Icons.mic : Icons.mic_off),
            label: Text(_micEnabled ? '静音' : '取消静音'),
          ),
          FilledButton.icon(
            onPressed: (_connected && (_cameraEnabled || canOpenVideo))
                ? _toggleCamera
                : null,
            icon: Icon(_cameraEnabled ? Icons.videocam : Icons.videocam_off),
            label: Text(_cameraEnabled ? '关闭摄像头' : '开启摄像头'),
          ),
          FilledButton.icon(
            onPressed:
                (_connected && canShareScreen) ? _toggleScreenShare : null,
            icon: Icon(
                _screenShareEnabled
                    ? Icons.stop_screen_share
                    : Icons.screen_share,
                color: (_screenShareEnabled && _screenShareAudioEnabled)
                    ? const Color(0xFF12B76A)
                    : null),
            label: Text(
              canShareScreen
                  ? (_screenShareEnabled ? '停止共享' : '共享屏幕')
                  : '共享已禁用',
            ),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _recordingActive
                  ? const Color(0xFFB42318)
                  : const Color(0xFF155EEF),
            ),
            onPressed: canRecord
                ? (_recordingActive
                    ? _stopMeetingRecording
                    : _startMeetingRecording)
                : null,
            icon: Icon(
              _recordingUploading
                  ? Icons.cloud_upload_outlined
                  : (_recordingActive
                      ? Icons.stop_circle_outlined
                      : Icons.fiber_manual_record),
              color: _recordingActive ? Colors.white : null,
            ),
            label: Text(
              _recordingUploading
                  ? '上传录制中...'
                  : (_recordingActive
                      ? '停止录制'
                      : (_allowRecording ? '开始录制' : '录制已禁用')),
            ),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB42318)),
            onPressed: _connected ? _handleLeaveButtonPressed : null,
            icon: const Icon(Icons.call_end),
            label: Text(_isHost && _requiresAuth ? '结束会议' : '离开会议'),
          ),
        ],
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
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF5F8FF), Color(0xFFEEF4FF)],
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
    );
  }
}

class _ApiException implements Exception {
  final int statusCode;
  final String detail;
  final Map<String, dynamic>? payload;

  const _ApiException({
    required this.statusCode,
    required this.detail,
    required this.payload,
  });

  @override
  String toString() => 'ApiException($statusCode): $detail';
}

enum _CameraResolutionPreset {
  p720,
  p1080,
  p1440,
  p2160,
}

enum _ScreenShareResolutionPreset {
  p720,
  p1080,
  p1440,
  p2160,
}

enum _RemoteShareViewMode {
  stretch,
  original,
}

class _ChatMessage {
  final int id;
  final int senderUserId;
  final String senderUsername;
  final String senderDisplayName;
  final bool isRealtimeBot;
  final String audioMimeType;
  final String audioBase64;
  final String content;
  final DateTime? createdAt;

  const _ChatMessage({
    required this.id,
    required this.senderUserId,
    required this.senderUsername,
    required this.senderDisplayName,
    required this.isRealtimeBot,
    required this.audioMimeType,
    required this.audioBase64,
    required this.content,
    required this.createdAt,
  });

  static int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static DateTime? _asDateTime(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return parsed.toLocal();
  }

  factory _ChatMessage.fromJson(Map<String, dynamic> json) {
    final senderUsername = (json['sender_username'] ?? '-').toString();
    final senderDisplayName =
        (json['sender_display_name'] ?? senderUsername).toString();
    return _ChatMessage(
      id: _asInt(json['id'], 0),
      senderUserId: _asInt(json['sender_user_id'], 0),
      senderUsername: senderUsername,
      senderDisplayName: senderDisplayName,
      isRealtimeBot: _asBool(json['is_realtime_bot'], false),
      audioMimeType: (json['audio_mime_type'] ?? '').toString(),
      audioBase64: (json['audio_base64'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      createdAt: _asDateTime(json['created_at']),
    );
  }

  static bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }
}

class _ParticipantTileData {
  final String identity;
  final String displayName;
  final String avatarUrl;
  final bool isLocal;
  final bool isSpeaking;
  final bool micEnabled;
  final bool cameraEnabled;
  final lk.VideoTrack? videoTrack;
  final bool isScreenShare;

  const _ParticipantTileData({
    required this.identity,
    required this.displayName,
    required this.avatarUrl,
    required this.isLocal,
    required this.isSpeaking,
    required this.micEnabled,
    required this.cameraEnabled,
    required this.videoTrack,
    required this.isScreenShare,
  });
}

class _PreferredVideoSelection {
  final lk.VideoTrack? track;
  final bool isScreenShare;

  const _PreferredVideoSelection({
    required this.track,
    required this.isScreenShare,
  });
}

class _RequestPendingFlags {
  final bool micPending;
  final bool videoPending;
  final bool screenSharePending;

  const _RequestPendingFlags({
    required this.micPending,
    required this.videoPending,
    required this.screenSharePending,
  });
}

class _ParticipantRowData {
  final String identity;
  final int? userId;
  final bool isRealtimeBot;
  final String displayName;
  final String avatarUrl;
  final String role;
  final String roleKey;
  final bool micEnabled;
  final bool cameraEnabled;
  final bool mutedByHost;
  final bool videoBlockedByHost;
  final bool allowSelfUnmute;
  final bool allowMemberVideo;
  final bool allowChat;
  final bool allowScreenShare;
  final bool micRequestPending;
  final bool videoRequestPending;
  final bool screenShareRequestPending;
  final bool isScreenSharing;

  const _ParticipantRowData({
    required this.identity,
    required this.userId,
    required this.isRealtimeBot,
    required this.displayName,
    required this.avatarUrl,
    required this.role,
    required this.roleKey,
    required this.micEnabled,
    required this.cameraEnabled,
    required this.mutedByHost,
    required this.videoBlockedByHost,
    required this.allowSelfUnmute,
    required this.allowMemberVideo,
    required this.allowChat,
    required this.allowScreenShare,
    required this.micRequestPending,
    required this.videoRequestPending,
    required this.screenShareRequestPending,
    required this.isScreenSharing,
  });
}

class _MeetingMemberProfile {
  final int userId;
  final String username;
  final String displayName;
  final int displayNameVersion;
  final String avatarUrl;
  final String role;
  final bool mutedByHost;
  final bool videoBlockedByHost;
  final bool allowSelfUnmute;
  final bool allowMemberVideo;
  final bool allowChat;
  final bool allowScreenShare;
  final bool micRequestPending;
  final bool videoRequestPending;

  const _MeetingMemberProfile({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.displayNameVersion,
    required this.avatarUrl,
    required this.role,
    required this.mutedByHost,
    required this.videoBlockedByHost,
    required this.allowSelfUnmute,
    required this.allowMemberVideo,
    required this.allowChat,
    required this.allowScreenShare,
    required this.micRequestPending,
    required this.videoRequestPending,
  });

  static int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }

  factory _MeetingMemberProfile.fromJson(Map<String, dynamic> json) {
    return _MeetingMemberProfile(
      userId: _asInt(json['user_id'], 0),
      username: (json['username'] ?? '').toString(),
      displayName: (json['display_name'] ?? json['username'] ?? '').toString(),
      displayNameVersion: _asInt(json['display_name_version'], 1),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      role: (json['role'] ?? 'participant').toString(),
      mutedByHost: _asBool(json['muted_by_host'], false),
      videoBlockedByHost: _asBool(json['video_blocked_by_host'], false),
      allowSelfUnmute: _asBool(json['allow_self_unmute'], true),
      allowMemberVideo: _asBool(json['allow_member_video'], true),
      allowChat: _asBool(json['allow_chat'], true),
      allowScreenShare: _asBool(json['allow_screen_share'], true),
      micRequestPending: _asBool(json['mic_request_pending'], false),
      videoRequestPending: _asBool(json['video_request_pending'], false),
    );
  }
}

class _JoinTokenPayload {
  final String meetingRef;
  final String roomName;
  final String livekitUrl;
  final String token;
  final bool waitingRoomEnabled;
  final int maxParticipants;
  final DateTime? actualStartedAt;
  final bool muteOnEntry;
  final bool allowGuestLinkJoin;
  final bool allowRecording;
  final bool allowScreenShare;
  final bool allowChat;
  final bool allowSelfUnmute;
  final bool allowMemberVideo;
  final bool canPublish;

  const _JoinTokenPayload({
    required this.meetingRef,
    required this.roomName,
    required this.livekitUrl,
    required this.token,
    required this.waitingRoomEnabled,
    required this.maxParticipants,
    required this.actualStartedAt,
    required this.muteOnEntry,
    required this.allowGuestLinkJoin,
    required this.allowRecording,
    required this.allowScreenShare,
    required this.allowChat,
    required this.allowSelfUnmute,
    required this.allowMemberVideo,
    required this.canPublish,
  });

  static bool _asBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }

  static int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  static DateTime? _asDateTime(dynamic value) {
    if (value == null) return null;
    final raw = value.toString().trim();
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return parsed.toLocal();
  }

  factory _JoinTokenPayload.fromJson(Map<String, dynamic> json) {
    return _JoinTokenPayload(
      meetingRef: (json['meeting_ref'] ?? '').toString().trim(),
      roomName: (json['room_name'] ?? '').toString(),
      livekitUrl: (json['livekit_url'] ?? '').toString(),
      token: (json['token'] ?? '').toString(),
      waitingRoomEnabled: _asBool(json['waiting_room_enabled'], false),
      maxParticipants: _asInt(json['max_participants'], 100),
      actualStartedAt: _asDateTime(json['actual_started_at']),
      muteOnEntry: _asBool(json['mute_on_entry'], false),
      allowGuestLinkJoin: _asBool(json['allow_guest_link_join'], true),
      allowRecording: _asBool(json['allow_recording'], true),
      allowScreenShare: _asBool(json['allow_screen_share'], true),
      allowChat: _asBool(json['allow_chat'], true),
      allowSelfUnmute: _asBool(json['allow_self_unmute'], true),
      allowMemberVideo: _asBool(json['allow_member_video'], true),
      canPublish: _asBool(json['can_publish'], true),
    );
  }
}

class _WaitingRoomEntry {
  final int userId;
  final String username;
  final String displayName;

  const _WaitingRoomEntry({
    required this.userId,
    required this.username,
    required this.displayName,
  });

  static int _asInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
    }
    return fallback;
  }

  factory _WaitingRoomEntry.fromJson(Map<String, dynamic> json) {
    return _WaitingRoomEntry(
      userId: _asInt(json['user_id'], 0),
      username: (json['username'] ?? '').toString(),
      displayName: (json['display_name'] ?? json['username'] ?? '').toString(),
    );
  }
}
