part of '../page.dart';

extension _MeetingRoomRecording on _MeetingRoomPageState {
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
    final reader = html.FileReader();
    final completer = Completer<Uint8List>();
    reader.onLoad.listen((_) {
      final result = reader.result;
      if (result is ByteBuffer) {
        completer.complete(Uint8List.view(result));
        return;
      }
      if (result is Uint8List) {
        completer.complete(result);
        return;
      }
      if (result is List<int>) {
        completer.complete(Uint8List.fromList(result));
        return;
      }
      completer.completeError(
        StateError('Unsupported blob read result: ${result.runtimeType}'),
      );
    });
    reader.onError.listen((_) {
      completer.completeError(
        StateError('Failed to read browser blob'),
      );
    });
    reader.readAsArrayBuffer(blob);
    return completer.future;
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
          throw Exception(
            '未采集到浏览器输出音频。请在共享对话框选择“标签页/窗口”并勾选“共享音频”后重试',
          );
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
        await _syncMeetingRecordingEgressStatus(
          silent: false,
          waitSeconds: 20,
        );
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
  }
}
