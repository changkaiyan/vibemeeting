import 'dart:async';

class WorkspaceSttSessionState {
  Object? captureController;
  Object? socket;
  Object? recorder;
  Object? stream;

  StreamSubscription<dynamic>? dataSubscription;
  StreamSubscription<dynamic>? stopSubscription;
  StreamSubscription<dynamic>? messageSubscription;
  StreamSubscription<dynamic>? openSubscription;
  StreamSubscription<dynamic>? closeSubscription;
  StreamSubscription<dynamic>? errorSubscription;

  Completer<void>? recorderStopCompleter;
  Completer<void>? flushDataCompleter;

  int pendingAudioChunkSends = 0;

  bool get hasLiveResources {
    return captureController != null ||
        socket != null ||
        recorder != null ||
        stream != null;
  }

  void reset() {
    captureController = null;
    socket = null;
    recorder = null;
    stream = null;
    dataSubscription = null;
    stopSubscription = null;
    messageSubscription = null;
    openSubscription = null;
    closeSubscription = null;
    errorSubscription = null;
    recorderStopCompleter = null;
    flushDataCompleter = null;
    pendingAudioChunkSends = 0;
  }
}
