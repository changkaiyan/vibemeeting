part of '../meeting_room_page.dart';

extension _MeetingRoomChatLogic on _MeetingRoomPageState {
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
        .map((e) => _ChatMessage.fromJson(e as Map<String, dynamic>))
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
          .map((e) => _ChatMessage.fromJson(e as Map<String, dynamic>))
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
    final draftMessage = _ChatMessage(
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
      final msg = _ChatMessage.fromJson(data);
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
