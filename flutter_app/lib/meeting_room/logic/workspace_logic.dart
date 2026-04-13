part of '../page.dart';

extension _MeetingRoomWorkspaceLogic on _MeetingRoomPageState {
  void _setWorkspaceSttRuntime(
    WorkspaceSttRuntimeState nextState, {
    bool rebuild = true,
  }) {
    if (!mounted || !rebuild) {
      _workspace.sttRuntime = nextState;
      return;
    }
    setState(() {
      _workspace.sttRuntime = nextState;
    });
  }

  void _handleStartWorkspaceRealtimeSttTap() {
    _setWorkspaceSttRuntime(_workspace.sttRuntime.afterStartTap(),
        rebuild: mounted);
    unawaited(_startWorkspaceRealtimeStt());
  }

  void _handleStopWorkspaceRealtimeSttTap() {
    _setWorkspaceSttRuntime(_workspace.sttRuntime.afterStopTap(),
        rebuild: mounted);
    unawaited(_stopWorkspaceRealtimeStt());
  }

  void _startWorkspacePolling() {
    if (!_hasPrivateMeetingApiScope || !_connected) return;
    _stopWorkspacePolling();
    _workspace.timer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_loadWorkspace(silent: true));
    });
  }

  void _stopWorkspacePolling() {
    _workspace.timer?.cancel();
    _workspace.timer = null;
  }

  Future<void> _loadWorkspace({bool silent = false}) async {
    if (!_hasPrivateMeetingApiScope || !_connected || _workspace.loading) return;
    _workspace.loading = true;
    try {
      final responses = await Future.wait<http.Response>([
        _request('GET', _meetingWorkspaceAgentsApiPath()),
        _request('GET', _meetingWorkspaceCurrentContextApiPath()),
        _request('GET', _meetingWorkspaceTranscriptsApiPath(limit: 80)),
        _request('GET', _meetingWorkspaceArtifactsApiPath(limit: 20)),
      ]);
      final agents = (await _jsonOrThrow(responses[0]) as List<dynamic>)
          .map(
            (e) => WorkspaceAgentSession.fromJson(e as Map<String, dynamic>),
          )
          .toList();
      final context = WorkspaceContextSnapshot.fromJson(
        await _jsonOrThrow(responses[1]) as Map<String, dynamic>,
      );
      final transcripts = (await _jsonOrThrow(responses[2]) as List<dynamic>)
          .map(
            (e) => WorkspaceTranscriptChunk.fromJson(e as Map<String, dynamic>),
          )
          .toList();
      final artifacts = (await _jsonOrThrow(responses[3]) as List<dynamic>)
          .map((e) => WorkspaceArtifact.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _workspace.agentSessions = agents;
        _workspace.context = context;
        _workspace.transcripts = transcripts;
        _workspace.artifacts = artifacts;
        _workspace.ready = true;
      });
    } catch (e) {
      if (!silent) {
        _setStatus('加载会议工作区失败：${_friendlyError(e)}');
      }
    } finally {
      _workspace.loading = false;
    }
  }

  WorkspaceAgentSession? _workspaceAgentSessionFor(String agentType) {
    for (final session in _workspace.agentSessions) {
      if (session.agentType == agentType) return session;
    }
    return null;
  }

  String _workspaceSttWebsocketUrl(String token) {
    return buildWorkspaceSttWebsocketUrl(
      origin: Uri.base,
      websocketPath: _meetingWorkspaceRealtimeSttWebsocketPath(),
      token: token,
    );
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
    final text = _workspace.transcriptController.text.trim();
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
      _workspace.transcriptController.clear();
      await _loadWorkspace(silent: true);
      _setStatus('已添加会议记录');
    } catch (e) {
      _setStatus('添加会议记录失败：${_friendlyError(e)}');
    }
  }

  Future<void> _clearWorkspaceRealtimeSttResources() async {
    await _workspace.sttSession.dataSubscription?.cancel();
    await _workspace.sttSession.stopSubscription?.cancel();
    await _workspace.sttSession.messageSubscription?.cancel();
    await _workspace.sttSession.openSubscription?.cancel();
    await _workspace.sttSession.closeSubscription?.cancel();
    await _workspace.sttSession.errorSubscription?.cancel();
    final captureController =
        _workspace.sttSession.captureController as WorkspaceSttPcmCaptureHandle?;
    if (captureController != null) {
      try {
        await captureController.stop();
      } catch (_) {}
    }
    try {
      (_workspace.sttSession.recorder as html.MediaRecorder?)?.stop();
    } catch (_) {}
    try {
      (_workspace.sttSession.socket as html.WebSocket?)?.close();
    } catch (_) {}
    if (captureController == null) {
      (_workspace.sttSession.stream as html.MediaStream?)?.getTracks().forEach((
        track,
      ) {
        try {
          track.stop();
        } catch (_) {}
      });
    }
    _workspace.resetSttRuntime();
    _setWorkspaceSttRuntime(_workspace.sttRuntime, rebuild: mounted);
  }

  void _attachWorkspaceSttSocketListeners(
    html.WebSocket socket,
    Completer<void> openCompleter,
  ) {
    _workspace.sttSession.openSubscription = socket.onOpen.listen((_) {
      _setWorkspaceSttRuntime(
        _workspace.sttRuntime.copyWith(
          debugState: 'ws-open',
          debugWsState: workspaceSttReadyStateLabel(socket.readyState),
        ),
        rebuild: mounted,
      );
      if (!openCompleter.isCompleted) {
        openCompleter.complete();
      }
    });
    _workspace.sttSession.errorSubscription = socket.onError.listen((_) {
      _setWorkspaceSttRuntime(
        _workspace.sttRuntime.copyWith(
          debugState: 'ws-error',
          debugWsState: workspaceSttReadyStateLabel(socket.readyState),
        ),
        rebuild: mounted,
      );
      if (!openCompleter.isCompleted) {
        openCompleter.completeError(
          Exception('Realtime STT websocket failed'),
        );
      }
    });
    _workspace.sttSession.closeSubscription = socket.onClose.listen((_) {
      _setWorkspaceSttRuntime(
        _workspace.sttRuntime.copyWith(
          debugWsState: workspaceSttReadyStateLabel(socket.readyState),
        ),
        rebuild: mounted,
      );
      unawaited(_clearWorkspaceRealtimeSttResources());
    });
    _workspace.sttSession.messageSubscription = socket.onMessage.listen(
      (event) async {
        final data = event.data;
        if (data is! String) return;
        final message = parseWorkspaceSttInboundMessage(data);
        if (message == null || !mounted) return;
        final effect = _workspace.sttController.handleInboundMessage(
          message,
          stopping: _workspace.sttRuntime.stopping,
        );
        if (effect.isNoop) {
          return;
        }
        _setWorkspaceSttRuntime(
          _workspace.sttRuntime.applyInboundEffect(effect),
        );
        if (effect.statusMessage != null && effect.statusMessage!.isNotEmpty) {
          _setStatus(effect.statusMessage!);
        }
        if (effect.shouldReloadWorkspace) {
          await _loadWorkspace(silent: true);
        }
        if (effect.shouldCloseSocket) {
          try {
            socket.close();
          } catch (_) {}
        }
      },
    );
  }

  void _sendWorkspaceSttStartMessage(html.WebSocket socket) {
    final speaker = resolveWorkspaceSttSpeaker(
      _room?.localParticipant?.identity ?? '',
    );
    socket.send(
      jsonEncode(
        workspaceSttStartMessage(
          speakerName: speaker.name,
          speakerIdentity: speaker.identity,
        ),
      ),
    );
  }

  Future<void> _startWorkspaceRealtimeSttWithWebm({
    required html.WebSocket socket,
  }) async {
    _setWorkspaceSttRuntime(
      _workspace.sttRuntime.copyWith(debugState: 'media-devices'),
      rebuild: mounted,
    );
    final mediaDevices = html.window.navigator.mediaDevices;
    if (mediaDevices == null) {
      throw Exception('当前浏览器不支持 MediaDevices');
    }
    _setWorkspaceSttRuntime(
      _workspace.sttRuntime.copyWith(debugState: 'gum-request'),
      rebuild: mounted,
    );
    final stream = await mediaDevices
        .getUserMedia(<String, dynamic>{'audio': true, 'video': false});
    _workspace.sttSession.stream = stream;
    _setWorkspaceSttRuntime(
      _workspace.sttRuntime.copyWith(
        debugState: 'gum-ok',
        debugAudioTrackCount: stream.getAudioTracks().length,
      ),
      rebuild: mounted,
    );
    if (stream.getAudioTracks().isEmpty) {
      throw Exception('浏览器没有返回音频轨道');
    }
    _setWorkspaceSttRuntime(
      _workspace.sttRuntime.copyWith(
        debugState: 'recorder-creating',
        debugWsState: workspaceSttReadyStateLabel(socket.readyState),
      ),
      rebuild: mounted,
    );
    final mimeType = preferredWorkspaceSttMimeType(
      isTypeSupported: html.MediaRecorder.isTypeSupported,
    );
    final recorder = mimeType.isNotEmpty
        ? html.MediaRecorder(stream, <String, dynamic>{'mimeType': mimeType})
        : html.MediaRecorder(stream);
    _workspace.sttSession.recorder = recorder;
    _setWorkspaceSttRuntime(
      _workspace.sttRuntime.enteredRecorderCreated(
        mimeType: mimeType.isNotEmpty ? mimeType : 'default',
        wsState: workspaceSttReadyStateLabel(socket.readyState),
      ),
      rebuild: mounted,
    );
    _sendWorkspaceSttStartMessage(socket);
    _workspace.sttSession.dataSubscription = recorder.on['dataavailable'].listen(
      (event) async {
        final blob = (event as html.BlobEvent).data;
        _setWorkspaceSttRuntime(
          _workspace.sttRuntime.observedBlobEvent(
            blobSize: blob?.size ?? 0,
            wsState: workspaceSttReadyStateLabel(
              (_workspace.sttSession.socket as html.WebSocket?)?.readyState,
            ),
            blobMimeType: blob?.type ?? '',
          ),
          rebuild: mounted,
        );
        if (blob == null) return;
        _workspace.sttSession.flushDataCompleter?.complete();
        _workspace.sttSession.flushDataCompleter = null;
        if (blob.size <= 0) return;
        final activeSocket = _workspace.sttSession.socket as html.WebSocket?;
        if (activeSocket == null ||
            activeSocket.readyState != html.WebSocket.OPEN) {
          return;
        }
        _workspace.sttSession.pendingAudioChunkSends += 1;
        try {
          final bytes = await _blobToBytes(blob);
          activeSocket.send(
            jsonEncode(
              workspaceSttAudioChunkMessage(
                mimeType: blob.type.isNotEmpty
                    ? blob.type
                    : (mimeType.isNotEmpty ? mimeType : 'audio/webm'),
                dataBase64: base64Encode(bytes),
              ),
            ),
          );
          _setWorkspaceSttRuntime(
            _workspace.sttRuntime.enteredChunkSent(),
            rebuild: mounted,
          );
        } catch (e) {
          final errorText = _friendlyError(e);
          _setWorkspaceSttRuntime(
            _workspace.sttRuntime.enteredChunkSendFailure(errorText),
            rebuild: mounted,
          );
        } finally {
          _workspace.sttSession.pendingAudioChunkSends =
              (_workspace.sttSession.pendingAudioChunkSends - 1).clamp(
            0,
            1 << 20,
          );
        }
      },
    );
    _workspace.sttSession.stopSubscription = recorder.on['stop'].listen((_) {
      _setWorkspaceSttRuntime(
        _workspace.sttRuntime.enteredRecorderStopped(
          wsState: workspaceSttReadyStateLabel(
            (_workspace.sttSession.socket as html.WebSocket?)?.readyState,
          ),
        ),
        rebuild: mounted,
      );
      _workspace.sttSession.recorderStopCompleter?.complete();
    });
    recorder.start(1000);
    _setWorkspaceSttRuntime(
      _workspace.sttRuntime.enteredRecording(
        wsState: workspaceSttReadyStateLabel(
          (_workspace.sttSession.socket as html.WebSocket?)?.readyState,
        ),
      ),
    );
  }

  Future<void> _startWorkspaceRealtimeSttWithPcm({
    required html.WebSocket socket,
  }) async {
    _setWorkspaceSttRuntime(
      _workspace.sttRuntime.copyWith(
        debugState: 'pcm-starting',
        debugWsState: workspaceSttReadyStateLabel(socket.readyState),
      ),
      rebuild: mounted,
    );
    _sendWorkspaceSttStartMessage(socket);
    final captureResult = await startWorkspaceSttPcmCapture(
      onMessage: (message) {
        final activeSocket = _workspace.sttSession.socket as html.WebSocket?;
        if (activeSocket == null ||
            activeSocket.readyState != html.WebSocket.OPEN) {
          return;
        }
        _workspace.sttSession.pendingAudioChunkSends += 1;
        try {
          activeSocket.send(jsonEncode(message));
          _setWorkspaceSttRuntime(
            _workspace.sttRuntime.enteredChunkSent(),
            rebuild: mounted,
          );
        } catch (e) {
          _setWorkspaceSttRuntime(
            _workspace.sttRuntime.enteredChunkSendFailure(_friendlyError(e)),
            rebuild: mounted,
          );
        } finally {
          _workspace.sttSession.pendingAudioChunkSends =
              (_workspace.sttSession.pendingAudioChunkSends - 1).clamp(
            0,
            1 << 20,
          );
        }
      },
    );
    _workspace.sttSession.captureController = captureResult.handle;
    _workspace.sttSession.stream = captureResult.handle.stream;
    _setWorkspaceSttRuntime(
      _workspace.sttRuntime.copyWith(
        debugAudioTrackCount: captureResult.audioTrackCount,
      ),
      rebuild: mounted,
    );
    _setWorkspaceSttRuntime(
      _workspace.sttRuntime.enteredRecorderCreated(
        mimeType: captureResult.mimeType,
        wsState: workspaceSttReadyStateLabel(socket.readyState),
      ),
      rebuild: mounted,
    );
    _setWorkspaceSttRuntime(
      _workspace.sttRuntime
          .enteredRecording(
            wsState: workspaceSttReadyStateLabel(socket.readyState),
          )
          .copyWith(
            debugState: 'pcm-recording',
            debugLastAction: 'pcm-capture-started',
          ),
      rebuild: mounted,
    );
  }

  Future<void> _startWorkspaceRealtimeStt() async {
    if (_workspace.sttRuntime.active) return;
    if (!_connected) {
      _setStatus('请先加入会议再启动实时字幕');
      return;
    }
    if (!_hasPrivateMeetingApiScope) {
      _setStatus('当前入口不支持实时字幕工作区能力');
      return;
    }
    try {
      _setWorkspaceSttRuntime(
        _workspace.sttRuntime.copyWith(
          debugState: 'jwt',
          debugLastError: '',
          debugWsState: 'not-created',
          debugAudioTrackCount: 0,
          debugLastAction: 'start-entered',
        ),
        rebuild: mounted,
      );
      final token = await _ensureJwt();
      var captureMode = resolveWorkspaceSttCaptureMode(
        preferredValue: 'pcm',
        pcmSupported: workspaceSttPcmCaptureSupported(),
      );
      while (true) {
        _setWorkspaceSttRuntime(
          _workspace.sttRuntime.copyWith(
            debugState: 'ws-connecting',
            debugMimeType: workspaceSttCaptureModeLabel(captureMode),
          ),
          rebuild: mounted,
        );
        final socket = html.WebSocket(_workspaceSttWebsocketUrl(token));
        _workspace.sttSession.socket = socket;
        _setWorkspaceSttRuntime(
          _workspace.sttRuntime.copyWith(
            stopping: false,
            debugWsState: workspaceSttReadyStateLabel(socket.readyState),
          ),
          rebuild: mounted,
        );

        final openCompleter = Completer<void>();
        _attachWorkspaceSttSocketListeners(socket, openCompleter);
        try {
          await openCompleter.future.timeout(const Duration(seconds: 10));
          switch (captureMode) {
            case WorkspaceSttCaptureMode.mediaRecorderWebm:
              await _startWorkspaceRealtimeSttWithWebm(socket: socket);
              break;
            case WorkspaceSttCaptureMode.pcmWorklet:
              await _startWorkspaceRealtimeSttWithPcm(socket: socket);
              break;
          }
          break;
        } catch (e) {
          final fallback = nextWorkspaceSttCaptureModeFallback(
            attemptedMode: captureMode,
          );
          if (fallback == null) {
            rethrow;
          }
          await _clearWorkspaceRealtimeSttResources();
          _setWorkspaceSttRuntime(
            _workspace.sttRuntime.copyWith(
              debugState: 'fallback',
              debugLastError: _friendlyError(e),
              debugMimeType: workspaceSttCaptureModeLabel(fallback),
              debugLastAction:
                  'fallback-${workspaceSttCaptureModeLabel(fallback)}',
            ),
            rebuild: mounted,
          );
          captureMode = fallback;
        }
      }
      if (!mounted) return;
      _setStatus('实时字幕已启动');
    } catch (e) {
      final errorText = _friendlyError(e);
      _setWorkspaceSttRuntime(
        _workspace.sttRuntime.withStartFailure(
          errorText: errorText,
          wsState: workspaceSttReadyStateLabel(
            (_workspace.sttSession.socket as html.WebSocket?)?.readyState,
          ),
          audioTrackCount: (_workspace.sttSession.stream as html.MediaStream?)
                  ?.getAudioTracks()
                  .length ??
              0,
        ),
        rebuild: mounted,
      );
      await _clearWorkspaceRealtimeSttResources();
      _setWorkspaceSttRuntime(
        _workspace.sttRuntime.copyWith(
          debugState: _workspace.sttRuntime.debugState == 'idle'
              ? 'failed'
              : _workspace.sttRuntime.debugState,
          debugLastError: errorText,
        ),
        rebuild: mounted,
      );
      _setStatus('启动实时字幕失败：$errorText');
    }
  }

  Future<void> _stopWorkspaceRealtimeStt({bool immediate = false}) async {
    if (!_workspace.sttRuntime.active && !_workspace.sttSession.hasLiveResources) {
      return;
    }
    _setWorkspaceSttRuntime(
      _workspace.sttRuntime.enteredStopping(
        wsState: workspaceSttReadyStateLabel(
          (_workspace.sttSession.socket as html.WebSocket?)?.readyState,
        ),
      ),
      rebuild: mounted,
    );
    final captureController =
        _workspace.sttSession.captureController as WorkspaceSttPcmCaptureHandle?;
    final recorder = _workspace.sttSession.recorder as html.MediaRecorder?;
    try {
      if (captureController != null) {
        await captureController.stop();
      } else if (recorder != null && recorder.state != 'inactive') {
        final flushCompleter = Completer<void>();
        final stopCompleter = Completer<void>();
        _workspace.sttSession.flushDataCompleter = flushCompleter;
        _workspace.sttSession.recorderStopCompleter = stopCompleter;
        try {
          recorder.requestData();
          _setWorkspaceSttRuntime(
            _workspace.sttRuntime.enteredRequestData(
              wsState: workspaceSttReadyStateLabel(
                (_workspace.sttSession.socket as html.WebSocket?)?.readyState,
              ),
            ),
            rebuild: mounted,
          );
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
        while (_workspace.sttSession.pendingAudioChunkSends > 0 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    } catch (_) {}
    _workspace.sttSession.recorderStopCompleter = null;
    _workspace.sttSession.flushDataCompleter = null;
    final socket = _workspace.sttSession.socket as html.WebSocket?;
    final stopPlan = planWorkspaceSttStopAction(
      socketReadyState: socket?.readyState,
      immediate: immediate,
    );
    if (socket != null && stopPlan.shouldCloseSocket) {
      try {
        socket.close();
      } catch (_) {}
    } else if (socket != null && stopPlan.shouldSendStopMessage) {
      socket.send(jsonEncode(workspaceSttStopMessage()));
    } else if (stopPlan.shouldClearResources) {
      await _clearWorkspaceRealtimeSttResources();
    }
    if (mounted) {
      setState(() {});
    }
  }
}
