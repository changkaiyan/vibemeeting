part of '../page.dart';

extension _MeetingRoomSessionLogic on _MeetingRoomPageState {
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
    final realtimeBotEnabled =
        _boolFromJson(data['realtime_bot_enabled'], false);
    final realtimeBotMuted = _boolFromJson(data['realtime_bot_muted'], false);
    final realtimeBotProvider = (data['realtime_bot_provider'] ?? 'openai')
        .toString()
        .trim()
        .toLowerCase();
    final realtimeBotBaseUrl =
        (data['realtime_bot_base_url'] ?? 'https://api.openai.com')
            .toString()
            .trim();
    final realtimeBotModel =
        (data['realtime_bot_model'] ?? 'gpt-realtime').toString().trim();
    final realtimeBotVoice =
        (data['realtime_bot_voice'] ?? 'marin').toString().trim();
    final realtimeBotVolcWsUrl = (data['realtime_bot_volc_ws_url'] ??
            'wss://openspeech.bytedance.com/api/v3/realtime/dialogue')
        .toString()
        .trim();
    final realtimeBotVolcAppId =
        (data['realtime_bot_volc_app_id'] ?? '').toString().trim();
    final realtimeBotVolcResourceId =
        (data['realtime_bot_volc_resource_id'] ?? 'volc.speech.dialog')
            .toString()
            .trim();
    final realtimeBotVolcUid =
        (data['realtime_bot_volc_uid'] ?? '').toString().trim();
    final realtimeBotDisplayName =
        (data['realtime_bot_display_name'] ?? '实时语音助手').toString().trim();
    final realtimeBotApiKeySet =
        _boolFromJson(data['realtime_bot_api_key_set'], false);
    final realtimeBotVolcAppKeySet =
        _boolFromJson(data['realtime_bot_volc_app_key_set'], false);
    final realtimeBotVolcAccessKeySet =
        _boolFromJson(data['realtime_bot_volc_access_key_set'], false);
    final realtimeBotUserId = _intFromJson(data['realtime_bot_user_id'], 0);
    final realtimeBotIdentity =
        (data['realtime_bot_identity'] ?? '').toString().trim();
    final isSuperAdminUser = _boolFromJson(data['can_debug_token'], false);
    final currentUserRole = (data['current_user_role'] ?? '').toString();
    final meetingRefFromApi = (data['meeting_ref'] ?? '').toString().trim();
    final meetingIdFromApi = _intFromJson(data['id'], 0);
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
      _realtimeBotProvider =
          realtimeBotProvider == 'volcengine' ? 'volcengine' : 'openai';
      _realtimeBotBaseUrl = realtimeBotBaseUrl.isEmpty
          ? 'https://api.openai.com'
          : realtimeBotBaseUrl;
      _realtimeBotModel =
          realtimeBotModel.isEmpty ? 'gpt-realtime' : realtimeBotModel;
      _realtimeBotVoice = realtimeBotVoice.isEmpty ? 'marin' : realtimeBotVoice;
      _realtimeBotVolcWsUrl = realtimeBotVolcWsUrl.isEmpty
          ? 'wss://openspeech.bytedance.com/api/v3/realtime/dialogue'
          : realtimeBotVolcWsUrl;
      _realtimeBotVolcAppId = realtimeBotVolcAppId;
      _realtimeBotVolcResourceId = realtimeBotVolcResourceId.isEmpty
          ? 'volc.speech.dialog'
          : realtimeBotVolcResourceId;
      _realtimeBotVolcUid = realtimeBotVolcUid;
      _realtimeBotDisplayName =
          realtimeBotDisplayName.isEmpty ? '实时语音助手' : realtimeBotDisplayName;
      _realtimeBotIdentity = realtimeBotIdentity;
      _realtimeBotApiKeySet = realtimeBotApiKeySet;
      _realtimeBotVolcAppKeySet = realtimeBotVolcAppKeySet;
      _realtimeBotVolcAccessKeySet = realtimeBotVolcAccessKeySet;
      _realtimeBotUserId = realtimeBotUserId > 0 ? realtimeBotUserId : null;
      _isSuperAdminUser = isSuperAdminUser;
      if (!isSuperAdminUser) {
        _realtimeBotDebugPanelVisible = false;
      }
      _currentUserRole = currentUserRole;
      if (meetingIdFromApi > 0) {
        _resolvedMeetingId = meetingIdFromApi;
      }
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
    _syncRealtimeBotAudioIngress();
  }

  Future<_JoinTokenPayload> _fetchJoinToken() async {
    if (_isShareEntry && _accessToken.isEmpty) {
      try {
        await _ensureJwt(force: true);
      } catch (_) {}
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
    final nextGuestDisplayNameVersions = <String, int>{};
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
        final localProfileName = localProfile?.displayName.trim() ?? '';
        final localProfileVersion = localProfile?.displayNameVersion ?? 0;
        final localMetadataName = _participantDisplayNameFromMetadata(local);
        final localMetadataVersion =
            _participantDisplayNameVersionFromMetadata(local);
        final localLivekitName = local.name.trim();
        final useLocalProfileName = localProfileName.isNotEmpty &&
            localProfileVersion >= localMetadataVersion;
        final localName = useLocalProfileName
            ? localProfileName
            : localMetadataName.isNotEmpty
                ? localMetadataName
                : localLivekitName.isNotEmpty
                    ? localLivekitName
                    : cachedLocalName;
        if (localName.isNotEmpty) {
          nextRuntimeNames[local.identity] = localName;
        }
        if (_userIdFromIdentity(local.identity) == null &&
            localMetadataVersion > 0) {
          nextGuestDisplayNameVersions[local.identity] = localMetadataVersion;
        }
      }
      for (final participant in room.remoteParticipants.values) {
        connectedIdentities.add(participant.identity);
        final profile = _profileForIdentity(participant.identity);
        final cachedParticipantName =
            (previousRuntimeNames[participant.identity] ?? '').trim();
        final profileDisplayName = profile?.displayName.trim() ?? '';
        final profileVersion = profile?.displayNameVersion ?? 0;
        final metadataDisplayName =
            _participantDisplayNameFromMetadata(participant);
        final metadataDisplayNameVersion =
            _participantDisplayNameVersionFromMetadata(participant);
        final participantLivekitName = participant.name.trim();
        final useProfileName = profileDisplayName.isNotEmpty &&
            profileVersion >= metadataDisplayNameVersion;
        final participantName = useProfileName
            ? profileDisplayName
            : metadataDisplayName.isNotEmpty
                ? metadataDisplayName
                : participantLivekitName.isNotEmpty
                    ? participantLivekitName
                    : cachedParticipantName;
        if (participantName.isNotEmpty) {
          nextRuntimeNames[participant.identity] = participantName;
        }
        if (_userIdFromIdentity(participant.identity) == null &&
            metadataDisplayNameVersion > 0) {
          nextGuestDisplayNameVersions[participant.identity] =
              metadataDisplayNameVersion;
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
      _guestDisplayNameVersionsByIdentity.addAll(nextGuestDisplayNameVersions);
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
    _syncRealtimeBotAudioIngress();
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
          _stopWorkspacePolling();
          _stopWaitingRoomPolling();
          _stopRecordingStatusPolling();
          await _stopWorkspaceRealtimeStt(immediate: true);
          _syncRealtimeBotAudioIngress();
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
            connectOptions: const lk.ConnectOptions(autoSubscribe: true),
          )
          .timeout(_MeetingRoomPageState._roomConnectTimeout);
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
        if (token.meetingId > 0) {
          _resolvedMeetingId = token.meetingId;
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
      await _loadWorkspace(silent: true);
      if (_allowChat) {
        _startChatPolling();
      } else {
        _stopChatPolling();
      }
      _startMemberPolling();
      _startWorkspacePolling();
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
    _stopWorkspacePolling();
    await _stopWorkspaceRealtimeStt(immediate: true);
    await _stopRealtimeBotAudioIngress();
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
    _stopWorkspacePolling();
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
    _syncRealtimeBotAudioIngress();
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
      _syncRealtimeBotAudioIngress();
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
}
