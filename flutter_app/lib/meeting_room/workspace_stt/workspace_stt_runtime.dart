import 'workspace_stt_controller.dart';

class WorkspaceSttRuntimeState {
  const WorkspaceSttRuntimeState({
    required this.active,
    required this.stopping,
    required this.partialText,
    required this.debugState,
    required this.debugMimeType,
    required this.debugBlobEventCount,
    required this.debugLastBlobSize,
    required this.debugLastError,
    required this.debugWsState,
    required this.debugAudioTrackCount,
    required this.debugStartTapCount,
    required this.debugStopTapCount,
    required this.debugLastAction,
  });

  factory WorkspaceSttRuntimeState.initial() {
    return const WorkspaceSttRuntimeState(
      active: false,
      stopping: false,
      partialText: '',
      debugState: 'idle',
      debugMimeType: '',
      debugBlobEventCount: 0,
      debugLastBlobSize: 0,
      debugLastError: '',
      debugWsState: 'not-created',
      debugAudioTrackCount: 0,
      debugStartTapCount: 0,
      debugStopTapCount: 0,
      debugLastAction: '-',
    );
  }

  final bool active;
  final bool stopping;
  final String partialText;
  final String debugState;
  final String debugMimeType;
  final int debugBlobEventCount;
  final int debugLastBlobSize;
  final String debugLastError;
  final String debugWsState;
  final int debugAudioTrackCount;
  final int debugStartTapCount;
  final int debugStopTapCount;
  final String debugLastAction;

  WorkspaceSttRuntimeState copyWith({
    bool? active,
    bool? stopping,
    String? partialText,
    String? debugState,
    String? debugMimeType,
    int? debugBlobEventCount,
    int? debugLastBlobSize,
    String? debugLastError,
    String? debugWsState,
    int? debugAudioTrackCount,
    int? debugStartTapCount,
    int? debugStopTapCount,
    String? debugLastAction,
  }) {
    return WorkspaceSttRuntimeState(
      active: active ?? this.active,
      stopping: stopping ?? this.stopping,
      partialText: partialText ?? this.partialText,
      debugState: debugState ?? this.debugState,
      debugMimeType: debugMimeType ?? this.debugMimeType,
      debugBlobEventCount: debugBlobEventCount ?? this.debugBlobEventCount,
      debugLastBlobSize: debugLastBlobSize ?? this.debugLastBlobSize,
      debugLastError: debugLastError ?? this.debugLastError,
      debugWsState: debugWsState ?? this.debugWsState,
      debugAudioTrackCount: debugAudioTrackCount ?? this.debugAudioTrackCount,
      debugStartTapCount: debugStartTapCount ?? this.debugStartTapCount,
      debugStopTapCount: debugStopTapCount ?? this.debugStopTapCount,
      debugLastAction: debugLastAction ?? this.debugLastAction,
    );
  }

  WorkspaceSttRuntimeState afterStartTap() {
    return copyWith(
      debugStartTapCount: debugStartTapCount + 1,
      debugLastAction: 'tap-start',
      debugState: debugState == 'idle' ? 'start-tapped' : debugState,
    );
  }

  WorkspaceSttRuntimeState afterStopTap() {
    return copyWith(
      debugStopTapCount: debugStopTapCount + 1,
      debugLastAction: 'tap-stop',
    );
  }

  WorkspaceSttRuntimeState cleared() {
    return copyWith(
      active: false,
      stopping: false,
      partialText: '',
      debugState: 'idle',
      debugMimeType: '',
      debugBlobEventCount: 0,
      debugLastBlobSize: 0,
      debugLastError: '',
      debugWsState: 'not-created',
      debugAudioTrackCount: 0,
      debugLastAction: 'resources-cleared',
    );
  }

  WorkspaceSttRuntimeState applyInboundEffect(
      WorkspaceSttInboundEffect effect) {
    return copyWith(
      partialText: effect.partialText ?? partialText,
      debugLastAction: effect.debugLastAction ?? debugLastAction,
    );
  }

  WorkspaceSttRuntimeState enteredRecorderCreated({
    required String mimeType,
    required String wsState,
  }) {
    return copyWith(
      debugState: 'recorder-created',
      debugMimeType: mimeType,
      debugBlobEventCount: 0,
      debugLastBlobSize: 0,
      debugLastError: '',
      debugWsState: wsState,
      debugLastAction: 'recorder-created',
    );
  }

  WorkspaceSttRuntimeState enteredRecording({
    required String wsState,
  }) {
    return copyWith(
      active: true,
      stopping: false,
      debugState: 'recording',
      debugWsState: wsState,
      debugLastAction: 'recorder-started',
    );
  }

  WorkspaceSttRuntimeState observedBlobEvent({
    required int blobSize,
    required String wsState,
    required String blobMimeType,
  }) {
    return copyWith(
      debugState: 'dataavailable',
      debugBlobEventCount: debugBlobEventCount + 1,
      debugLastBlobSize: blobSize,
      debugWsState: wsState,
      debugLastAction: 'blob-event',
      debugMimeType: blobMimeType.isNotEmpty ? blobMimeType : debugMimeType,
    );
  }

  WorkspaceSttRuntimeState enteredStopping({
    required String wsState,
  }) {
    return copyWith(
      stopping: true,
      debugState: 'stopping',
      debugWsState: wsState,
      debugLastAction: 'stop-entered',
    );
  }

  WorkspaceSttRuntimeState enteredRequestData({
    required String wsState,
  }) {
    return copyWith(
      debugState: 'request-data',
      debugWsState: wsState,
      debugLastAction: 'request-data',
    );
  }

  WorkspaceSttRuntimeState enteredRecorderStopped({
    required String wsState,
  }) {
    return copyWith(
      debugState: 'recorder-stopped',
      debugWsState: wsState,
      debugLastAction: 'recorder-stop-event',
    );
  }

  WorkspaceSttRuntimeState enteredChunkSent() {
    return copyWith(
      debugLastAction: 'chunk-sent',
      debugLastError: '',
    );
  }

  WorkspaceSttRuntimeState enteredChunkSendFailure(String errorText) {
    return copyWith(
      debugState: 'failed:chunk-send',
      debugLastAction: 'chunk-send-failed',
      debugLastError: errorText,
    );
  }

  WorkspaceSttRuntimeState withStartFailure({
    required String errorText,
    required String wsState,
    required int audioTrackCount,
  }) {
    final nextDebugState =
        debugState == 'idle' ? 'failed' : 'failed:$debugState';
    return copyWith(
      debugState: nextDebugState,
      debugLastError: errorText,
      debugWsState: wsState,
      debugAudioTrackCount: audioTrackCount,
      debugLastAction: 'start-failed',
    );
  }
}
