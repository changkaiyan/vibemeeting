class DesktopJoinTarget {
  const DesktopJoinTarget({
    this.meetingRef,
    this.shareCode,
    this.roomName,
  });

  final String? meetingRef;
  final String? shareCode;
  final String? roomName;
}

DesktopJoinTarget resolveDesktopJoinTarget(String rawInput) {
  final trimmed = rawInput.trim();
  if (trimmed.isEmpty) {
    return const DesktopJoinTarget();
  }

  final parsed = Uri.tryParse(trimmed);
  final path = parsed != null && parsed.hasScheme
      ? parsed.path.trim()
      : trimmed.split('?').first.trim();

  final pathSegments =
      path.split('/').where((segment) => segment.trim().isNotEmpty).toList();

  if (pathSegments.length >= 2 && pathSegments.first == 'm') {
    final shareCode = pathSegments[1].trim();
    if (shareCode.isNotEmpty) {
      return DesktopJoinTarget(shareCode: shareCode);
    }
  }

  if (pathSegments.length >= 3 &&
      pathSegments[0] == 'my' &&
      pathSegments[1] == 'meetings') {
    final meetingRef = pathSegments[2].trim();
    if (meetingRef.isNotEmpty) {
      return DesktopJoinTarget(meetingRef: meetingRef);
    }
  }

  if (pathSegments.length >= 2 && pathSegments[0] == 'meetings') {
    final meetingRef = pathSegments[1].trim();
    if (meetingRef.isNotEmpty) {
      return DesktopJoinTarget(meetingRef: meetingRef);
    }
  }

  if (pathSegments.length >= 2 && pathSegments[0] == 'share') {
    final shareCode = pathSegments[1].trim();
    if (shareCode.isNotEmpty) {
      return DesktopJoinTarget(shareCode: shareCode);
    }
  }

  if (pathSegments.length > 1) {
    final candidate = pathSegments.last.trim();
    if (candidate.isNotEmpty) {
      return DesktopJoinTarget(
        meetingRef: candidate,
        shareCode: candidate,
        roomName: candidate,
      );
    }
  }

  return DesktopJoinTarget(
    meetingRef: trimmed,
    shareCode: trimmed,
    roomName: trimmed,
  );
}
