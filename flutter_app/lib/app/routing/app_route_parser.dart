enum AppRouteKind {
  dashboard,
  billingAdmin,
  meetingRoom,
}

class AppRoute {
  const AppRoute._({
    required this.kind,
    this.meetingRef,
    this.meetingId,
    this.shareCode,
    this.autoJoin = false,
  });

  const AppRoute.dashboard() : this._(kind: AppRouteKind.dashboard);

  const AppRoute.billingAdmin() : this._(kind: AppRouteKind.billingAdmin);

  const AppRoute.meetingRoom({
    String? meetingRef,
    int? meetingId,
    String? shareCode,
    required bool autoJoin,
  }) : this._(
          kind: AppRouteKind.meetingRoom,
          meetingRef: meetingRef,
          meetingId: meetingId,
          shareCode: shareCode,
          autoJoin: autoJoin,
        );

  final AppRouteKind kind;
  final String? meetingRef;
  final int? meetingId;
  final String? shareCode;
  final bool autoJoin;
}

AppRoute resolveAppRoute(Uri uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length >= 3 &&
      segments[0] == 'my' &&
      segments[1] == 'meetings') {
    final meetingRef = segments[2].trim();
    if (meetingRef.isNotEmpty) {
      return AppRoute.meetingRoom(
        meetingRef: meetingRef,
        autoJoin: uri.queryParameters['autojoin'] == '1',
      );
    }
  }
  if (segments.length >= 2 && segments.first == 'meetings') {
    final meetingId = int.tryParse(segments[1]);
    if (meetingId != null) {
      return AppRoute.meetingRoom(
        meetingId: meetingId,
        autoJoin: uri.queryParameters['autojoin'] == '1',
      );
    }
  }
  if (segments.length >= 2 && segments.first == 'm') {
    final shareCode = segments[1].trim();
    if (shareCode.isNotEmpty) {
      return AppRoute.meetingRoom(
        shareCode: shareCode,
        autoJoin: uri.queryParameters['autojoin'] != '0',
      );
    }
  }
  if (segments.isNotEmpty && segments.first == 'billing') {
    return const AppRoute.billingAdmin();
  }
  return const AppRoute.dashboard();
}
