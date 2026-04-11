const bool meetingDebugUiEnabled = bool.fromEnvironment(
  'MEETING_DEBUG_UI',
  defaultValue: false,
);

bool shouldShowRealtimeBotDebugPanel({
  required bool projectDebugUiEnabled,
  required bool isSuperAdminUser,
  required bool debugPanelVisible,
}) {
  return isSuperAdminUser && debugPanelVisible;
}

bool shouldShowWorkspaceSttDebug({
  required bool projectDebugUiEnabled,
}) {
  return projectDebugUiEnabled;
}
