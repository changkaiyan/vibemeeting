import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'workspace_stt_pcm_streamer.dart';

class WorkspaceSttPcmCaptureStartResult {
  const WorkspaceSttPcmCaptureStartResult({
    required this.handle,
    required this.audioTrackCount,
    required this.mimeType,
    required this.sampleRate,
  });

  final WorkspaceSttPcmCaptureHandle handle;
  final int audioTrackCount;
  final String mimeType;
  final int sampleRate;
}

class WorkspaceSttPcmCaptureHandle {
  WorkspaceSttPcmCaptureHandle({
    required this.stream,
    required this.audioContext,
    required this.sourceNode,
    required this.processorNode,
    required this.streamer,
  });

  final web.MediaStream stream;
  final web.AudioContext audioContext;
  final web.MediaStreamAudioSourceNode sourceNode;
  final web.ScriptProcessorNode processorNode;
  final WorkspaceSttPcmStreamer streamer;

  Future<void> stop() async {
    processorNode.onaudioprocess = null;
    try {
      processorNode.disconnect();
    } catch (_) {}
    try {
      sourceNode.disconnect();
    } catch (_) {}
    for (final track in stream.getTracks().toDart) {
      try {
        track.stop();
      } catch (_) {}
    }
    try {
      if (audioContext.state != 'closed') {
        await audioContext.close().toDart;
      }
    } catch (_) {}
    streamer.reset();
  }
}

bool workspaceSttPcmCaptureSupported() {
  return web.window.navigator.mediaDevices != null;
}

Future<WorkspaceSttPcmCaptureStartResult> startWorkspaceSttPcmCapture({
  required void Function(Map<String, dynamic> message) onMessage,
  int frameMs = 200,
  int processorBufferSize = 4096,
}) async {
  if (!workspaceSttPcmCaptureSupported()) {
    throw StateError('Web Audio PCM capture is not supported in this browser');
  }

  final stream = await web.window.navigator.mediaDevices
      .getUserMedia(
        web.MediaStreamConstraints(
          audio: true.toJS,
          video: false.toJS,
        ),
      )
      .toDart;
  final audioTracks = stream.getAudioTracks().toDart;
  if (audioTracks.isEmpty) {
    throw StateError('Browser did not return any audio track');
  }

  final audioContext = web.AudioContext(
    web.AudioContextOptions(
      latencyHint: 'interactive'.toJS,
    ),
  );
  try {
    await audioContext.resume().toDart.timeout(const Duration(seconds: 3));
  } catch (_) {}

  final sourceNode = audioContext.createMediaStreamSource(stream);
  final processorNode = audioContext.createScriptProcessor(
    processorBufferSize,
    1,
    1,
  );
  final streamer = WorkspaceSttPcmStreamer(frameMs: frameMs);

  processorNode.onaudioprocess = ((web.Event rawEvent) {
    final event = rawEvent as web.AudioProcessingEvent;
    final input = event.inputBuffer.getChannelData(0).toDart;
    final output = event.outputBuffer.getChannelData(0).toDart;
    for (var i = 0; i < output.length; i++) {
      output[i] = 0;
    }
    streamer.pushFloat32Samples(
      Float32List.fromList(input),
      sourceRate: audioContext.sampleRate.toInt(),
      onMessage: onMessage,
    );
  }).toJS;

  sourceNode.connect(processorNode);
  processorNode.connect(audioContext.destination);

  return WorkspaceSttPcmCaptureStartResult(
    handle: WorkspaceSttPcmCaptureHandle(
      stream: stream,
      audioContext: audioContext,
      sourceNode: sourceNode,
      processorNode: processorNode,
      streamer: streamer,
    ),
    audioTrackCount: audioTracks.length,
    mimeType: streamer.mimeType,
    sampleRate: audioContext.sampleRate.toInt(),
  );
}
