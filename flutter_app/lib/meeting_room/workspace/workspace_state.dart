import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../workspace_stt/workspace_stt_controller.dart';
import '../workspace_stt/workspace_stt_runtime.dart';
import '../workspace_stt/workspace_stt_session.dart';

class MeetingWorkspaceState {
  final TextEditingController transcriptController = TextEditingController();
  final WorkspaceSttController sttController = const WorkspaceSttController();

  Timer? timer;
  bool loading = false;
  bool ready = false;

  WorkspaceSttRuntimeState sttRuntime = WorkspaceSttRuntimeState.initial();
  final WorkspaceSttSessionState sttSession = WorkspaceSttSessionState();

  List<WorkspaceAgentSession> agentSessions = const <WorkspaceAgentSession>[];
  WorkspaceContextSnapshot? context;
  List<WorkspaceTranscriptChunk> transcripts = const <WorkspaceTranscriptChunk>[];
  List<WorkspaceArtifact> artifacts = const <WorkspaceArtifact>[];

  void resetSttRuntime() {
    sttSession.reset();
    sttRuntime = sttRuntime.cleared();
  }

  void dispose() {
    timer?.cancel();
    timer = null;
    transcriptController.dispose();
  }
}
