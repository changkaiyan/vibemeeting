import secrets
import string

from django.db import IntegrityError

from conference.models import MeetingAlias

_ALPHABET = string.ascii_lowercase + string.digits
_REF_LENGTH = 12


def _new_ref() -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(_REF_LENGTH))


def ensure_meeting_ref(meeting, user) -> str:
    alias = MeetingAlias.objects.filter(user=user, meeting=meeting).first()
    if alias:
        return alias.meeting_ref

    for _ in range(12):
        candidate = _new_ref()
        try:
            alias = MeetingAlias.objects.create(
                user=user,
                meeting=meeting,
                meeting_ref=candidate,
            )
            return alias.meeting_ref
        except IntegrityError:
            alias = MeetingAlias.objects.filter(user=user, meeting=meeting).first()
            if alias:
                return alias.meeting_ref
            continue
    raise RuntimeError("failed to allocate meeting_ref")


def meeting_from_ref(user, meeting_ref: str):
    ref = (meeting_ref or "").strip()
    if not ref:
        return None
    alias = (
        MeetingAlias.objects.filter(user=user, meeting_ref=ref)
        .select_related("meeting")
        .first()
    )
    if not alias:
        return None
    return alias.meeting
