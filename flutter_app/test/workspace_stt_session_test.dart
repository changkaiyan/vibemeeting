import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_meeting_app/meeting_room/workspace_stt/workspace_stt_session.dart';

void main() {
  group('WorkspaceSttSessionState', () {
    test('starts empty', () {
      final session = WorkspaceSttSessionState();

      expect(session.hasLiveResources, isFalse);
      expect(session.pendingAudioChunkSends, 0);
      expect(session.socket, isNull);
      expect(session.recorder, isNull);
      expect(session.stream, isNull);
    });

    test('tracks whether any live resource exists', () {
      final session = WorkspaceSttSessionState()..captureController = Object();

      expect(session.hasLiveResources, isTrue);
    });

    test('reset clears all handles and counters', () {
      final session = WorkspaceSttSessionState()
        ..captureController = Object()
        ..socket = Object()
        ..recorder = Object()
        ..stream = Object()
        ..dataSubscription = StreamController<void>().stream.listen((_) {})
        ..stopSubscription = StreamController<void>().stream.listen((_) {})
        ..messageSubscription = StreamController<void>().stream.listen((_) {})
        ..openSubscription = StreamController<void>().stream.listen((_) {})
        ..closeSubscription = StreamController<void>().stream.listen((_) {})
        ..errorSubscription = StreamController<void>().stream.listen((_) {})
        ..recorderStopCompleter = Completer<void>()
        ..flushDataCompleter = Completer<void>()
        ..pendingAudioChunkSends = 9;

      session.reset();

      expect(session.hasLiveResources, isFalse);
      expect(session.pendingAudioChunkSends, 0);
      expect(session.captureController, isNull);
      expect(session.socket, isNull);
      expect(session.recorder, isNull);
      expect(session.stream, isNull);
      expect(session.dataSubscription, isNull);
      expect(session.stopSubscription, isNull);
      expect(session.messageSubscription, isNull);
      expect(session.openSubscription, isNull);
      expect(session.closeSubscription, isNull);
      expect(session.errorSubscription, isNull);
      expect(session.recorderStopCompleter, isNull);
      expect(session.flushDataCompleter, isNull);
    });
  });
}
