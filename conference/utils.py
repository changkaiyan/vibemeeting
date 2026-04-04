from django.utils import timezone

from conference.models import AuditLog, MeetingMember, MeetingRole, OrganizationMember


def client_ip(request) -> str:
    forwarded = request.META.get("HTTP_X_FORWARDED_FOR", "").strip()
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.META.get("REMOTE_ADDR", "unknown")


def log_audit(
    *,
    user=None,
    action: str,
    resource_type: str | None = None,
    resource_id: str | int | None = None,
    detail: str | None = None,
    ip_address: str | None = None,
) -> None:
    AuditLog.objects.create(
        user=user,
        action=action,
        resource_type=resource_type,
        resource_id=str(resource_id) if resource_id is not None else None,
        detail=detail,
        ip_address=ip_address,
        created_at=timezone.now(),
    )


def user_org_ids(user) -> set[int]:
    return set(
        OrganizationMember.objects.filter(user=user).values_list("organization_id", flat=True),
    )


def meeting_membership(meeting_id: int, user_id: int):
    return MeetingMember.objects.filter(meeting_id=meeting_id, user_id=user_id).first()


def has_meeting_access(user, meeting) -> bool:
    if user.is_superuser:
        return True
    if meeting.owner_id == user.id:
        return True
    return MeetingMember.objects.filter(meeting=meeting, user=user).exists()


def can_moderate(user, membership) -> bool:
    if user.is_superuser:
        return True
    if not membership:
        return False
    return membership.role in {MeetingRole.HOST, MeetingRole.COHOST}


def can_change_roles(user, membership) -> bool:
    if user.is_superuser:
        return True
    if not membership:
        return False
    return membership.role in {MeetingRole.HOST, MeetingRole.COHOST}
