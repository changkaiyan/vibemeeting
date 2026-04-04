import re

from django.utils.crypto import constant_time_compare, salted_hmac

_SHARE_NAMESPACE = "conference.meeting.share"
_SHARE_PATTERN = re.compile(r"^(?P<room_variant>[A-Za-z0-9_-]{6,120})-(?P<sig>[0-9a-f]{12})$")


def _meeting_room_variant(room_name: str) -> str:
    room_name = (room_name or "").strip()
    if room_name.startswith("room-"):
        return room_name[5:]
    return room_name


def build_meeting_share_code(room_name: str) -> str:
    variant = _meeting_room_variant(room_name)
    signature = salted_hmac(_SHARE_NAMESPACE, room_name).hexdigest()[:12]
    return f"{variant}-{signature}"


def room_name_from_share_code(share_code: str) -> str | None:
    raw = (share_code or "").strip()
    match = _SHARE_PATTERN.fullmatch(raw)
    if not match:
        return None

    room_variant = match.group("room_variant")
    provided_sig = match.group("sig")
    room_name = room_variant if room_variant.startswith("room-") else f"room-{room_variant}"
    expected_sig = salted_hmac(_SHARE_NAMESPACE, room_name).hexdigest()[:12]
    if not constant_time_compare(provided_sig, expected_sig):
        return None
    return room_name
