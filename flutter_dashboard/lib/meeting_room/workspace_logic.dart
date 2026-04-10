part of '../meeting_room_page.dart';

extension _MeetingRoomWorkspaceLogic on _MeetingRoomPageState {
  void _handleStartWorkspaceRealtimeSttTap() {
    if (mounted) {
      setState(() {
        _workspaceSttDebugStartTapCount += 1;
        _workspaceSttDebugLastAction = 'tap-start';
        if (_workspaceSttDebugState == 'idle') {
          _workspaceSttDebugState = 'start-tapped';
        }
      });
    } else {
      _workspaceSttDebugStartTapCount += 1;
      _workspaceSttDebugLastAction = 'tap-start';
      if (_workspaceSttDebugState == 'idle') {
        _workspaceSttDebugState = 'start-tapped';
      }
    }
    unawaited(_startWorkspaceRealtimeStt());
  }

  void _handleStopWorkspaceRealtimeSttTap() {
    if (mounted) {
      setState(() {
        _workspaceSttDebugStopTapCount += 1;
        _workspaceSttDebugLastAction = 'tap-stop';
      });
    } else {
      _workspaceSttDebugStopTapCount += 1;
      _workspaceSttDebugLastAction = 'tap-stop';
    }
    unawaited(_stopWorkspaceRealtimeStt());
  }

  void _startWorkspacePolling() {
    if (!_hasPrivateMeetingApiScope || !_connected) return;
    _stopWorkspacePolling();
    _workspaceTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_loadWorkspace(silent: true));
    });
  }

  void _stopWorkspacePolling() {
    _workspaceTimer?.cancel();
    _workspaceTimer = null;
  }

  Future<void> _loadWorkspace({bool silent = false}) async {
    if (!_hasPrivateMeetingApiScope || !_connected || _workspaceLoading) return;
    _workspaceLoading = true;
    try {
      final responses = await Future.wait<http.Response>([
        _request('GET', _meetingWorkspaceAgentsApiPath()),
        _request('GET', _meetingWorkspaceCurrentContextApiPath()),
        _request('GET', _meetingWorkspaceTranscriptsApiPath(limit: 80)),
        _request('GET', _meetingWorkspaceArtifactsApiPath(limit: 20)),
      ]);
      final agents = (await _jsonOrThrow(responses[0]) as List<dynamic>)
          .map(
            (e) => _WorkspaceAgentSession.fromJson(e as Map<String, dynamic>),
          )
          .toList();
      final context = _WorkspaceContextSnapshot.fromJson(
        await _jsonOrThrow(responses[1]) as Map<String, dynamic>,
      );
      final transcripts = (await _jsonOrThrow(responses[2]) as List<dynamic>)
          .map(
            (e) =>
                _WorkspaceTranscriptChunk.fromJson(e as Map<String, dynamic>),
          )
          .toList();
      final artifacts = (await _jsonOrThrow(responses[3]) as List<dynamic>)
          .map((e) => _WorkspaceArtifact.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _workspaceAgentSessions = agents;
        _workspaceContext = context;
        _workspaceTranscripts = transcripts;
        _workspaceArtifacts = artifacts;
        _workspaceReady = true;
      });
    } catch (e) {
      if (!silent) {
        _setStatus('加载会议工作区失败：${_friendlyError(e)}');
      }
    } finally {
      _workspaceLoading = false;
    }
  }

  _WorkspaceAgentSession? _workspaceAgentSessionFor(String agentType) {
    for (final session in _workspaceAgentSessions) {
      if (session.agentType == agentType) return session;
    }
    return null;
  }

  String _workspaceSttWebsocketUrl(String token) {
    final scheme = Uri.base.scheme == 'https' ? 'wss' : 'ws';
    final host = Uri.base.host;
    final port = Uri.base.hasPort ? ':${Uri.base.port}' : '';
    final path = _meetingWorkspaceRealtimeSttWebsocketPath();
    return '$scheme://$host$port$path?token=${Uri.encodeQueryComponent(token)}';
  }

  Future<void> _connectWorkspaceAgent(String agentType) async {
    if (!_hasPrivateMeetingApiScope) {
      _setStatus('当前入口不支持会议工作区能力');
      return;
    }
    try {
      await _request(
        'POST',
        _meetingWorkspaceAgentsApiPath(),
        body: <String, dynamic>{'agent_type': agentType},
      ).then(_jsonOrThrow);
      await _loadWorkspace(silent: true);
      _setStatus('$agentType 已连接到会议工作区');
    } catch (e) {
      _setStatus('连接 $agentType 失败：${_friendlyError(e)}');
    }
  }

  Future<void> _runWorkspaceAgentAction(
    String agentType,
    String taskType, {
    String instruction = '',
    List<int>? chunkIds,
  }) async {
    if (!_hasPrivateMeetingApiScope) {
      _setStatus('当前入口不支持会议工作区能力');
      return;
    }
    try {
      await _request(
        'POST',
        _meetingWorkspaceAgentActionsApiPath(),
        body: <String, dynamic>{
          'agent_type': agentType,
          'task_type': taskType,
          'instruction': instruction,
          'chunk_ids': chunkIds ?? const <int>[],
        },
      ).then(_jsonOrThrow);
      await _loadWorkspace(silent: true);
      _setStatus('$agentType 已完成 $taskType');
    } catch (e) {
      _setStatus('Agent 执行失败：${_friendlyError(e)}');
    }
  }

  Future<void> _addWorkspaceManualTranscript() async {
    final text = _workspaceTranscriptController.text.trim();
    if (text.isEmpty || !_hasPrivateMeetingApiScope) return;
    final speaker = _meetingDisplayName.trim().isNotEmpty
        ? _meetingDisplayName.trim()
        : (_defaultDisplayName.trim().isNotEmpty
            ? _defaultDisplayName.trim()
            : '我');
    try {
      await _request(
        'POST',
        _meetingWorkspaceTranscriptsApiPath(),
        body: <String, dynamic>{
          'speaker_name': speaker,
          'text': text,
          'source': 'manual',
          'is_final': true,
        },
      ).then(_jsonOrThrow);
      _workspaceTranscriptController.clear();
      await _loadWorkspace(silent: true);
      _setStatus('已添加会议记录');
    } catch (e) {
      _setStatus('添加会议记录失败：${_friendlyError(e)}');
    }
  }

  Future<void> _clearWorkspaceRealtimeSttResources() async {
    await _workspaceSttDataSubscription?.cancel();
    await _workspaceSttStopSubscription?.cancel();
    await _workspaceSttMessageSubscription?.cancel();
    await _workspaceSttOpenSubscription?.cancel();
    await _workspaceSttCloseSubscription?.cancel();
    await _workspaceSttErrorSubscription?.cancel();
    _workspaceSttDataSubscription = null;
    _workspaceSttStopSubscription = null;
    _workspaceSttMessageSubscription = null;
    _workspaceSttOpenSubscription = null;
    _workspaceSttCloseSubscription = null;
    _workspaceSttErrorSubscription = null;
    try {
      _workspaceSttRecorder?.stop();
    } catch (_) {}
    _workspaceSttRecorder = null;
    try {
      _workspaceSttSocket?.close();
    } catch (_) {}
    _workspaceSttSocket = null;
    _workspaceSttStream?.getTracks().forEach((track) {
      try {
        track.stop();
      } catch (_) {}
    });
    _workspaceSttStream = null;
    _workspaceSttRecorderStopCompleter = null;
    _workspaceSttFlushDataCompleter = null;
    _workspacePendingAudioChunkSends = 0;
    if (mounted) {
      setState(() {
        _workspaceSttActive = false;
        _workspaceSttStopping = false;
        _workspacePartialText = '';
        _workspaceSttDebugState = 'idle';
        _workspaceSttDebugMimeType = '';
        _workspaceSttDebugBlobEventCount = 0;
        _workspaceSttDebugLastBlobSize = 0;
        _workspaceSttDebugLastError = '';
        _workspaceSttDebugWsState = 'not-created';
        _workspaceSttDebugAudioTrackCount = 0;
        _workspaceSttDebugLastAction = 'resources-cleared';
      });
    }
  }

  Future<void> _startWorkspaceRealtimeStt() async {
    if (_workspaceSttActive) return;
    if (!_connected) {
      _setStatus('请先加入会议再启动实时字幕');
      return;
    }
    if (!_hasPrivateMeetingApiScope) {
      _setStatus('当前入口不支持实时字幕工作区能力');
      return;
    }
    try {
      if (mounted) {
        setState(() {
          _workspaceSttDebugState = 'jwt';
          _workspaceSttDebugLastError = '';
          _workspaceSttDebugWsState = 'not-created';
          _workspaceSttDebugAudioTrackCount = 0;
          _workspaceSttDebugLastAction = 'start-entered';
        });
      }
      final token = await _ensureJwt();
      if (mounted) {
        setState(() {
          _workspaceSttDebugState = 'media-devices';
        });
      }
      final mediaDevices = html.window.navigator.mediaDevices;
      if (mediaDevices == null) {
        throw Exception('当前浏览器不支持 MediaDevices');
      }
      if (mounted) {
        setState(() {
          _workspaceSttDebugState = 'gum-request';
        });
      }
      final stream = await mediaDevices
          .getUserMedia(<String, dynamic>{'audio': true, 'video': false});
      if (mounted) {
        setState(() {
          _workspaceSttDebugState = 'gum-ok';
          _workspaceSttDebugAudioTrackCount = stream.getAudioTracks().length;
        });
      }
      if (stream.getAudioTracks().isEmpty) {
        throw Exception('浏览器没有返回音频轨道');
      }
      if (mounted) {
        setState(() {
          _workspaceSttDebugState = 'ws-connecting';
        });
      }
      final socket = html.WebSocket(_workspaceSttWebsocketUrl(token));
      _workspaceSttSocket = socket;
      _workspaceSttStream = stream;
      _workspaceSttStopping = false;
      if (mounted) {
        setState(() {
          _workspaceSttDebugWsState =
              workspaceSttReadyStateLabel(socket.readyState);
        });
      }

      final openCompleter = Completer<void>();
      _workspaceSttOpenSubscription = socket.onOpen.listen((_) {
        if (mounted) {
          setState(() {
            _workspaceSttDebugState = 'ws-open';
            _workspaceSttDebugWsState =
                workspaceSttReadyStateLabel(socket.readyState);
          });
        }
        if (!openCompleter.isCompleted) {
          openCompleter.complete();
        }
      });
      _workspaceSttErrorSubscription = socket.onError.listen((_) {
        if (mounted) {
          setState(() {
            _workspaceSttDebugState = 'ws-error';
            _workspaceSttDebugWsState =
                workspaceSttReadyStateLabel(socket.readyState);
          });
        }
        if (!openCompleter.isCompleted) {
          openCompleter.completeError(
            Exception('Realtime STT websocket failed'),
          );
        }
      });
      _workspaceSttCloseSubscription = socket.onClose.listen((_) {
        if (mounted) {
          setState(() {
            _workspaceSttDebugWsState =
                workspaceSttReadyStateLabel(socket.readyState);
          });
        }
        unawaited(_clearWorkspaceRealtimeSttResources());
      });
      _workspaceSttMessageSubscription = socket.onMessage.listen((event) async {
        final data = event.data;
        if (data is! String) return;
        try {
          final payload = jsonDecode(data) as Map<String, dynamic>;
          final messageType = (payload['type'] ?? '').toString();
          if (!mounted) return;
          if (messageType == 'session_started') {
            setState(() {
              _workspaceSttDebugLastAction = 'ws-session-started';
            });
            _setStatus('实时字幕会话已启动');
            return;
          }
          if (messageType == 'partial_transcript') {
            setState(() {
              _workspacePartialText = (payload['text'] ?? '').toString();
              _workspaceSttDebugLastAction = 'ws-partial';
            });
            return;
          }
          if (messageType == 'final_transcript') {
            setState(() {
              _workspacePartialText = '';
              _workspaceSttDebugLastAction = 'ws-final';
            });
            await _loadWorkspace(silent: true);
            if (_workspaceSttStopping) {
              try {
                socket.close();
              } catch (_) {}
            }
            return;
          }
          if (messageType == 'error') {
            setState(() {
              _workspaceSttDebugLastAction = 'ws-error-message';
            });
            _setStatus((payload['detail'] ?? 'Realtime STT error').toString());
          }
        } catch (_) {}
      });

      await openCompleter.future.timeout(const Duration(seconds: 10));
      if (mounted) {
        setState(() {
          _workspaceSttDebugState = 'recorder-creating';
          _workspaceSttDebugWsState =
              workspaceSttReadyStateLabel(socket.readyState);
        });
      }
      final mimeType =
          html.MediaRecorder.isTypeSupported('audio/webm') ? 'audio/webm' : '';
      final recorder = mimeType.isNotEmpty
          ? html.MediaRecorder(stream, <String, dynamic>{'mimeType': mimeType})
          : html.MediaRecorder(stream);
      _workspaceSttRecorder = recorder;
      if (mounted) {
        setState(() {
          _workspaceSttDebugState = 'recorder-created';
          _workspaceSttDebugMimeType =
              mimeType.isNotEmpty ? mimeType : 'default';
          _workspaceSttDebugBlobEventCount = 0;
          _workspaceSttDebugLastBlobSize = 0;
          _workspaceSttDebugLastError = '';
          _workspaceSttDebugWsState =
              workspaceSttReadyStateLabel(socket.readyState);
          _workspaceSttDebugLastAction = 'recorder-created';
        });
      }
      final identity = (_room?.localParticipant?.identity ?? '').trim();
      socket.send(jsonEncode(<String, dynamic>{
        'type': 'start',
        'speaker_name': identity.isNotEmpty ? identity : 'Me',
        'speaker_identity': identity.isNotEmpty ? identity : 'me',
      }));
      _workspaceSttDataSubscription = recorder.on['dataavailable'].listen(
        (event) async {
          final blob = (event as html.BlobEvent).data;
          if (mounted) {
            setState(() {
              _workspaceSttDebugState = 'dataavailable';
              _workspaceSttDebugBlobEventCount += 1;
              _workspaceSttDebugLastBlobSize = blob?.size ?? 0;
              _workspaceSttDebugWsState =
                  workspaceSttReadyStateLabel(_workspaceSttSocket?.readyState);
              _workspaceSttDebugLastAction = 'blob-event';
              if ((blob?.type ?? '').isNotEmpty) {
                _workspaceSttDebugMimeType = blob!.type;
              }
            });
          }
          if (blob == null) return;
          _workspaceSttFlushDataCompleter?.complete();
          _workspaceSttFlushDataCompleter = null;
          if (blob.size <= 0) return;
          if (_workspaceSttSocket == null ||
              _workspaceSttSocket!.readyState != html.WebSocket.OPEN) {
            return;
          }
          _workspacePendingAudioChunkSends += 1;
          try {
            final bytes = await _blobToBytes(blob);
            _workspaceSttSocket!.send(
              jsonEncode(<String, dynamic>{
                'type': 'audio_chunk',
                'mime_type': blob.type.isNotEmpty
                    ? blob.type
                    : (mimeType.isNotEmpty ? mimeType : 'audio/webm'),
                'data_base64': base64Encode(bytes),
              }),
            );
            if (mounted) {
              setState(() {
                _workspaceSttDebugLastAction = 'chunk-sent';
                _workspaceSttDebugLastError = '';
              });
            }
          } catch (e) {
            final errorText = _friendlyError(e);
            if (mounted) {
              setState(() {
                _workspaceSttDebugState = 'failed:chunk-send';
                _workspaceSttDebugLastAction = 'chunk-send-failed';
                _workspaceSttDebugLastError = errorText;
              });
            } else {
              _workspaceSttDebugLastError = errorText;
            }
          } finally {
            _workspacePendingAudioChunkSends =
                (_workspacePendingAudioChunkSends - 1).clamp(0, 1 << 20);
          }
        },
      );
      _workspaceSttStopSubscription = recorder.on['stop'].listen((_) {
        if (mounted) {
          setState(() {
            _workspaceSttDebugState = 'recorder-stopped';
            _workspaceSttDebugWsState =
                workspaceSttReadyStateLabel(_workspaceSttSocket?.readyState);
            _workspaceSttDebugLastAction = 'recorder-stop-event';
          });
        }
        _workspaceSttRecorderStopCompleter?.complete();
      });
      recorder.start(1000);
      if (!mounted) return;
      setState(() {
        _workspaceSttActive = true;
        _workspaceSttStopping = false;
        _workspaceSttDebugState = 'recording';
        _workspaceSttDebugWsState =
            workspaceSttReadyStateLabel(_workspaceSttSocket?.readyState);
        _workspaceSttDebugLastAction = 'recorder-started';
      });
      _setStatus('实时字幕已启动');
    } catch (e) {
      final errorText = _friendlyError(e);
      if (mounted) {
        setState(() {
          if (_workspaceSttDebugState == 'idle') {
            _workspaceSttDebugState = 'failed';
          } else {
            _workspaceSttDebugState = 'failed:${_workspaceSttDebugState}';
          }
          _workspaceSttDebugLastError = errorText;
          _workspaceSttDebugWsState =
              workspaceSttReadyStateLabel(_workspaceSttSocket?.readyState);
          _workspaceSttDebugAudioTrackCount =
              _workspaceSttStream?.getAudioTracks().length ?? 0;
          _workspaceSttDebugLastAction = 'start-failed';
        });
      } else {
        _workspaceSttDebugLastError = errorText;
      }
      await _clearWorkspaceRealtimeSttResources();
      if (mounted) {
        setState(() {
          if (_workspaceSttDebugState == 'idle') {
            _workspaceSttDebugState = 'failed';
          }
          _workspaceSttDebugLastError = errorText;
        });
      } else {
        _workspaceSttDebugLastError = errorText;
      }
      _setStatus('启动实时字幕失败：$errorText');
    }
  }

  Future<void> _stopWorkspaceRealtimeStt({bool immediate = false}) async {
    if (!_workspaceSttActive &&
        _workspaceSttSocket == null &&
        _workspaceSttStream == null) {
      return;
    }
    _workspaceSttStopping = true;
    if (mounted) {
      setState(() {
        _workspaceSttDebugState = 'stopping';
        _workspaceSttDebugWsState =
            workspaceSttReadyStateLabel(_workspaceSttSocket?.readyState);
        _workspaceSttDebugLastAction = 'stop-entered';
      });
    }
    final recorder = _workspaceSttRecorder;
    try {
      if (recorder != null && recorder.state != 'inactive') {
        final flushCompleter = Completer<void>();
        final stopCompleter = Completer<void>();
        _workspaceSttFlushDataCompleter = flushCompleter;
        _workspaceSttRecorderStopCompleter = stopCompleter;
        try {
          recorder.requestData();
          if (mounted) {
            setState(() {
              _workspaceSttDebugState = 'request-data';
              _workspaceSttDebugWsState =
                  workspaceSttReadyStateLabel(_workspaceSttSocket?.readyState);
              _workspaceSttDebugLastAction = 'request-data';
            });
          }
        } catch (_) {}
        await flushCompleter.future.timeout(
          const Duration(milliseconds: 800),
          onTimeout: () {},
        );
        recorder.stop();
        await stopCompleter.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (_workspacePendingAudioChunkSends > 0 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    } catch (_) {}
    _workspaceSttRecorderStopCompleter = null;
    _workspaceSttFlushDataCompleter = null;
    final socket = _workspaceSttSocket;
    if (socket != null && socket.readyState == html.WebSocket.OPEN) {
      if (immediate) {
        try {
          socket.close();
        } catch (_) {}
      } else {
        socket.send(jsonEncode(const <String, dynamic>{'type': 'stop'}));
      }
    } else {
      await _clearWorkspaceRealtimeSttResources();
    }
    if (mounted) {
      setState(() {});
    }
  }
}
