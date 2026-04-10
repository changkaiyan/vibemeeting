part of '../page.dart';

extension _MeetingRoomModerationLogic on _MeetingRoomPageState {
  Future<void> _muteAllMembers() async {
    if (!_canUseModeratorControls) return;
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
    String identity,
    bool muted,
  ) async {
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
    String identity,
    bool disabled,
  ) async {
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
          payload['current_display_name_version'],
          expectedVersion ?? 1,
        );
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
    String identity,
    String displayName,
  ) async {
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
            _applyIdentityDisplayNameLocally(
              identity,
              currentName,
              displayNameVersion: currentVersion > 0 ? currentVersion : null,
            );
          }
        }
      } catch (_) {}
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
        displayNameVersion: resolvedVersion > 0 ? resolvedVersion : null,
      );
    } on _ApiException catch (e) {
      if (e.statusCode == 409 && e.payload != null) {
        final payload = e.payload!;
        final currentName =
            (payload['current_display_name'] ?? '').toString().trim();
        final currentVersion = _intFromJson(
          payload['current_display_name_version'],
          expectedVersion ?? 1,
        );
        if (mounted && currentVersion > 0) {
          setState(() {
            _guestDisplayNameVersionsByIdentity[identity] = currentVersion;
          });
        }
        if (currentName.isNotEmpty) {
          _applyIdentityDisplayNameLocally(
            identity,
            currentName,
            displayNameVersion: currentVersion > 0 ? currentVersion : null,
          );
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
                          decoration:
                              const InputDecoration(labelText: '新主持人'),
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
    final res = await _request('GET', _meetingWaitingRoomApiPath());
    final list = await _jsonOrThrow(res) as List<dynamic>;
    return list
        .map((item) => _WaitingRoomEntry.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> _loadWaitingRoomEntriesForModerator({
    bool silent = false,
  }) async {
    if (!_canUseModeratorControls) {
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
}
