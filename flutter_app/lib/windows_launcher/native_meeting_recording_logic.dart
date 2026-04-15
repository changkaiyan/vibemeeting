class DesktopMeetingRecordingState {
  const DesktopMeetingRecordingState({
    this.active = false,
    this.startedAt,
    this.egressId = '',
    this.statusKey = '',
    this.errorText = '',
    this.fileName = '',
  });

  final bool active;
  final DateTime? startedAt;
  final String egressId;
  final String statusKey;
  final String errorText;
  final String fileName;

  factory DesktopMeetingRecordingState.fromPayload(
      Map<String, dynamic> payload) {
    final active = payload['active'] == true;
    final rawStartedAt = (payload['started_at'] ?? '').toString().trim();
    final startedAt = rawStartedAt.isEmpty
        ? null
        : DateTime.tryParse(rawStartedAt)?.toLocal();
    return DesktopMeetingRecordingState(
      active: active,
      startedAt: startedAt,
      egressId: (payload['egress_id'] ?? '').toString().trim(),
      statusKey: (payload['status'] ?? '').toString().trim().toLowerCase(),
      errorText: (payload['error'] ?? '').toString().trim(),
      fileName: _resolveRecordingFileName(payload),
    );
  }
}

String describeRecordingStatus({
  required DesktopMeetingRecordingState state,
  required bool uploading,
}) {
  if (uploading) {
    return '录制请求处理中...';
  }
  if (state.active) {
    return '正在录制中';
  }
  if (state.errorText.isNotEmpty) {
    return '录制失败：${state.errorText}';
  }
  if (state.statusKey == 'complete') {
    if (state.fileName.isNotEmpty) {
      return '录制完成：${state.fileName}';
    }
    return '录制已完成并保存';
  }
  if (state.statusKey == 'idle') {
    return '当前没有进行中的录制';
  }
  return '录制已停止';
}

String recordingBadgeText({
  required DesktopMeetingRecordingState state,
  required bool uploading,
}) {
  if (uploading) {
    return '录制处理中';
  }
  if (state.active) {
    return '录制中';
  }
  return '未录制';
}

String _resolveRecordingFileName(Map<String, dynamic> payload) {
  final topLevel = (payload['file_name'] ?? '').toString().trim();
  if (topLevel.isNotEmpty) {
    return topLevel;
  }
  final nested = payload['recording'];
  if (nested is Map<String, dynamic>) {
    return (nested['file_name'] ?? '').toString().trim();
  }
  return '';
}
