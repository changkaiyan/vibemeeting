part of '../page.dart';

extension _MeetingRoomServiceLogic on _MeetingRoomPageState {
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
    final headers = <String, String>{'Content-Type': 'application/json'};
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
        res = await http.post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? {}),
        );
        break;
      case 'PATCH':
        res = await http.patch(
          uri,
          headers: headers,
          body: jsonEncode(body ?? {}),
        );
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
      throw MeetingApiException(
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
      final next = <int, MeetingMemberProfile>{};
      for (final row in list) {
        final item =
            MeetingMemberProfile.fromJson(row as Map<String, dynamic>);
        next[item.userId] = item;
      }
      if (!mounted) return;
      setState(() {
        final merged = <int, MeetingMemberProfile>{...next};
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
    _memberTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_loadMeetingMembers());
      if (_requiresAuth) {
        unawaited(_loadMeetingInfo());
        if (_isModerator) {
          unawaited(_loadWaitingRoomEntriesForModerator(silent: true));
        }
      }
    });
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
    if (_isShareEntry && localIdentity != null && localUserId == null) {
      var expectedVersion = _guestDisplayNameVersionsByIdentity[localIdentity];
      try {
        final res = await _request(
          'PATCH',
          _publicMyDisplayNameApiPath(),
          body: {
            'display_name': name,
            if (expectedVersion != null)
              'expected_display_name_version': expectedVersion,
          },
          requireAuth: false,
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
        if (mounted && resolvedVersion > 0) {
          setState(() {
            _guestDisplayNameVersionsByIdentity[localIdentity] =
                resolvedVersion;
          });
        }
        _applyIdentityDisplayNameLocally(
          localIdentity,
          nextName,
          displayNameVersion: resolvedVersion > 0 ? resolvedVersion : null,
        );
        try {
          await _setLocalDisplayNameMetadata(
            nextName,
            displayNameVersion: resolvedVersion > 0 ? resolvedVersion : null,
          );
        } catch (_) {}
      } on MeetingApiException catch (e) {
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
              _guestDisplayNameVersionsByIdentity[localIdentity] =
                  currentVersion;
            });
          }
          if (currentName.isNotEmpty) {
            _applyIdentityDisplayNameLocally(
              localIdentity,
              currentName,
              displayNameVersion: currentVersion > 0 ? currentVersion : null,
            );
            try {
              await _setLocalDisplayNameMetadata(
                currentName,
                displayNameVersion: currentVersion > 0 ? currentVersion : null,
              );
            } catch (_) {}
          }
        }
        rethrow;
      }
      return;
    }
    if (_hasPrivateMeetingApiScope && localUserId != null) {
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
          if (localParticipant != null) {
            try {
              await _setLocalDisplayNameMetadata(
                nextName,
                displayNameVersion:
                    resolvedVersion > 0 ? resolvedVersion : null,
              );
            } catch (_) {}
          }
        } else if (mounted) {
          setState(() {
            _meetingDisplayName = nextName;
          });
        }
      } on MeetingApiException catch (e) {
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
              if (localParticipant != null) {
                try {
                  await _setLocalDisplayNameMetadata(
                    currentName,
                    displayNameVersion:
                        currentVersion > 0 ? currentVersion : null,
                  );
                } catch (_) {}
              }
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
      } catch (_) {}
    }
    var metadataSynced = false;
    if (localParticipant != null) {
      try {
        await _setLocalDisplayNameMetadata(name, bumpVersionIfMissing: true);
        metadataSynced = true;
      } catch (_) {}
    }
    if (localIdentity != null) {
      if (!metadataSynced) {
        _applyIdentityDisplayNameLocally(
          localIdentity,
          name,
          userId: localUserId,
        );
      }
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
    if (!_canUseModeratorControls || payload.isEmpty) return;
    final res = await _request(
      'PATCH',
      _meetingControlsApiPath(),
      body: payload,
    );
    await _jsonOrThrow(res);
    await _refreshModerationState(reloadMessages: true);
  }

  Future<void> _patchMeetingAiControls(Map<String, dynamic> payload) async {
    if (!_canUseModeratorControls || payload.isEmpty) return;
    final res = await _request(
      'PATCH',
      _meetingAiControlsApiPath(),
      body: payload,
    );
    await _jsonOrThrow(res);
    await _refreshModerationState(reloadMessages: true);
  }

  Future<Map<String, dynamic>> _testMeetingAiConnectivity({
    required String provider,
    String baseUrl = '',
    String model = '',
    String voice = '',
    String apiKey = '',
    String volcWsUrl = '',
    String volcAppId = '',
    String volcAppKey = '',
    String volcAccessKey = '',
    String volcResourceId = '',
    String volcUid = '',
    String? prompt,
  }) async {
    final key = apiKey.trim();
    final payload = <String, dynamic>{'provider': provider.trim()};
    final normalizedBaseUrl = baseUrl.trim();
    final normalizedModel = model.trim();
    final normalizedVoice = voice.trim();
    final normalizedVolcWsUrl = volcWsUrl.trim();
    final normalizedVolcAppId = volcAppId.trim();
    final normalizedVolcAppKey = volcAppKey.trim();
    final normalizedVolcAccessKey = volcAccessKey.trim();
    final normalizedVolcResourceId = volcResourceId.trim();
    final normalizedVolcUid = volcUid.trim();
    if (normalizedBaseUrl.isNotEmpty) payload['base_url'] = normalizedBaseUrl;
    if (normalizedModel.isNotEmpty) payload['model'] = normalizedModel;
    if (normalizedVoice.isNotEmpty) payload['voice'] = normalizedVoice;
    if (normalizedVolcWsUrl.isNotEmpty) {
      payload['volc_ws_url'] = normalizedVolcWsUrl;
    }
    if (normalizedVolcAppId.isNotEmpty) {
      payload['volc_app_id'] = normalizedVolcAppId;
    }
    if (normalizedVolcAppKey.isNotEmpty) {
      payload['volc_app_key'] = normalizedVolcAppKey;
    }
    if (normalizedVolcAccessKey.isNotEmpty) {
      payload['volc_access_key'] = normalizedVolcAccessKey;
    }
    if (normalizedVolcResourceId.isNotEmpty) {
      payload['volc_resource_id'] = normalizedVolcResourceId;
    }
    if (normalizedVolcUid.isNotEmpty) {
      payload['volc_uid'] = normalizedVolcUid;
    }
    final res = await _request(
      'POST',
      _meetingAiControlsTestApiPath(),
      body: <String, dynamic>{
        ...payload,
        if (key.isNotEmpty) 'api_key': key,
        if ((prompt ?? '').trim().isNotEmpty) 'prompt': prompt!.trim(),
      },
    );
    return await _jsonOrThrow(res) as Map<String, dynamic>;
  }
}
