part of '../page.dart';

extension _MeetingRoomChatLogic on _MeetingRoomPageState {
  List<ChatMessage> _mergeServerRowsWithPendingDrafts(
    List<ChatMessage> serverRows,
  ) {
    if (_pendingLocalDraftMessages.isEmpty) {
      return serverRows;
    }
    final merged = <ChatMessage>[...serverRows];
    final drafts = _pendingLocalDraftMessages.values.toList()
      ..sort((a, b) {
        final aTime = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bTime = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final byTime = aTime.compareTo(bTime);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });
    for (final draft in drafts) {
      final exists = merged.any((msg) => msg.id == draft.id);
      if (!exists) {
        merged.add(draft);
      }
    }
    return merged;
  }

  int _latestMessageIdFromRows(List<ChatMessage> rows) {
    var latest = 0;
    for (final row in rows) {
      if (row.id > latest) {
        latest = row.id;
      }
    }
    return latest;
  }

  bool _sameMessageSnapshot(List<ChatMessage> rows) {
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

  bool _isRealtimeBotMessage(ChatMessage message) {
    if (message.isRealtimeBot) return true;
    final botUserId = _realtimeBotUserId;
    if (botUserId == null) return false;
    return message.senderUserId == botUserId;
  }

  Future<void> _playRealtimeBotAudio(ChatMessage message) async {
    if (!_isRealtimeBotMessage(message)) return;
    if (_isRealtimeBotMutedForPlayback()) return;
    if (_playedRealtimeBotAudioMessageIds.contains(message.id)) return;
    if (_playingRealtimeBotAudioMessageIds.contains(message.id)) return;
    final audioBase64 = message.audioBase64.trim();
    if (audioBase64.isEmpty) return;
    _playingRealtimeBotAudioMessageIds.add(message.id);
    _realtimeBotPlaybackActive = _playingRealtimeBotAudioMessageIds.isNotEmpty;
    html.AudioElement? audio;
    String? objectUrl;
    var cleaned = false;
    final playbackDone = Completer<void>();

    void cleanupPlayback() {
      if (cleaned) return;
      cleaned = true;
      if (objectUrl != null && objectUrl.isNotEmpty) {
        try {
          html.Url.revokeObjectUrl(objectUrl);
        } catch (_) {}
      }
      try {
        audio?.remove();
      } catch (_) {}
      if (!playbackDone.isCompleted) {
        playbackDone.complete();
      }
    }

    try {
      var bytes = base64Decode(audioBase64);
      var mimeType = message.audioMimeType.trim().isEmpty
          ? 'audio/wav'
          : message.audioMimeType.trim();
      final loweredMime = mimeType.toLowerCase();
      final shouldConvertPcm = loweredMime.contains('audio/pcm') ||
          loweredMime.contains('audio/l16') ||
          loweredMime.contains('audio/raw') ||
          (loweredMime == 'audio/wav' && !_looksLikeWav(bytes));
      if (shouldConvertPcm) {
        bytes = _pcm16ToWavBytes(bytes, sampleRate: 24000, channels: 1);
        mimeType = 'audio/wav';
      }
      final blob = html.Blob(<dynamic>[bytes], mimeType);
      objectUrl = html.Url.createObjectUrlFromBlob(blob);
      audio = html.AudioElement(objectUrl)
        ..autoplay = true
        ..preload = 'auto';
      audio.onEnded.first.then((_) => cleanupPlayback());
      audio.onError.first.then((_) => cleanupPlayback());
      await audio.play();
      _playedRealtimeBotAudioMessageIds.add(message.id);
      await playbackDone.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          cleanupPlayback();
        },
      );
    } catch (e) {
      _updateRealtimeBotDebug(
        event: 'audio_play_failed',
        error: _friendlyError(e),
        forceRebuild: true,
      );
      _setStatus('AI语音播放失败：${_friendlyError(e)}');
    }
    cleanupPlayback();
    _playingRealtimeBotAudioMessageIds.remove(message.id);
    _realtimeBotPlaybackActive = _playingRealtimeBotAudioMessageIds.isNotEmpty;
  }

  void _playRealtimeBotAudioForNewMessages(
    List<ChatMessage> rows,
    int previousLatest,
  ) {
    if (previousLatest <= 0) return;
    if (_isRealtimeBotMutedForPlayback()) return;
    for (final message in rows) {
      if (message.id <= previousLatest) continue;
      if (!_isRealtimeBotMessage(message)) continue;
      if (message.audioBase64.trim().isEmpty) continue;
      unawaited(_playRealtimeBotAudio(message));
    }
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

  Future<void> _loadMessages() async {
    final localProfile = _localMemberProfile;
    final canChat = _isModerator || (localProfile?.allowChat ?? _allowChat);
    if (!canChat) {
      if (!mounted) return;
      setState(() {
        _messages.clear();
        _latestMessageId = 0;
        _pendingLocalDraftMessages.clear();
        _playedRealtimeBotAudioMessageIds.clear();
        _playingRealtimeBotAudioMessageIds.clear();
        _realtimeBotPlaybackActive = false;
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
    final serverRows = list
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
    final rows = _mergeServerRowsWithPendingDrafts(serverRows);
    if (!mounted) return;
    final previousLatest = _latestMessageId;
    setState(() {
      _messages
        ..clear()
        ..addAll(rows);
      _latestMessageId = _latestMessageIdFromRows(_messages);
      _playedRealtimeBotAudioMessageIds.removeWhere(
        (messageId) => !_messages.any((message) => message.id == messageId),
      );
      _playingRealtimeBotAudioMessageIds.removeWhere(
        (messageId) => !_messages.any((message) => message.id == messageId),
      );
      _realtimeBotPlaybackActive =
          _playingRealtimeBotAudioMessageIds.isNotEmpty;
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
      final serverRows = list
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
      final rows = _mergeServerRowsWithPendingDrafts(serverRows);
      if (!mounted || _sameMessageSnapshot(rows)) return;
      final previousLatest = _latestMessageId;
      setState(() {
        _messages
          ..clear()
          ..addAll(rows);
        _latestMessageId = _latestMessageIdFromRows(_messages);
        _playedRealtimeBotAudioMessageIds.removeWhere(
          (messageId) => !_messages.any((message) => message.id == messageId),
        );
        _playingRealtimeBotAudioMessageIds.removeWhere(
          (messageId) => !_messages.any((message) => message.id == messageId),
        );
        _realtimeBotPlaybackActive =
            _playingRealtimeBotAudioMessageIds.isNotEmpty;
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
      } catch (_) {}
    }
    if (_isShareEntry && _localUserId == null && _accessToken.isEmpty) {
      _setStatus('访客链接模式下暂不支持发送聊天消息');
      return;
    }
    final content = _chatController.text.trim();
    if (content.isEmpty) return;
    final draftId = _localDraftMessageSequence;
    _localDraftMessageSequence -= 1;
    final localIdentity = _room?.localParticipant?.identity ?? '';
    final draftDisplayName = _displayNameForIdentity(
      localIdentity,
      fallback: _meetingDisplayName.trim().isEmpty
          ? (_defaultDisplayName.trim().isEmpty
              ? 'me'
              : _defaultDisplayName.trim())
          : _meetingDisplayName.trim(),
    );
    final draftMessage = ChatMessage(
      id: draftId,
      senderUserId: _localUserId ?? 0,
      senderUsername: localIdentity.isEmpty ? 'local' : localIdentity,
      senderDisplayName:
          draftDisplayName.trim().isEmpty ? 'me' : draftDisplayName,
      isRealtimeBot: false,
      audioMimeType: '',
      audioBase64: '',
      content: content,
      createdAt: DateTime.now(),
    );
    _pendingLocalDraftMessages[draftId] = draftMessage;
    if (mounted) {
      setState(() {
        _chatController.clear();
        _messages.add(draftMessage);
      });
      _scrollChatToBottom();
    }
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
      final msg = ChatMessage.fromJson(data);
      _pendingLocalDraftMessages.remove(draftId);
      if (!mounted) return;
      setState(() {
        final draftIdx = _messages.indexWhere((m) => m.id == draftId);
        final exists = _messages.any((m) => m.id == msg.id);
        if (draftIdx >= 0) {
          _messages[draftIdx] = msg;
        } else if (!exists) {
          _messages.add(msg);
        }
        if (msg.id > _latestMessageId) {
          _latestMessageId = msg.id;
        }
      });
      if (_isRealtimeBotMessage(msg)) {
        unawaited(_playRealtimeBotAudio(msg));
      }
      _scrollChatToBottom();
    } catch (e) {
      _pendingLocalDraftMessages.remove(draftId);
      if (mounted) {
        setState(() {
          _messages.removeWhere((m) => m.id == draftId);
          if (_chatController.text.trim().isEmpty) {
            _chatController.text = content;
            _chatController.selection = TextSelection.collapsed(
              offset: _chatController.text.length,
            );
          }
        });
      }
      _setStatus('发送消息失败：${_friendlyError(e)}');
    }
  }
}
