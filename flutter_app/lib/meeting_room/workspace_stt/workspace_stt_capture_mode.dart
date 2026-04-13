enum WorkspaceSttCaptureMode {
  mediaRecorderWebm,
  pcmWorklet,
}

WorkspaceSttCaptureMode resolveWorkspaceSttCaptureMode({
  required String? preferredValue,
  required bool pcmSupported,
}) {
  final normalized = (preferredValue ?? '').trim().toLowerCase();
  if (normalized == 'pcm' && pcmSupported) {
    return WorkspaceSttCaptureMode.pcmWorklet;
  }
  return WorkspaceSttCaptureMode.mediaRecorderWebm;
}

String workspaceSttCaptureModeLabel(WorkspaceSttCaptureMode mode) {
  switch (mode) {
    case WorkspaceSttCaptureMode.mediaRecorderWebm:
      return 'webm';
    case WorkspaceSttCaptureMode.pcmWorklet:
      return 'pcm';
  }
}

WorkspaceSttCaptureMode? nextWorkspaceSttCaptureModeFallback({
  required WorkspaceSttCaptureMode attemptedMode,
}) {
  switch (attemptedMode) {
    case WorkspaceSttCaptureMode.pcmWorklet:
      return WorkspaceSttCaptureMode.mediaRecorderWebm;
    case WorkspaceSttCaptureMode.mediaRecorderWebm:
      return null;
  }
}
