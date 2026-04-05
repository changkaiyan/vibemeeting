import json
import os
import re
import threading
import time
from datetime import timedelta, timezone as dt_timezone
from urllib.parse import urlsplit, urlunsplit
from typing import Iterable
from uuid import uuid4

from django.conf import settings
from django.contrib.auth import authenticate, login as auth_login, logout as auth_logout
from django.contrib.auth.models import User
from django.db import close_old_connections, transaction
from django.db.models import Max, Q, Sum
from django.http import FileResponse, HttpResponse, HttpResponseNotFound, JsonResponse
from django.shortcuts import redirect, render
from pathlib import Path, PurePosixPath
from django.utils import timezone
from django.contrib.auth.decorators import login_required
from rest_framework import status
from rest_framework.decorators import (
    api_view,
    authentication_classes,
    permission_classes,
)
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework_simplejwt.tokens import RefreshToken
from livekit import api as lk_api
from livekit.protocol import egress as lk_egress
from livekit.api.twirp_client import TwirpError

from conference.forms import MeetingRegisterForm
from conference.meeting_resolver import MeetingLookup
from conference.meeting_refs import ensure_meeting_ref, meeting_from_ref
from conference.models import (
    AuditLog,
    BillingPlan,
    LoginAttempt,
    MeetingBlockedMember,
    Meeting,
    MeetingWaitingRoomEntry,
    MeetingMember,
    MeetingGuestParticipant,
    MeetingMessage,
    MeetingRecording,
    MeetingOrganization,
    MeetingRole,
    RecordingStorageConfig,
    UserBillingProfile,
    Organization,
    OrganizationMember,
    UserProfile,
    WaitingRoomStatus,
)
from conference.share import build_meeting_share_code, room_name_from_share_code
from conference.serializers import (
    AuditLogSerializer,
    BillingPlanSerializer,
    BillingPlanUpsertSerializer,
    MeetingBlockedMemberSerializer,
    MeetingCreateSerializer,
    MeetingControlUpdateSerializer,
    MeetingDisplayNameUpdateSerializer,
    MeetingJoinSerializer,
    MeetingMemberAddSerializer,
    MeetingMemberDisplayNameControlSerializer,
    MeetingHostLeaveSerializer,
    MeetingPermissionControlSerializer,
    MeetingRaiseHandSerializer,
    MeetingMemberSerializer,
    MeetingMessageCreateSerializer,
    MeetingMessageSerializer,
    MeetingRecordingSerializer,
    MeetingMuteSerializer,
    MeetingRoleUpdateSerializer,
    RecordingStorageConfigSerializer,
    RecordingStorageConfigUpdateSerializer,
    MeetingVideoControlSerializer,
    MeetingWaitingRoomEntrySerializer,
    MeetingSerializer,
    MeetingUpdateSerializer,
    OrganizationMemberAddSerializer,
    OrganizationMemberSerializer,
    OrganizationSerializer,
    RegisterSerializer,
    UserBillingPlanAssignSerializer,
    UserBillingProfileSerializer,
    UserProfileSerializer,
    UserProfileUpdateSerializer,
    UserOutSerializer,
    WaitingRoomReviewSerializer,
)
from conference.services.livekit_service import LiveKitService
from conference.utils import (
    can_change_roles,
    can_moderate,
    client_ip,
    has_meeting_access,
    log_audit,
    meeting_membership,
)

livekit_service = LiveKitService()
_LOCAL_LIVEKIT_HOSTS = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}
_LIVEKIT_WEBHOOK_ACTIVE_EVENTS = {
    "participant_joined",
    "participant_active",
    "participant_resumed",
    "room_started",
}
_LIVEKIT_WEBHOOK_INACTIVE_EVENTS = {
    "participant_left",
    "participant_connection_aborted",
    "room_finished",
    "room_ended",
}
_LIVEKIT_WEBHOOK_MONITORED_EVENTS = _LIVEKIT_WEBHOOK_ACTIVE_EVENTS.union(
    _LIVEKIT_WEBHOOK_INACTIVE_EVENTS
)
_OWNER_ROOM_LIMIT_TIMERS: dict[int, threading.Timer] = {}
_OWNER_ROOM_LIMIT_TIMERS_LOCK = threading.Lock()
_MEETING_ROOM_LIMIT_TIMERS: dict[int, threading.Timer] = {}
_MEETING_ROOM_LIMIT_TIMERS_LOCK = threading.Lock()


def _host_without_port(host: str) -> str:
    value = (host or "").strip()
    if not value:
        return ""
    if value.startswith("["):
        end = value.find("]")
        if end != -1:
            return value[1:end]
    if ":" in value:
        return value.split(":", 1)[0]
    return value


def _normalize_livekit_client_url_scheme(url: str, *, request_is_secure: bool) -> str:
    parsed = urlsplit(url)
    if not parsed.scheme or not parsed.netloc:
        return url

    scheme = parsed.scheme.lower()
    if scheme == "http":
        scheme = "ws"
    elif scheme == "https":
        scheme = "wss"

    if request_is_secure and scheme == "ws":
        scheme = "wss"

    return urlunsplit((scheme, parsed.netloc, parsed.path, parsed.query, parsed.fragment))


def _meeting_livekit_url_for_client(request) -> str:
    public_url = getattr(settings, "LIVEKIT_PUBLIC_URL", "") or ""
    public_url = public_url.strip()
    if public_url:
        return _normalize_livekit_client_url_scheme(public_url, request_is_secure=request.is_secure())

    livekit_url = (settings.LIVEKIT_URL or "").strip()
    if not livekit_url:
        return livekit_url

    parsed = urlsplit(livekit_url)
    if not parsed.scheme or not parsed.netloc:
        return livekit_url

    source_host = (parsed.hostname or "").lower()
    if source_host not in _LOCAL_LIVEKIT_HOSTS:
        return livekit_url

    request_host = _host_without_port(request.get_host())
    if not request_host:
        return livekit_url

    host_for_netloc = request_host
    if ":" in request_host and not request_host.startswith("["):
        host_for_netloc = f"[{request_host}]"

    auth_part = ""
    if parsed.username:
        auth_part = parsed.username
        if parsed.password:
            auth_part = f"{auth_part}:{parsed.password}"
        auth_part = f"{auth_part}@"

    port_part = f":{parsed.port}" if parsed.port else ""
    rewritten_netloc = f"{auth_part}{host_for_netloc}{port_part}"
    rewritten_url = urlunsplit((parsed.scheme, rewritten_netloc, parsed.path, parsed.query, parsed.fragment))
    return _normalize_livekit_client_url_scheme(rewritten_url, request_is_secure=request.is_secure())


def _profile_for_user(user: User) -> UserProfile:
    profile, _ = UserProfile.objects.get_or_create(
        user=user,
        defaults={"default_display_name": user.username},
    )
    if not profile.default_display_name:
        profile.default_display_name = user.username
        profile.save(update_fields=["default_display_name", "updated_at"])
    return profile


def _billing_profile_for_user(user: User) -> UserBillingProfile:
    profile, _ = UserBillingProfile.objects.get_or_create(user=user)
    return profile


def _normalized_limit_value(raw_value) -> int | None:
    if raw_value is None:
        return None
    value = int(raw_value)
    if value <= 0:
        return None
    return value


def _billing_limits_for_user(user: User) -> dict:
    if user.is_superuser:
        return {
            "max_active_rooms": None,
            "max_room_participants": None,
            "max_room_used_seconds": None,
            "max_current_room_used_seconds": None,
            "max_recording_storage_bytes": None,
            "max_meeting_count": None,
        }
    profile = _billing_profile_for_user(user)
    plan = profile.plan
    if plan is None:
        return {
            "max_active_rooms": None,
            "max_room_participants": None,
            "max_room_used_seconds": None,
            "max_current_room_used_seconds": None,
            "max_recording_storage_bytes": None,
            "max_meeting_count": None,
        }
    return {
        "max_active_rooms": _normalized_limit_value(plan.max_active_rooms),
        "max_room_participants": _normalized_limit_value(plan.max_room_participants),
        "max_room_used_seconds": _normalized_limit_value(plan.max_room_used_seconds),
        "max_current_room_used_seconds": _normalized_limit_value(plan.max_current_room_used_seconds),
        "max_recording_storage_bytes": _normalized_limit_value(plan.max_recording_storage_bytes),
        "max_meeting_count": _normalized_limit_value(plan.max_meeting_count),
    }


def _owned_meetings(user: User):
    return Meeting.objects.filter(owner=user)


def _user_meeting_count(user: User) -> int:
    return int(_owned_meetings(user).count())


def _user_max_room_participants(user: User) -> int:
    raw = _owned_meetings(user).aggregate(value=Max("max_participants")).get("value")
    return int(raw or 0)


def _user_active_room_count(user: User) -> int:
    return int(_owned_meetings(user).filter(room_session_started_at__isnull=False).count())


def _user_recording_storage_used_bytes(user: User) -> int:
    raw = MeetingRecording.objects.filter(owner=user).aggregate(value=Sum("size_bytes")).get("value")
    return int(raw or 0)


def _user_room_used_seconds(user: User, *, now=None) -> int:
    now = now or timezone.now()
    profile = _billing_profile_for_user(user)
    total = int(profile.accumulated_room_used_seconds or 0)
    active_values = (
        _owned_meetings(user)
        .filter(room_session_started_at__isnull=False)
        .values_list("room_session_started_at", flat=True)
    )
    for started_at in active_values:
        if started_at is None:
            continue
        elapsed = int((now - started_at).total_seconds())
        if elapsed > 0:
            total += elapsed
    return max(0, total)


def _user_current_room_max_used_seconds(user: User, *, now=None) -> int:
    now = now or timezone.now()
    started_values = (
        _owned_meetings(user)
        .filter(room_session_started_at__isnull=False)
        .values_list("room_session_started_at", flat=True)
    )
    max_elapsed = 0
    for started_at in started_values:
        if started_at is None:
            continue
        elapsed = int((now - started_at).total_seconds())
        if elapsed > max_elapsed:
            max_elapsed = elapsed
    return max(0, max_elapsed)


def _billing_usage_snapshot(user: User, *, now=None) -> dict:
    now = now or timezone.now()
    profile = _billing_profile_for_user(user)
    cumulative_seconds = _user_room_used_seconds(user, now=now)
    current_room_max_seconds = _user_current_room_max_used_seconds(user, now=now)
    return {
        "active_room_count": _user_active_room_count(user),
        "room_peak_count": int(profile.room_peak_count or 0),
        "max_room_participants_used": _user_max_room_participants(user),
        "cumulative_room_used_seconds": cumulative_seconds,
        "current_room_max_used_seconds": current_room_max_seconds,
        "room_used_seconds": cumulative_seconds,
        "recording_storage_used_bytes": _user_recording_storage_used_bytes(user),
        "meeting_count": _user_meeting_count(user),
    }


def _billing_exceeded_keys(usage: dict, limits: dict) -> list[str]:
    mapping = [
        ("active_room_count", "max_active_rooms"),
        ("max_room_participants_used", "max_room_participants"),
        ("room_used_seconds", "max_room_used_seconds"),
        ("current_room_max_used_seconds", "max_current_room_used_seconds"),
        ("recording_storage_used_bytes", "max_recording_storage_bytes"),
        ("meeting_count", "max_meeting_count"),
    ]
    exceeded: list[str] = []
    for usage_key, limit_key in mapping:
        limit_value = limits.get(limit_key)
        if limit_value is None:
            continue
        usage_value = int(usage.get(usage_key, 0))
        limit_int = int(limit_value)
        if limit_key in {"max_room_used_seconds", "max_current_room_used_seconds"}:
            if usage_value >= limit_int:
                exceeded.append(limit_key)
            continue
        if usage_value > limit_int:
            exceeded.append(limit_key)
    return exceeded


def _billing_limit_message_for_action(
    user: User,
    *,
    projected_active_rooms: int | None = None,
    projected_room_participants: int | None = None,
    projected_room_used_seconds: int | None = None,
    projected_current_room_max_used_seconds: int | None = None,
    projected_recording_storage_bytes: int | None = None,
    projected_meeting_count: int | None = None,
) -> str | None:
    limits = _billing_limits_for_user(user)
    if all(value is None for value in limits.values()):
        return None
    usage = _billing_usage_snapshot(user)
    checks = [
        (
            "max_active_rooms",
            projected_active_rooms if projected_active_rooms is not None else usage["active_room_count"],
            "active rooms",
        ),
        (
            "max_room_participants",
            projected_room_participants
            if projected_room_participants is not None
            else usage["max_room_participants_used"],
            "max participants per room",
        ),
        (
            "max_room_used_seconds",
            projected_room_used_seconds if projected_room_used_seconds is not None else usage["room_used_seconds"],
            "cumulative room used seconds",
        ),
        (
            "max_current_room_used_seconds",
            projected_current_room_max_used_seconds
            if projected_current_room_max_used_seconds is not None
            else usage["current_room_max_used_seconds"],
            "current room max used seconds",
        ),
        (
            "max_recording_storage_bytes",
            projected_recording_storage_bytes
            if projected_recording_storage_bytes is not None
            else usage["recording_storage_used_bytes"],
            "recording storage bytes",
        ),
        (
            "max_meeting_count",
            projected_meeting_count if projected_meeting_count is not None else usage["meeting_count"],
            "meeting count",
        ),
    ]
    for limit_key, current_value, label in checks:
        limit_value = limits.get(limit_key)
        if limit_value is None:
            continue
        current_int = int(current_value)
        limit_int = int(limit_value)
        if limit_key in {"max_room_used_seconds", "max_current_room_used_seconds"}:
            if current_int >= limit_int:
                return f"Plan limit exceeded: {label} ({current_int}/{limit_int})"
            continue
        if current_int > limit_int:
            return f"Plan limit exceeded: {label} ({current_value}/{limit_value})"
    return None


def _refresh_room_peak_for_user(user: User) -> None:
    if user.is_superuser:
        return
    current_active_rooms = _user_active_room_count(user)
    profile = _billing_profile_for_user(user)
    if current_active_rooms <= int(profile.room_peak_count or 0):
        return
    profile.room_peak_count = current_active_rooms
    profile.save(update_fields=["room_peak_count", "updated_at"])


def _owner_room_used_seconds_limit(user: User) -> int | None:
    limit = _billing_limits_for_user(user).get("max_room_used_seconds")
    if limit is None:
        return None
    return int(limit)


def _owner_current_room_used_seconds_limit(user: User) -> int | None:
    limit = _billing_limits_for_user(user).get("max_current_room_used_seconds")
    if limit is None:
        return None
    return int(limit)


def _meeting_current_room_used_seconds(meeting, *, now=None) -> int:
    started_at = meeting.room_session_started_at
    if started_at is None:
        return 0
    now = now or timezone.now()
    elapsed = int((now - started_at).total_seconds())
    return max(0, elapsed)


def _cancel_owner_room_limit_timer(owner_id: int) -> None:
    with _OWNER_ROOM_LIMIT_TIMERS_LOCK:
        timer = _OWNER_ROOM_LIMIT_TIMERS.pop(int(owner_id), None)
    if timer is not None:
        timer.cancel()


def _cancel_meeting_room_limit_timer(meeting_id: int) -> None:
    with _MEETING_ROOM_LIMIT_TIMERS_LOCK:
        timer = _MEETING_ROOM_LIMIT_TIMERS.pop(int(meeting_id), None)
    if timer is not None:
        timer.cancel()


def _timeout_active_rooms_for_owner_due_to_room_used_limit(
    owner: User,
    *,
    now=None,
    usage_seconds: int,
    limit_seconds: int,
) -> int:
    now = now or timezone.now()
    room_targets: list[tuple[int, str]] = []
    with transaction.atomic():
        meetings = list(
            Meeting.objects.select_related("owner")
            .select_for_update()
            .filter(owner=owner, room_session_started_at__isnull=False)
            .order_by("id")
        )
        for meeting in meetings:
            _finalize_room_session_if_needed(meeting, ended_at=now, schedule_limit_timer=False)
            _cancel_meeting_room_limit_timer(meeting.id)
            room_targets.append((meeting.id, meeting.room_name))

    for _, room_name in room_targets:
        try:
            livekit_service.delete_room(room_name)
        except Exception:
            pass

    for meeting_id, room_name in room_targets:
        log_audit(
            user=owner,
            action="meeting.cumulative_room_used_seconds_timeout",
            resource_type="meeting",
            resource_id=meeting_id,
            detail=f"usage={usage_seconds}, limit={limit_seconds}, room={room_name}",
            ip_address="system",
        )
    _schedule_owner_room_limit_timer(owner.id)
    return len(room_targets)


def _enforce_owner_room_used_limit_if_needed(owner: User, *, now=None) -> bool:
    if owner.is_superuser:
        return False
    limit_seconds = _owner_room_used_seconds_limit(owner)
    if limit_seconds is None:
        return False
    now = now or timezone.now()
    usage_seconds = _user_room_used_seconds(owner, now=now)
    if int(usage_seconds) < int(limit_seconds):
        return False
    changed = _timeout_active_rooms_for_owner_due_to_room_used_limit(
        owner,
        now=now,
        usage_seconds=int(usage_seconds),
        limit_seconds=int(limit_seconds),
    )
    return changed > 0


def _owner_room_used_limit_timer_fire(owner_id: int) -> None:
    with _OWNER_ROOM_LIMIT_TIMERS_LOCK:
        _OWNER_ROOM_LIMIT_TIMERS.pop(int(owner_id), None)
    close_old_connections()
    try:
        owner = User.objects.filter(id=owner_id).first()
        if not owner:
            return
        _enforce_owner_room_used_limit_if_needed(owner)
        _schedule_owner_room_limit_timer(owner_id)
    finally:
        close_old_connections()


def _schedule_owner_room_limit_timer(owner_id: int) -> None:
    owner = User.objects.filter(id=owner_id).first()
    if not owner:
        _cancel_owner_room_limit_timer(owner_id)
        return
    if owner.is_superuser:
        _cancel_owner_room_limit_timer(owner_id)
        return

    limit_seconds = _owner_room_used_seconds_limit(owner)
    if limit_seconds is None:
        _cancel_owner_room_limit_timer(owner_id)
        return

    active_count = _user_active_room_count(owner)
    if active_count <= 0:
        _cancel_owner_room_limit_timer(owner_id)
        return

    now = timezone.now()
    remaining_seconds = int(limit_seconds) - int(_user_room_used_seconds(owner, now=now))
    if remaining_seconds <= 0:
        _cancel_owner_room_limit_timer(owner_id)
        return

    delay_seconds = max(1, remaining_seconds)
    timer = threading.Timer(
        delay_seconds,
        _owner_room_used_limit_timer_fire,
        args=(owner.id,),
    )
    timer.daemon = True
    _cancel_owner_room_limit_timer(owner.id)
    with _OWNER_ROOM_LIMIT_TIMERS_LOCK:
        _OWNER_ROOM_LIMIT_TIMERS[owner.id] = timer
    timer.start()


def _timeout_meeting_due_to_current_room_limit(
    meeting,
    *,
    now=None,
    usage_seconds: int,
    limit_seconds: int,
) -> bool:
    now = now or timezone.now()
    if meeting.room_session_started_at is None:
        _cancel_meeting_room_limit_timer(meeting.id)
        return False

    _finalize_room_session_if_needed(meeting, ended_at=now, schedule_limit_timer=False)
    _cancel_meeting_room_limit_timer(meeting.id)
    _schedule_owner_room_limit_timer(meeting.owner_id)
    try:
        livekit_service.delete_room(meeting.room_name)
    except Exception:
        pass
    log_audit(
        user=meeting.owner,
        action="meeting.current_room_used_seconds_timeout",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=f"usage={usage_seconds}, limit={limit_seconds}, room={meeting.room_name}",
        ip_address="system",
    )
    return True


def _enforce_meeting_current_room_used_limit_if_needed(meeting, *, now=None) -> bool:
    if meeting.owner.is_superuser:
        return False
    if meeting.room_session_started_at is None:
        _cancel_meeting_room_limit_timer(meeting.id)
        return False
    limit_seconds = _owner_current_room_used_seconds_limit(meeting.owner)
    if limit_seconds is None:
        _cancel_meeting_room_limit_timer(meeting.id)
        return False
    now = now or timezone.now()
    usage_seconds = _meeting_current_room_used_seconds(meeting, now=now)
    if usage_seconds < int(limit_seconds):
        return False
    return _timeout_meeting_due_to_current_room_limit(
        meeting,
        now=now,
        usage_seconds=int(usage_seconds),
        limit_seconds=int(limit_seconds),
    )


def _meeting_room_used_limit_timer_fire(meeting_id: int) -> None:
    with _MEETING_ROOM_LIMIT_TIMERS_LOCK:
        _MEETING_ROOM_LIMIT_TIMERS.pop(int(meeting_id), None)
    close_old_connections()
    try:
        meeting = Meeting.objects.select_related("owner").filter(id=meeting_id).first()
        if not meeting:
            return
        _enforce_meeting_current_room_used_limit_if_needed(meeting)
        _schedule_meeting_room_limit_timer(meeting.id)
    finally:
        close_old_connections()


def _schedule_meeting_room_limit_timer(meeting_id: int) -> None:
    meeting = Meeting.objects.select_related("owner").filter(id=meeting_id).first()
    if not meeting:
        _cancel_meeting_room_limit_timer(meeting_id)
        return
    if meeting.owner.is_superuser or meeting.room_session_started_at is None:
        _cancel_meeting_room_limit_timer(meeting_id)
        return

    limit_seconds = _owner_current_room_used_seconds_limit(meeting.owner)
    if limit_seconds is None:
        _cancel_meeting_room_limit_timer(meeting_id)
        return

    now = timezone.now()
    remaining_seconds = int(limit_seconds) - int(_meeting_current_room_used_seconds(meeting, now=now))
    if remaining_seconds <= 0:
        _cancel_meeting_room_limit_timer(meeting.id)
        return

    delay_seconds = max(1, remaining_seconds)
    timer = threading.Timer(
        delay_seconds,
        _meeting_room_used_limit_timer_fire,
        args=(meeting.id,),
    )
    timer.daemon = True
    _cancel_meeting_room_limit_timer(meeting.id)
    with _MEETING_ROOM_LIMIT_TIMERS_LOCK:
        _MEETING_ROOM_LIMIT_TIMERS[meeting.id] = timer
    timer.start()


def _start_room_session_if_needed(meeting) -> bool:
    if meeting.room_session_started_at is not None:
        return False
    meeting.room_session_started_at = timezone.now()
    meeting.save(update_fields=["room_session_started_at"])
    _refresh_room_peak_for_user(meeting.owner)
    if _enforce_owner_room_used_limit_if_needed(meeting.owner):
        return True
    if _enforce_meeting_current_room_used_limit_if_needed(meeting):
        return True
    _schedule_owner_room_limit_timer(meeting.owner_id)
    _schedule_meeting_room_limit_timer(meeting.id)
    return True


def _accumulate_room_usage_for_meeting_owner(meeting, *, ended_at=None) -> int:
    started_at = meeting.room_session_started_at
    if started_at is None:
        return 0
    ended_at = ended_at or timezone.now()
    elapsed_seconds = int((ended_at - started_at).total_seconds())
    if elapsed_seconds < 0:
        elapsed_seconds = 0
    if elapsed_seconds > 0:
        profile = _billing_profile_for_user(meeting.owner)
        profile.accumulated_room_used_seconds = int(profile.accumulated_room_used_seconds or 0) + elapsed_seconds
        profile.save(update_fields=["accumulated_room_used_seconds", "updated_at"])
    return elapsed_seconds


def _finalize_room_session_if_needed(meeting, *, ended_at=None, schedule_limit_timer: bool = True) -> int:
    if meeting.room_session_started_at is None:
        _cancel_meeting_room_limit_timer(meeting.id)
        return 0
    elapsed = _accumulate_room_usage_for_meeting_owner(meeting, ended_at=ended_at)
    meeting.room_session_started_at = None
    meeting.save(update_fields=["room_session_started_at"])
    _cancel_meeting_room_limit_timer(meeting.id)
    if schedule_limit_timer:
        _schedule_owner_room_limit_timer(meeting.owner_id)
    return elapsed


def _transfer_meeting_owner_with_session_usage(meeting, *, new_owner: User) -> None:
    if meeting.owner_id == new_owner.id:
        return
    old_owner_id = meeting.owner_id
    now = timezone.now()
    update_fields = ["owner"]
    if meeting.room_session_started_at is not None:
        _accumulate_room_usage_for_meeting_owner(meeting, ended_at=now)
        meeting.room_session_started_at = now
        update_fields.append("room_session_started_at")
    meeting.owner = new_owner
    meeting.save(update_fields=update_fields)
    if meeting.room_session_started_at is not None:
        _refresh_room_peak_for_user(new_owner)
        _enforce_owner_room_used_limit_if_needed(new_owner, now=now)
        _enforce_meeting_current_room_used_limit_if_needed(meeting, now=now)
    if old_owner_id:
        _schedule_owner_room_limit_timer(old_owner_id)
    _schedule_meeting_room_limit_timer(meeting.id)
    _schedule_owner_room_limit_timer(new_owner.id)


def _extract_bearer_token(value: str) -> str:
    raw = (value or "").strip()
    if not raw:
        return ""
    if raw.lower().startswith("bearer "):
        return raw.split(" ", 1)[1].strip()
    return raw


def _livekit_webhook_receiver() -> lk_api.WebhookReceiver:
    verifier = lk_api.TokenVerifier(
        api_key=settings.LIVEKIT_API_KEY,
        api_secret=settings.LIVEKIT_API_SECRET,
    )
    return lk_api.WebhookReceiver(verifier)


def _livekit_room_participant_count(room_name: str) -> int | None:
    try:
        participants = livekit_service.list_participants(room_name)
    except Exception:
        return None
    return max(0, len(participants))


def _room_online_count_from_webhook_event(meeting, event, *, event_name: str) -> int:
    room = getattr(event, "room", None)
    room_count = None
    if room is not None:
        try:
            room_count = int(getattr(room, "num_participants", 0))
        except (TypeError, ValueError):
            room_count = None
    if room_count is not None:
        room_count = max(0, room_count)

    if event_name in _LIVEKIT_WEBHOOK_ACTIVE_EVENTS:
        if room_count is not None and room_count > 0:
            return room_count
        resolved = _livekit_room_participant_count(meeting.room_name)
        if resolved is not None:
            return max(1, resolved)
        return 1

    if event_name in _LIVEKIT_WEBHOOK_INACTIVE_EVENTS:
        if event_name in {"room_finished", "room_ended"}:
            return 0
        if room_count is not None:
            return room_count
        resolved = _livekit_room_participant_count(meeting.room_name)
        if resolved is not None:
            return resolved
        return 0

    if room_count is not None:
        return room_count
    resolved = _livekit_room_participant_count(meeting.room_name)
    if resolved is not None:
        return resolved
    return 0


def _sync_room_session_state_with_online_count(
    meeting_id: int,
    *,
    online_count: int,
    changed_at=None,
) -> bool:
    changed_at = changed_at or timezone.now()
    normalized_count = max(0, int(online_count or 0))
    with transaction.atomic():
        meeting = (
            Meeting.objects.select_related("owner")
            .select_for_update()
            .filter(id=meeting_id)
            .first()
        )
        if not meeting:
            return False
        if normalized_count > 0:
            if meeting.room_session_started_at is not None:
                _enforce_owner_room_used_limit_if_needed(meeting.owner, now=changed_at)
                _enforce_meeting_current_room_used_limit_if_needed(meeting, now=changed_at)
                _schedule_owner_room_limit_timer(meeting.owner_id)
                _schedule_meeting_room_limit_timer(meeting.id)
                return False
            meeting.room_session_started_at = changed_at
            meeting.save(update_fields=["room_session_started_at"])
            _refresh_room_peak_for_user(meeting.owner)
            _enforce_owner_room_used_limit_if_needed(meeting.owner, now=changed_at)
            _enforce_meeting_current_room_used_limit_if_needed(meeting, now=changed_at)
            _schedule_owner_room_limit_timer(meeting.owner_id)
            _schedule_meeting_room_limit_timer(meeting.id)
            return True
        if meeting.room_session_started_at is None:
            _cancel_meeting_room_limit_timer(meeting.id)
            return False
        _finalize_room_session_if_needed(meeting, ended_at=changed_at)
        return True


def _flutter_cache_bust() -> int:
    js_path = settings.FLUTTER_DASHBOARD_BUILD_DIR / "main.dart.js"
    try:
        return int(os.path.getmtime(js_path))
    except OSError:
        return int(timezone.now().timestamp())


def _fallback_display_name(user: User) -> str:
    profile = _profile_for_user(user)
    return (profile.default_display_name or user.username).strip() or user.username


def _safe_path_component(value: str, fallback: str = "item") -> str:
    normalized = re.sub(r"[^0-9A-Za-z._-]+", "_", (value or "").strip())
    normalized = normalized.strip("._-")
    if not normalized:
        return fallback
    return normalized[:80]


def _is_linux_absolute_path(raw_path: str) -> bool:
    value = (raw_path or "").strip()
    if not value:
        return False
    if not value.startswith("/"):
        return False
    if value.startswith("//"):
        return False
    return True


def _recording_storage_config() -> RecordingStorageConfig:
    config = RecordingStorageConfig.objects.order_by("id").first()
    if config:
        return config
    return RecordingStorageConfig.objects.create(storage_root="")


def _resolved_recording_root(config: RecordingStorageConfig) -> Path | None:
    raw_root = (config.storage_root or "").strip()
    if not raw_root:
        return None
    try:
        candidate = Path(raw_root).expanduser()
        if not candidate.is_absolute():
            candidate = (Path(settings.BASE_DIR) / candidate).resolve()
        else:
            candidate = candidate.resolve()
    except Exception:
        return None
    return candidate


def _egress_output_path_for_target(
    *,
    relative_path: str,
    host_target_path: Path,
) -> str:
    """
    Output filepath passed to LiveKit egress.
    - default: host path (egress runs on host)
    - when LIVEKIT_EGRESS_OUTPUT_ROOT is set: mapped path (egress runs in container)
    """
    output_root = (getattr(settings, "LIVEKIT_EGRESS_OUTPUT_ROOT", "") or "").strip()
    if not output_root:
        return str(host_target_path)

    normalized_parts = [
        part
        for part in (relative_path or "").split("/")
        if part and part not in {".", ".."}
    ]
    normalized_relative = "/".join(normalized_parts) or host_target_path.name

    if output_root.startswith("/"):
        # Preserve POSIX separators for Linux container paths.
        return str(PurePosixPath(output_root) / PurePosixPath(normalized_relative))

    native_relative = Path(*normalized_parts) if normalized_parts else Path(host_target_path.name)
    try:
        output_root_path = Path(output_root).expanduser()
        if not output_root_path.is_absolute():
            output_root_path = (Path(settings.BASE_DIR) / output_root_path).resolve()
        else:
            output_root_path = output_root_path.resolve()
        return str(output_root_path / native_relative)
    except Exception:
        return str(host_target_path)


def _resolve_recording_file_path(recording: MeetingRecording) -> Path | None:
    candidate_roots: list[Path] = []

    root = _resolved_recording_root(
        RecordingStorageConfig(storage_root=recording.storage_root),
    )
    if (
        os.name == "nt"
        and _is_linux_absolute_path(recording.storage_root)
    ):
        root = None
    if root is not None:
        candidate_roots.append(root)

    current_root = _resolved_recording_root(_recording_storage_config())
    if (
        current_root is not None
        and all(existing != current_root for existing in candidate_roots)
    ):
        candidate_roots.append(current_root)

    first_valid_path: Path | None = None
    for base_root in candidate_roots:
        try:
            resolved = (base_root / Path(recording.relative_path)).resolve()
        except Exception:
            continue
        try:
            resolved.relative_to(base_root)
        except Exception:
            continue
        if first_valid_path is None:
            first_valid_path = resolved
        if resolved.exists() and resolved.is_file():
            return resolved

    return first_valid_path


def _delete_recording_file_if_exists(recording: MeetingRecording) -> None:
    target_path = _resolve_recording_file_path(recording)
    if target_path is None or not target_path.exists() or not target_path.is_file():
        return
    try:
        target_path.unlink()
    except Exception:
        return

    root = _resolved_recording_root(RecordingStorageConfig(storage_root=recording.storage_root))
    if root is None:
        return

    # Best-effort cleanup for empty directories created for the recording hierarchy.
    current = target_path.parent
    while True:
        if current == root:
            break
        try:
            current.rmdir()
        except Exception:
            break
        parent = current.parent
        if parent == current:
            break
        current = parent


def _meeting_display_name_for_user(meeting, user: User) -> str:
    membership = MeetingMember.objects.filter(meeting=meeting, user=user).first()
    if membership and membership.display_name:
        return membership.display_name
    return _fallback_display_name(user)


def _clear_meeting_active_egress(meeting) -> None:
    meeting.active_egress_id = ""
    meeting.active_egress_file_name = ""
    meeting.active_egress_relative_path = ""
    meeting.active_egress_storage_root = ""
    meeting.active_egress_started_by = None
    meeting.active_egress_started_at = None
    meeting.save(
        update_fields=[
            "active_egress_id",
            "active_egress_file_name",
            "active_egress_relative_path",
            "active_egress_storage_root",
            "active_egress_started_by",
            "active_egress_started_at",
        ]
    )


def _egress_status_key(status_value) -> str:
    try:
        status = int(status_value)
    except Exception:
        return "unknown"

    mapping = {
        int(lk_egress.EGRESS_STARTING): "starting",
        int(lk_egress.EGRESS_ACTIVE): "active",
        int(lk_egress.EGRESS_ENDING): "ending",
        int(lk_egress.EGRESS_COMPLETE): "complete",
        int(lk_egress.EGRESS_FAILED): "failed",
        int(lk_egress.EGRESS_ABORTED): "aborted",
        int(lk_egress.EGRESS_LIMIT_REACHED): "limit_reached",
    }
    return mapping.get(status, "unknown")


def _query_egress_info(egress_id: str):
    if not egress_id:
        return None
    items = livekit_service.list_egress(egress_id=egress_id)
    if not items:
        return None
    return items[0]


def _egress_file_info(egress_info):
    file_info = getattr(egress_info, "file", None)
    if file_info and (getattr(file_info, "filename", "") or getattr(file_info, "location", "")):
        return file_info
    file_results = list(getattr(egress_info, "file_results", []) or [])
    if file_results:
        return file_results[0]
    return None


def _relative_recording_path_from_location(
    *,
    storage_root: str,
    fallback_relative_path: str,
    location: str,
) -> str:
    relative_path = (fallback_relative_path or "").strip()
    if relative_path:
        return relative_path
    raw_location = (location or "").strip()
    if not raw_location:
        return ""
    root = _resolved_recording_root(RecordingStorageConfig(storage_root=storage_root))
    if root is None:
        return Path(raw_location).name
    try:
        resolved_location = Path(raw_location).resolve()
        return resolved_location.relative_to(root).as_posix()
    except Exception:
        return Path(raw_location).name


def _finalize_active_egress_if_ready(meeting, *, wait_seconds: int = 0) -> dict:
    egress_id = (meeting.active_egress_id or "").strip()
    if not egress_id:
        return {"active": False, "status": "idle"}

    started_at = meeting.active_egress_started_at
    started_by = meeting.active_egress_started_by
    file_name_hint = (meeting.active_egress_file_name or "").strip()
    relative_path_hint = (meeting.active_egress_relative_path or "").strip()
    storage_root_hint = (meeting.active_egress_storage_root or "").strip()

    wait_seconds = max(0, int(wait_seconds))
    deadline = time.time() + wait_seconds
    info = None
    status_key = "unknown"
    query_error = None

    while True:
        try:
            info = _query_egress_info(egress_id)
            query_error = None
        except Exception as exc:
            query_error = _friendly_livekit_egress_error(exc)[0]
            info = None

        if info is None:
            if time.time() < deadline:
                time.sleep(1)
                continue
            break

        status_key = _egress_status_key(getattr(info, "status", None))
        if status_key in {"complete", "failed", "aborted", "limit_reached"}:
            break
        if time.time() >= deadline:
            break
        time.sleep(1)

    if info is None:
        if query_error:
            return {
                "active": True,
                "egress_id": egress_id,
                "status": "unknown",
                "error": query_error,
                "started_at": started_at,
                "file_name": file_name_hint,
            }
        return {
            "active": True,
            "egress_id": egress_id,
            "status": "unknown",
            "started_at": started_at,
            "file_name": file_name_hint,
        }

    if status_key == "complete":
        recording = MeetingRecording.objects.filter(egress_id=egress_id).first()
        if not recording:
            owner = started_by or meeting.owner
            file_info = _egress_file_info(info)
            file_name = (
                (getattr(file_info, "filename", "") or "").strip()
                or file_name_hint
                or f"recording_{egress_id}.mp4"
            )
            location = (getattr(file_info, "location", "") or "").strip()
            size_bytes = int(getattr(file_info, "size", 0) or 0)
            duration_raw = int(getattr(file_info, "duration", 0) or 0)
            duration_seconds = duration_raw if duration_raw > 0 else None
            relative_path = _relative_recording_path_from_location(
                storage_root=storage_root_hint,
                fallback_relative_path=relative_path_hint,
                location=location,
            )
            recording = MeetingRecording.objects.create(
                meeting=meeting,
                owner=owner,
                recorded_by_display_name=_meeting_display_name_for_user(meeting, owner),
                file_name=file_name,
                storage_root=storage_root_hint,
                relative_path=relative_path,
                egress_id=egress_id,
                mime_type="video/mp4",
                size_bytes=size_bytes,
                duration_seconds=duration_seconds,
            )
            log_audit(
                user=owner,
                action="meeting.recording_egress_finalize",
                resource_type="meeting_recording",
                resource_id=recording.id,
                detail=f"meeting={meeting.id}, egress_id={egress_id}, file={file_name}",
            )

        _clear_meeting_active_egress(meeting)
        return {
            "active": False,
            "egress_id": egress_id,
            "status": "complete",
            "recording": recording,
            "started_at": started_at,
        }

    if status_key in {"failed", "aborted", "limit_reached"}:
        error_message = (getattr(info, "error", "") or getattr(info, "details", "") or "").strip()
        error_message = _friendly_recording_egress_terminal_error(error_message)
        _clear_meeting_active_egress(meeting)
        return {
            "active": False,
            "egress_id": egress_id,
            "status": status_key,
            "error": error_message,
            "started_at": started_at,
            "file_name": file_name_hint,
        }

    return {
        "active": True,
        "egress_id": egress_id,
        "status": status_key,
        "started_at": started_at,
        "file_name": file_name_hint,
    }


def _recording_egress_payload(state: dict, *, request) -> dict:
    payload = {
        "active": bool(state.get("active")),
        "status": (state.get("status") or "unknown"),
    }
    egress_id = (state.get("egress_id") or "").strip()
    if egress_id:
        payload["egress_id"] = egress_id
    file_name = (state.get("file_name") or "").strip()
    if file_name:
        payload["file_name"] = file_name
    error_text = _friendly_recording_egress_terminal_error((state.get("error") or "").strip())
    if error_text:
        payload["error"] = error_text
    started_at = state.get("started_at")
    if started_at is not None:
        payload["started_at"] = started_at
    recording = state.get("recording")
    if recording is not None:
        payload["recording"] = MeetingRecordingSerializer(
            recording,
            context={"request": request},
        ).data
    return payload


def _friendly_recording_egress_terminal_error(raw_error: str) -> str:
    error_text = (raw_error or "").strip()
    if not error_text:
        return ""
    lowered = error_text.lower()
    if "start signal not received" in lowered or "source closed" in lowered:
        return (
            "Recording ended before egress fully started (Start signal not received / Source closed). "
            "This usually happens when recording is stopped too quickly. "
            "Please keep recording for at least 3 seconds with active participants before stopping."
        )
    return error_text


def _friendly_livekit_egress_error(exc: Exception) -> tuple[str, int]:
    if isinstance(exc, TwirpError):
        raw_message = (exc.message or "").strip()
        status_code = int(getattr(exc, "status", 0) or 0)
    else:
        raw_message = str(exc).strip()
        status_code = 0

    lowered = raw_message.lower()
    if "egress not connected" in lowered or "redis required" in lowered:
        return (
            "LiveKit egress 未连接：需要先启动 Redis，并保证 livekit-server 与 livekit-egress 都已连接到同一个 Redis。",
            status.HTTP_503_SERVICE_UNAVAILABLE,
        )
    if "no response from server" in lowered:
        return (
            "LiveKit egress 服务无响应：请检查 livekit-egress 进程是否在线，并检查其到 Redis/LiveKit 的网络连通。",
            status.HTTP_503_SERVICE_UNAVAILABLE,
        )
    if "requested room does not exist" in lowered:
        return (
            "LiveKit 房间不存在或已关闭，请先确保会议房间里已有在线参会者，再开始录制。",
            status.HTTP_409_CONFLICT,
        )
    if "local upload failed" in lowered or "permission denied" in lowered:
        return (
            "LiveKit egress cannot write output file. If egress runs in Docker, mount a writable volume and set LIVEKIT_EGRESS_OUTPUT_ROOT (for example /recordings).",
            status.HTTP_500_INTERNAL_SERVER_ERROR,
        )
    mapped_terminal_error = _friendly_recording_egress_terminal_error(raw_message)
    if mapped_terminal_error != raw_message:
        return (
            mapped_terminal_error,
            status.HTTP_409_CONFLICT,
        )
    if status_code in {503, 504}:
        return (
            f"LiveKit egress 服务暂时不可用：{raw_message or 'service unavailable'}",
            status.HTTP_503_SERVICE_UNAVAILABLE,
        )
    detail = raw_message or str(exc)
    return (
        f"Failed to start LiveKit egress recording: {detail}",
        status.HTTP_502_BAD_GATEWAY,
    )


def _meeting_recording_egress_start_impl(request, meeting):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can record meeting"}, status=status.HTTP_403_FORBIDDEN)
    if not meeting.allow_recording:
        return Response({"detail": "Recording is disabled for this meeting"}, status=status.HTTP_403_FORBIDDEN)
    quota_user = meeting.owner
    billing_limit_message = _billing_limit_message_for_action(
        quota_user,
        projected_recording_storage_bytes=_user_recording_storage_used_bytes(quota_user) + 1,
    )
    if billing_limit_message:
        return Response({"detail": billing_limit_message}, status=status.HTTP_403_FORBIDDEN)

    # Avoid duplicate start and also auto-finalize stale sessions.
    current_state = _finalize_active_egress_if_ready(meeting, wait_seconds=0)
    if current_state.get("active"):
        return Response(_recording_egress_payload(current_state, request=request))

    config = _recording_storage_config()
    root_path = _resolved_recording_root(config)
    if root_path is None:
        return Response(
            {"detail": "Recording storage directory is not configured by super admin"},
            status=status.HTTP_400_BAD_REQUEST,
        )
    try:
        root_path.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        return Response(
            {"detail": f"Cannot access recording storage directory: {exc}"},
            status=status.HTTP_500_INTERNAL_SERVER_ERROR,
        )

    safe_username = _safe_path_component(request.user.username, "user")
    owner_folder = f"user_{request.user.id}_{safe_username}"
    meeting_folder = f"meeting_{meeting.id}_{_safe_path_component(meeting.room_name, 'meeting')}"
    timestamp = timezone.now().strftime("%Y%m%d_%H%M%S")
    file_name = f"{timestamp}_meeting_egress_{uuid4().hex[:8]}.mp4"
    relative_path = (Path(owner_folder) / meeting_folder / file_name).as_posix()
    target_path = root_path / Path(relative_path)

    try:
        target_path.parent.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        return Response(
            {"detail": f"Failed to prepare recording output path: {exc}"},
            status=status.HTTP_500_INTERNAL_SERVER_ERROR,
        )

    layout = (request.data.get("layout") or "grid").strip().lower()
    if layout not in {"grid", "speaker"}:
        return Response(
            {"detail": "layout must be one of: grid, speaker"},
            status=status.HTTP_400_BAD_REQUEST,
        )

    try:
        egress_output_path = _egress_output_path_for_target(
            relative_path=relative_path,
            host_target_path=target_path,
        )
        started = livekit_service.start_room_composite_egress_to_file(
            meeting.room_name,
            egress_output_path,
            layout=layout,
        )
    except Exception as exc:
        detail, status_code = _friendly_livekit_egress_error(exc)
        return Response(
            {"detail": detail},
            status=status_code,
        )

    egress_id = (getattr(started, "egress_id", "") or "").strip()
    if not egress_id:
        return Response(
            {"detail": "LiveKit egress did not return egress_id"},
            status=status.HTTP_500_INTERNAL_SERVER_ERROR,
        )

    meeting.active_egress_id = egress_id
    meeting.active_egress_file_name = file_name
    meeting.active_egress_relative_path = relative_path
    meeting.active_egress_storage_root = str(root_path)
    meeting.active_egress_started_by = request.user
    meeting.active_egress_started_at = timezone.now()
    meeting.save(
        update_fields=[
            "active_egress_id",
            "active_egress_file_name",
            "active_egress_relative_path",
            "active_egress_storage_root",
            "active_egress_started_by",
            "active_egress_started_at",
        ]
    )
    log_audit(
        user=request.user,
        action="meeting.recording_egress_start",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=f"egress_id={egress_id}, file={file_name}, layout={layout}",
        ip_address=client_ip(request),
    )

    current_state = _finalize_active_egress_if_ready(meeting, wait_seconds=0)
    return Response(_recording_egress_payload(current_state, request=request))


def _meeting_recording_egress_stop_impl(request, meeting):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can record meeting"}, status=status.HTTP_403_FORBIDDEN)

    current_state = _finalize_active_egress_if_ready(meeting, wait_seconds=0)
    if not current_state.get("active"):
        return Response(_recording_egress_payload(current_state, request=request))

    egress_id = (current_state.get("egress_id") or "").strip()
    if not egress_id:
        return Response(_recording_egress_payload(current_state, request=request))

    stop_error = ""
    try:
        livekit_service.stop_egress(egress_id)
        log_audit(
            user=request.user,
            action="meeting.recording_egress_stop",
            resource_type="meeting",
            resource_id=meeting.id,
            detail=f"egress_id={egress_id}",
            ip_address=client_ip(request),
        )
    except Exception as exc:
        stop_error = _friendly_livekit_egress_error(exc)[0]

    final_state = _finalize_active_egress_if_ready(meeting, wait_seconds=20)
    if stop_error and final_state.get("active"):
        final_state["error"] = stop_error
    return Response(_recording_egress_payload(final_state, request=request))


def _meeting_recording_egress_status_impl(request, meeting):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can record meeting"}, status=status.HTTP_403_FORBIDDEN)

    raw_wait = (request.GET.get("wait_seconds") or "").strip()
    wait_seconds = 0
    if raw_wait:
        try:
            wait_seconds = int(raw_wait)
        except ValueError:
            return Response({"detail": "wait_seconds must be an integer"}, status=status.HTTP_400_BAD_REQUEST)
    wait_seconds = max(0, min(wait_seconds, 30))
    state = _finalize_active_egress_if_ready(meeting, wait_seconds=wait_seconds)
    return Response(_recording_egress_payload(state, request=request))


def _meeting_by_share_code(share_code: str):
    room_name = room_name_from_share_code(share_code)
    if not room_name:
        return None
    meeting = Meeting.objects.filter(room_name=room_name).first()
    if meeting and meeting.room_session_started_at is not None:
        _enforce_owner_room_used_limit_if_needed(meeting.owner)
        _enforce_meeting_current_room_used_limit_if_needed(meeting)
        _schedule_owner_room_limit_timer(meeting.owner_id)
        _schedule_meeting_room_limit_timer(meeting.id)
        meeting.refresh_from_db()
    return meeting


def home_view(request):
    if request.user.is_authenticated:
        return redirect("/dashboard")
    return render(request, "home.html")


@login_required(login_url="/accounts/login")
def dashboard_view(request):
    flutter_index = settings.FLUTTER_DASHBOARD_BUILD_DIR / "index.html"
    if flutter_index.exists():
        return render(
            request,
            "flutter_dashboard.html",
            {"flutter_cache_bust": _flutter_cache_bust()},
        )
    return redirect("/dashboard/legacy")


@login_required(login_url="/accounts/login")
def billing_dashboard_view(request):
    if not request.user.is_superuser:
        return redirect("/dashboard")
    flutter_index = settings.FLUTTER_DASHBOARD_BUILD_DIR / "index.html"
    if flutter_index.exists():
        return render(
            request,
            "flutter_dashboard.html",
            {"flutter_cache_bust": _flutter_cache_bust()},
        )
    return redirect("/dashboard/legacy")


@login_required(login_url="/accounts/login")
def dashboard_legacy_view(request):
    return render(request, "dashboard.html")


@login_required(login_url="/accounts/login")
def meeting_room_view(request, meeting_id: int):
    meeting = Meeting.objects.filter(id=meeting_id).first()
    if not meeting:
        return HttpResponseNotFound("Meeting not found")
    if not has_meeting_access(request.user, meeting):
        return HttpResponseNotFound("Meeting not found")
    meeting_ref = ensure_meeting_ref(meeting, request.user)
    target = f"/my/meetings/{meeting_ref}"
    query = (request.META.get("QUERY_STRING") or "").strip()
    if query:
        target = f"{target}?{query}"
    return redirect(target)


@login_required(login_url="/accounts/login")
def meeting_room_ref_view(request, meeting_ref: str):
    meeting = meeting_from_ref(request.user, meeting_ref)
    if not meeting:
        return HttpResponseNotFound("Meeting not found")
    if not has_meeting_access(request.user, meeting) and not _has_waiting_room_access(request.user, meeting):
        return HttpResponseNotFound("Meeting not found")
    return render(
        request,
        "flutter_meeting.html",
        {"flutter_cache_bust": _flutter_cache_bust()},
    )


def meeting_room_share_view(request, share_code: str):
    meeting = _meeting_by_share_code(share_code)
    if not meeting:
        return HttpResponseNotFound("Meeting not found")
    return render(
        request,
        "flutter_meeting.html",
        {"flutter_cache_bust": _flutter_cache_bust()},
    )


def register_page_view(request):
    if request.user.is_authenticated:
        return redirect("/dashboard")

    if request.method == "POST":
        form = MeetingRegisterForm(request.POST)
        if form.is_valid():
            username = form.cleaned_data["username"]
            email = form.cleaned_data["email"]
            if User.objects.filter(Q(username=username) | Q(email=email)).exists():
                form.add_error(None, "用户名或邮箱已存在")
                return render(request, "registration/register.html", {"form": form})
            user = form.save(commit=False)
            user.email = email
            user.save()
            _profile_for_user(user)
            _billing_profile_for_user(user)

            base_org_name = f"{username}-workspace"
            org_name = base_org_name
            suffix = 1
            while Organization.objects.filter(name=org_name).exists():
                suffix += 1
                org_name = f"{base_org_name}-{suffix}"
            org = Organization.objects.create(name=org_name, owner_user=user)
            OrganizationMember.objects.create(organization=org, user=user, is_org_admin=True)

            log_audit(
                user=user,
                action="auth.register_page",
                resource_type="user",
                resource_id=user.id,
                detail="Registered from web page",
                ip_address=client_ip(request),
            )
            auth_login(request, user)
            return redirect("/dashboard")
    else:
        form = MeetingRegisterForm()
    return render(request, "registration/register.html", {"form": form})


@login_required(login_url="/accounts/login")
def session_jwt(request):
    refresh = RefreshToken.for_user(request.user)
    token = str(refresh.access_token)
    return JsonResponse({"access_token": token, "token_type": "bearer"})


@login_required(login_url="/accounts/login")
def session_logout(request):
    auth_logout(request)
    return redirect("/")


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def livekit_webhook(request):
    auth_header = request.headers.get("Authorization", "")
    auth_token = _extract_bearer_token(auth_header)
    if not auth_token:
        return Response(
            {"detail": "Missing LiveKit webhook authorization token"},
            status=status.HTTP_401_UNAUTHORIZED,
        )

    try:
        raw_body = request.body.decode("utf-8")
    except UnicodeDecodeError:
        return Response(
            {"detail": "Invalid webhook body encoding"},
            status=status.HTTP_400_BAD_REQUEST,
        )

    try:
        webhook_event = _livekit_webhook_receiver().receive(raw_body, auth_token)
    except Exception:
        return Response(
            {"detail": "Invalid LiveKit webhook signature"},
            status=status.HTTP_401_UNAUTHORIZED,
        )

    event_name = (getattr(webhook_event, "event", "") or "").strip().lower()
    if event_name not in _LIVEKIT_WEBHOOK_MONITORED_EVENTS:
        return Response({"ok": True, "ignored": True, "event": event_name})

    room_name = (getattr(getattr(webhook_event, "room", None), "name", "") or "").strip()
    if not room_name:
        return Response({"ok": True, "ignored": True, "event": event_name, "reason": "missing_room_name"})

    meeting = Meeting.objects.filter(room_name=room_name).first()
    if not meeting:
        return Response({"ok": True, "ignored": True, "event": event_name, "reason": "meeting_not_found"})

    online_count = _room_online_count_from_webhook_event(meeting, webhook_event, event_name=event_name)
    state_changed = _sync_room_session_state_with_online_count(
        meeting.id,
        online_count=online_count,
    )
    return Response(
        {
            "ok": True,
            "event": event_name,
            "room_name": room_name,
            "online_count": online_count,
            "state_changed": state_changed,
        }
    )


@api_view(["GET", "PATCH"])
@permission_classes([IsAuthenticated])
def my_profile(request):
    profile = _profile_for_user(request.user)
    if request.method == "GET":
        return Response(UserProfileSerializer(profile).data)

    serializer = UserProfileUpdateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    payload = serializer.validated_data

    updated_fields = []
    if "avatar_url" in payload:
        profile.avatar_url = (payload.get("avatar_url") or "").strip()
        updated_fields.append("avatar_url")
    if "default_display_name" in payload:
        display_name = (payload.get("default_display_name") or "").strip()
        profile.default_display_name = display_name or request.user.username
        updated_fields.append("default_display_name")

    if updated_fields:
        updated_fields.append("updated_at")
        profile.save(update_fields=updated_fields)
        log_audit(
            user=request.user,
            action="profile.update",
            resource_type="user",
            resource_id=request.user.id,
            detail="fields=" + ",".join(updated_fields),
            ip_address=client_ip(request),
        )
    return Response(UserProfileSerializer(profile).data)


@api_view(["GET", "PATCH"])
@permission_classes([IsAuthenticated])
def recording_storage_config(request):
    if not request.user.is_superuser:
        return Response({"detail": "Only super admin can manage recording storage"}, status=status.HTTP_403_FORBIDDEN)

    config = _recording_storage_config()
    if request.method == "GET":
        return Response(RecordingStorageConfigSerializer(config).data)

    serializer = RecordingStorageConfigUpdateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    raw_root = (serializer.validated_data.get("storage_root") or "").strip()
    if not raw_root:
        return Response({"detail": "storage_root is required"}, status=status.HTTP_400_BAD_REQUEST)

    try:
        root_path = Path(raw_root).expanduser()
        if not root_path.is_absolute():
            root_path = (Path(settings.BASE_DIR) / root_path).resolve()
        else:
            root_path = root_path.resolve()
        root_path.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        return Response(
            {"detail": f"Invalid storage_root: {exc}"},
            status=status.HTTP_400_BAD_REQUEST,
        )

    config.storage_root = str(root_path)
    config.updated_by = request.user
    config.save(update_fields=["storage_root", "updated_by", "updated_at"])
    log_audit(
        user=request.user,
        action="recording.storage_config_update",
        resource_type="recording_storage",
        resource_id=config.id,
        detail=f"storage_root={config.storage_root}",
        ip_address=client_ip(request),
    )
    return Response(RecordingStorageConfigSerializer(config).data)


def _billing_user_payload(user: User, *, now=None) -> dict:
    now = now or timezone.now()
    profile = _billing_profile_for_user(user)
    usage = _billing_usage_snapshot(user, now=now)
    limits = _billing_limits_for_user(user)
    exceeded_keys = _billing_exceeded_keys(usage, limits)
    return {
        "user_id": user.id,
        "username": user.username,
        "email": user.email,
        "is_superuser": bool(user.is_superuser),
        "plan_id": profile.plan_id,
        "plan_name": profile.plan.name if profile.plan_id else None,
        "usage": usage,
        "limits": limits,
        "exceeded_keys": exceeded_keys,
        "room_peak_count": int(profile.room_peak_count or 0),
        "accumulated_room_used_seconds": int(profile.accumulated_room_used_seconds or 0),
        "updated_at": profile.updated_at,
    }


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def billing_me(request):
    now = timezone.now()
    return Response(_billing_user_payload(request.user, now=now))


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def billing_overview(request):
    if not request.user.is_superuser:
        return Response({"detail": "Only super admin can view billing overview"}, status=status.HTTP_403_FORBIDDEN)

    now = timezone.now()
    plans = BillingPlan.objects.all().order_by("name")
    users = User.objects.all().order_by("date_joined", "id")
    users_payload = [_billing_user_payload(user, now=now) for user in users]
    return Response(
        {
            "plans": BillingPlanSerializer(plans, many=True).data,
            "users": users_payload,
        }
    )


@api_view(["GET", "POST"])
@permission_classes([IsAuthenticated])
def billing_plans(request):
    if not request.user.is_superuser:
        return Response({"detail": "Only super admin can manage billing plans"}, status=status.HTTP_403_FORBIDDEN)

    if request.method == "GET":
        plans = BillingPlan.objects.all().order_by("name")
        return Response(BillingPlanSerializer(plans, many=True).data)

    serializer = BillingPlanUpsertSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    payload = serializer.validated_data
    name = (payload.get("name") or "").strip()
    if not name:
        return Response({"detail": "name is required"}, status=status.HTTP_400_BAD_REQUEST)
    if BillingPlan.objects.filter(name=name).exists():
        return Response({"detail": "Plan name already exists"}, status=status.HTTP_400_BAD_REQUEST)

    plan = BillingPlan.objects.create(
        name=name,
        description=(payload.get("description") or "").strip(),
        max_active_rooms=payload.get("max_active_rooms", 1),
        max_room_participants=payload.get("max_room_participants", 100),
        max_room_used_seconds=payload.get("max_room_used_seconds", 0),
        max_current_room_used_seconds=payload.get("max_current_room_used_seconds", 0),
        max_recording_storage_bytes=payload.get("max_recording_storage_bytes", 0),
        max_meeting_count=payload.get("max_meeting_count", 10),
    )
    log_audit(
        user=request.user,
        action="billing.plan_create",
        resource_type="billing_plan",
        resource_id=plan.id,
        detail=f"name={plan.name}",
        ip_address=client_ip(request),
    )
    return Response(BillingPlanSerializer(plan).data)


@api_view(["PATCH", "DELETE"])
@permission_classes([IsAuthenticated])
def billing_plan_detail(request, plan_id: int):
    if not request.user.is_superuser:
        return Response({"detail": "Only super admin can manage billing plans"}, status=status.HTTP_403_FORBIDDEN)

    plan = BillingPlan.objects.filter(id=plan_id).first()
    if not plan:
        return Response({"detail": "Billing plan not found"}, status=status.HTTP_404_NOT_FOUND)

    if request.method == "DELETE":
        plan_name = plan.name
        plan.delete()
        log_audit(
            user=request.user,
            action="billing.plan_delete",
            resource_type="billing_plan",
            resource_id=plan_id,
            detail=f"name={plan_name}",
            ip_address=client_ip(request),
        )
        return Response({"ok": True, "id": plan_id})

    serializer = BillingPlanUpsertSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    payload = serializer.validated_data
    updated_fields: list[str] = []

    if "name" in payload:
        next_name = (payload.get("name") or "").strip()
        if not next_name:
            return Response({"detail": "name cannot be empty"}, status=status.HTTP_400_BAD_REQUEST)
        if BillingPlan.objects.exclude(id=plan.id).filter(name=next_name).exists():
            return Response({"detail": "Plan name already exists"}, status=status.HTTP_400_BAD_REQUEST)
        if next_name != plan.name:
            plan.name = next_name
            updated_fields.append("name")

    if "description" in payload:
        next_description = (payload.get("description") or "").strip()
        if next_description != plan.description:
            plan.description = next_description
            updated_fields.append("description")

    numeric_fields = (
        "max_active_rooms",
        "max_room_participants",
        "max_room_used_seconds",
        "max_current_room_used_seconds",
        "max_recording_storage_bytes",
        "max_meeting_count",
    )
    for field in numeric_fields:
        if field not in payload:
            continue
        next_value = int(payload[field])
        if getattr(plan, field) == next_value:
            continue
        setattr(plan, field, next_value)
        updated_fields.append(field)

    if updated_fields:
        updated_fields.append("updated_at")
        plan.save(update_fields=updated_fields)
        log_audit(
            user=request.user,
            action="billing.plan_update",
            resource_type="billing_plan",
            resource_id=plan.id,
            detail=f"fields={','.join(updated_fields)}",
            ip_address=client_ip(request),
        )

    return Response(BillingPlanSerializer(plan).data)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def billing_user_plan_assign(request, user_id: int):
    if not request.user.is_superuser:
        return Response({"detail": "Only super admin can assign billing plans"}, status=status.HTTP_403_FORBIDDEN)
    target_user = User.objects.filter(id=user_id).first()
    if not target_user:
        return Response({"detail": "Target user not found"}, status=status.HTTP_404_NOT_FOUND)

    serializer = UserBillingPlanAssignSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    plan_id = serializer.validated_data.get("plan_id")

    plan = None
    if plan_id is not None:
        plan = BillingPlan.objects.filter(id=plan_id).first()
        if not plan:
            return Response({"detail": "Billing plan not found"}, status=status.HTTP_404_NOT_FOUND)

    profile = _billing_profile_for_user(target_user)
    profile.plan = plan
    profile.save(update_fields=["plan", "updated_at"])

    log_audit(
        user=request.user,
        action="billing.user_plan_assign",
        resource_type="user",
        resource_id=target_user.id,
        detail=f"plan_id={plan.id if plan else 'null'}",
        ip_address=client_ip(request),
    )
    return Response(_billing_user_payload(target_user))


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_recordings(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_recordings_impl(request, meeting)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_recordings_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_recordings_impl(request, meeting)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_recording_egress_start(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_recording_egress_start_impl(request, meeting)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_recording_egress_start_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_recording_egress_start_impl(request, meeting)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_recording_egress_stop(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_recording_egress_stop_impl(request, meeting)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_recording_egress_stop_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_recording_egress_stop_impl(request, meeting)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_recording_egress_status(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_recording_egress_status_impl(request, meeting)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_recording_egress_status_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_recording_egress_status_impl(request, meeting)


def _meeting_recordings_impl(request, meeting):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can record meeting"}, status=status.HTTP_403_FORBIDDEN)
    if not meeting.allow_recording:
        return Response({"detail": "Recording is disabled for this meeting"}, status=status.HTTP_403_FORBIDDEN)

    upload = request.FILES.get("file")
    if upload is None:
        return Response({"detail": "file is required"}, status=status.HTTP_400_BAD_REQUEST)
    if getattr(upload, "size", 0) <= 0:
        return Response({"detail": "Uploaded recording file is empty"}, status=status.HTTP_400_BAD_REQUEST)
    quota_user = meeting.owner
    projected_storage = _user_recording_storage_used_bytes(quota_user) + int(getattr(upload, "size", 0) or 0)
    billing_limit_message = _billing_limit_message_for_action(
        quota_user,
        projected_recording_storage_bytes=projected_storage,
    )
    if billing_limit_message:
        return Response({"detail": billing_limit_message}, status=status.HTTP_403_FORBIDDEN)

    duration_seconds = None
    raw_duration = request.data.get("duration_seconds")
    if raw_duration not in (None, ""):
        try:
            duration_seconds = int(raw_duration)
        except (TypeError, ValueError):
            return Response({"detail": "duration_seconds must be an integer"}, status=status.HTTP_400_BAD_REQUEST)
        if duration_seconds < 0:
            return Response({"detail": "duration_seconds must be >= 0"}, status=status.HTTP_400_BAD_REQUEST)

    config = _recording_storage_config()
    root_path = _resolved_recording_root(config)
    if root_path is None:
        return Response(
            {"detail": "Recording storage directory is not configured by super admin"},
            status=status.HTTP_400_BAD_REQUEST,
        )
    try:
        root_path.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        return Response(
            {"detail": f"Cannot access recording storage directory: {exc}"},
            status=status.HTTP_500_INTERNAL_SERVER_ERROR,
        )

    safe_username = _safe_path_component(request.user.username, "user")
    owner_folder = f"user_{request.user.id}_{safe_username}"
    meeting_folder = f"meeting_{meeting.id}_{_safe_path_component(meeting.room_name, 'meeting')}"

    original_name = (getattr(upload, "name", "") or "recording.webm").strip()
    extension = Path(original_name).suffix.lower()
    if not extension or len(extension) > 10:
        extension = ".webm"
    stem = _safe_path_component(Path(original_name).stem, "recording")
    timestamp = timezone.now().strftime("%Y%m%d_%H%M%S")
    file_name = f"{timestamp}_{stem}_{uuid4().hex[:8]}{extension}"

    relative_path = Path(owner_folder) / meeting_folder / file_name
    target_path = root_path / relative_path
    try:
        target_path.parent.mkdir(parents=True, exist_ok=True)
        with open(target_path, "wb") as output:
            for chunk in upload.chunks():
                output.write(chunk)
        size_bytes = target_path.stat().st_size
    except Exception as exc:
        return Response(
            {"detail": f"Failed to store recording file: {exc}"},
            status=status.HTTP_500_INTERNAL_SERVER_ERROR,
        )

    display_name = ""
    if actor_membership and actor_membership.display_name:
        display_name = actor_membership.display_name
    if not display_name:
        display_name = _fallback_display_name(request.user)

    recording = MeetingRecording.objects.create(
        meeting=meeting,
        owner=request.user,
        recorded_by_display_name=display_name,
        file_name=file_name,
        storage_root=str(root_path),
        relative_path=relative_path.as_posix(),
        mime_type=(getattr(upload, "content_type", "") or "").strip(),
        size_bytes=size_bytes,
        duration_seconds=duration_seconds,
    )
    log_audit(
        user=request.user,
        action="meeting.recording_upload",
        resource_type="meeting_recording",
        resource_id=recording.id,
        detail=(
            f"meeting={meeting.id}, file={recording.file_name}, "
            f"size={recording.size_bytes}, owner={request.user.id}"
        ),
        ip_address=client_ip(request),
    )
    return Response(MeetingRecordingSerializer(recording, context={"request": request}).data)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def recordings(request):
    queryset = MeetingRecording.objects.select_related("meeting", "owner").order_by("-created_at")
    if not request.user.is_superuser:
        queryset = queryset.filter(owner=request.user)

    q = (request.GET.get("q") or "").strip()
    if q:
        queryset = queryset.filter(
            Q(file_name__icontains=q)
            | Q(meeting__title__icontains=q)
            | Q(meeting__room_name__icontains=q)
            | Q(meeting_title_snapshot__icontains=q)
            | Q(meeting_room_name_snapshot__icontains=q)
            | Q(owner__username__icontains=q)
            | Q(recorded_by_display_name__icontains=q)
            | Q(storage_root__icontains=q)
            | Q(relative_path__icontains=q)
        )

    meeting_id = (request.GET.get("meeting_id") or "").strip()
    if meeting_id:
        try:
            meeting_id_int = int(meeting_id)
            queryset = queryset.filter(
                Q(meeting_id=meeting_id_int)
                | Q(meeting_id_snapshot=meeting_id_int)
            )
        except ValueError:
            return Response({"detail": "meeting_id must be an integer"}, status=status.HTTP_400_BAD_REQUEST)

    limit_raw = (request.GET.get("limit") or "").strip()
    limit = 200
    if limit_raw:
        try:
            limit = int(limit_raw)
        except ValueError:
            return Response({"detail": "limit must be an integer"}, status=status.HTTP_400_BAD_REQUEST)
    limit = max(1, min(limit, 500))

    rows = list(queryset[:limit])
    return Response(MeetingRecordingSerializer(rows, many=True, context={"request": request}).data)


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def recording_delete(request, recording_id: int):
    recording = MeetingRecording.objects.select_related("meeting", "owner").filter(id=recording_id).first()
    if not recording:
        return Response({"detail": "Recording not found"}, status=status.HTTP_404_NOT_FOUND)
    if not request.user.is_superuser and recording.owner_id != request.user.id:
        return Response({"detail": "No permission to delete this recording"}, status=status.HTTP_403_FORBIDDEN)

    _delete_recording_file_if_exists(recording)
    deleted_recording_id = recording.id
    deleted_file_name = recording.file_name
    meeting_id = recording.meeting_id
    owner_id = recording.owner_id
    recording.delete()

    log_audit(
        user=request.user,
        action="meeting.recording_delete",
        resource_type="meeting_recording",
        resource_id=deleted_recording_id,
        detail=f"meeting={meeting_id}, owner={owner_id}, file={deleted_file_name}",
        ip_address=client_ip(request),
    )
    return Response({"ok": True, "id": deleted_recording_id})


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def recording_download(request, recording_id: int):
    recording = MeetingRecording.objects.select_related("meeting", "owner").filter(id=recording_id).first()
    if not recording:
        return Response({"detail": "Recording not found"}, status=status.HTTP_404_NOT_FOUND)
    if not request.user.is_superuser and recording.owner_id != request.user.id:
        return Response({"detail": "No permission to download this recording"}, status=status.HTTP_403_FORBIDDEN)

    target_path = _resolve_recording_file_path(recording)
    if target_path is None or not target_path.exists() or not target_path.is_file():
        return Response({"detail": "Recording file does not exist"}, status=status.HTTP_404_NOT_FOUND)

    log_audit(
        user=request.user,
        action="meeting.recording_download",
        resource_type="meeting_recording",
        resource_id=recording.id,
        detail=f"meeting={recording.meeting_id}, owner={recording.owner_id}",
        ip_address=client_ip(request),
    )
    response = FileResponse(open(target_path, "rb"), as_attachment=True, filename=recording.file_name)
    if recording.mime_type:
        response["Content-Type"] = recording.mime_type
    return response


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def register_api(request):
    serializer = RegisterSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    data = serializer.validated_data

    if User.objects.filter(Q(username=data["username"]) | Q(email=data["email"])).exists():
        return Response({"detail": "Username or email already exists"}, status=status.HTTP_400_BAD_REQUEST)

    user = User.objects.create_user(
        username=data["username"],
        email=data["email"],
        password=data["password"],
    )
    _profile_for_user(user)
    _billing_profile_for_user(user)

    base_org_name = f"{data['username']}-workspace"
    org_name = base_org_name
    suffix = 1
    while Organization.objects.filter(name=org_name).exists():
        suffix += 1
        org_name = f"{base_org_name}-{suffix}"
    org = Organization.objects.create(name=org_name, owner_user=user)
    OrganizationMember.objects.create(organization=org, user=user, is_org_admin=True)

    log_audit(
        user=user,
        action="auth.register",
        resource_type="user",
        resource_id=user.id,
        detail="User registered and workspace initialized",
        ip_address=client_ip(request),
    )
    return Response(UserOutSerializer(user).data)


@api_view(["POST"])
@authentication_classes([])
@permission_classes([AllowAny])
def login_api(request):
    username = request.data.get("username") or request.POST.get("username")
    password = request.data.get("password") or request.POST.get("password")
    if not username or not password:
        return Response({"detail": "username and password are required"}, status=status.HTTP_400_BAD_REQUEST)

    ip = client_ip(request)
    now = timezone.now()
    attempt = LoginAttempt.objects.filter(username=username, ip_address=ip).first()
    if attempt and attempt.locked_until and attempt.locked_until > now:
        return Response(
            {"detail": f"Too many failed attempts. Try again after {attempt.locked_until.isoformat()}"},
            status=status.HTTP_429_TOO_MANY_REQUESTS,
        )

    user = authenticate(request=request, username=username, password=password)
    if not user:
        if not attempt:
            attempt = LoginAttempt.objects.create(username=username, ip_address=ip, failed_count=0)
        attempt.failed_count += 1
        attempt.last_failed_at = now
        if attempt.failed_count >= 5:
            attempt.locked_until = now + timedelta(minutes=15)
        attempt.save(update_fields=["failed_count", "last_failed_at", "locked_until"])
        log_audit(
            action="auth.login_failed",
            resource_type="user",
            resource_id=username,
            detail=f"failed_count={attempt.failed_count}",
            ip_address=ip,
        )
        return Response(
            {"detail": "Incorrect username or password"},
            status=status.HTTP_401_UNAUTHORIZED,
        )

    if attempt:
        attempt.delete()
    refresh = RefreshToken.for_user(user)
    access_token = str(refresh.access_token)
    log_audit(
        user=user,
        action="auth.login_success",
        resource_type="user",
        resource_id=user.id,
        ip_address=ip,
    )
    return Response({"access_token": access_token, "token_type": "bearer"})


def _refresh_meeting_runtime_state(meeting) -> None:
    if meeting.room_session_started_at is not None:
        _enforce_owner_room_used_limit_if_needed(meeting.owner)
        _enforce_meeting_current_room_used_limit_if_needed(meeting)
        _schedule_owner_room_limit_timer(meeting.owner_id)
        _schedule_meeting_room_limit_timer(meeting.id)
        meeting.refresh_from_db()


def _resolve_user_meeting(user, lookup: MeetingLookup, *, allow_waiting_room: bool = False):
    meeting = lookup.resolve(user)
    if not meeting:
        return None, Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)

    _refresh_meeting_runtime_state(meeting)

    if has_meeting_access(user, meeting):
        return meeting, None
    if allow_waiting_room and _has_waiting_room_access(user, meeting):
        return meeting, None

    if lookup.hidden_forbidden:
        return None, Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)
    return None, Response({"detail": "No permission to access this meeting"}, status=status.HTTP_403_FORBIDDEN)


def _resolve_user_meeting_with_membership(
    user,
    lookup: MeetingLookup,
    *,
    allow_waiting_room: bool = False,
):
    meeting = lookup.resolve(user)
    if not meeting:
        return None, None, Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)

    _refresh_meeting_runtime_state(meeting)

    membership = None
    if not user.is_superuser and meeting.owner_id != user.id:
        membership = MeetingMember.objects.filter(meeting=meeting, user=user).first()
        if membership is not None:
            return meeting, membership, None
    else:
        return meeting, membership, None

    if allow_waiting_room and _has_waiting_room_access(user, meeting):
        return meeting, membership, None

    if lookup.hidden_forbidden:
        return None, None, Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)
    return None, None, Response({"detail": "No permission to access this meeting"}, status=status.HTTP_403_FORBIDDEN)


def _meeting_for_user_or_403(user, meeting_id: int):
    return _resolve_user_meeting(
        user,
        MeetingLookup(meeting_id=meeting_id),
    )


def _meeting_endpoint(
    request,
    *,
    lookup: MeetingLookup,
    impl,
    allow_waiting_room: bool = False,
):
    meeting, error = _resolve_user_meeting(
        request.user,
        lookup,
        allow_waiting_room=allow_waiting_room,
    )
    if error:
        return error
    return impl(request, meeting)


def _meeting_endpoint_by_id(request, meeting_id: int, impl):
    return _meeting_endpoint(
        request,
        lookup=MeetingLookup(meeting_id=meeting_id),
        impl=impl,
    )


def _has_waiting_room_access(user, meeting) -> bool:
    if not getattr(user, "is_authenticated", False):
        return False
    if not meeting.waiting_room_enabled:
        return False
    if MeetingBlockedMember.objects.filter(meeting=meeting, user=user).exists():
        return False
    return MeetingWaitingRoomEntry.objects.filter(meeting=meeting, user=user).exists()


def _meeting_for_user_ref_or_404(user, meeting_ref: str, *, allow_waiting_room: bool = False):
    return _resolve_user_meeting(
        user,
        MeetingLookup(meeting_ref=meeting_ref, hidden_forbidden=True),
        allow_waiting_room=allow_waiting_room,
    )


def _can_edit_meeting(user, meeting) -> bool:
    if user.is_superuser:
        return True
    membership = meeting_membership(meeting.id, user.id)
    if not membership:
        return False
    return membership.role == MeetingRole.HOST


def _can_delete_meeting(user, meeting) -> bool:
    if user.is_superuser:
        return True
    membership = meeting_membership(meeting.id, user.id)
    if not membership:
        return False
    return membership.role == MeetingRole.HOST


def _apply_meeting_payload(meeting, payload: dict):
    for key, value in payload.items():
        if key == "meeting_password":
            setattr(meeting, key, (value or "").strip() or None)
        elif key == "meeting_timezone":
            setattr(meeting, key, (value or "").strip() or "Asia/Shanghai")
        else:
            setattr(meeting, key, value)


def _ics_escape_text(value: str) -> str:
    text = (value or "").replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,")
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return text.replace("\n", "\\n")


def _ics_utc(dt_value) -> str:
    return dt_value.astimezone(dt_timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _meeting_outlook_ics_response(request, meeting) -> HttpResponse:
    scheduled_start = meeting.scheduled_start or meeting.created_at or timezone.now()
    if timezone.is_naive(scheduled_start):
        scheduled_start = timezone.make_aware(scheduled_start, timezone.get_current_timezone())

    duration_minutes = max(1, int(meeting.duration_minutes or 30))
    scheduled_end = scheduled_start + timedelta(minutes=duration_minutes)
    meeting_ref = ensure_meeting_ref(meeting, request.user)
    share_code = build_meeting_share_code(meeting.room_name)
    share_url = request.build_absolute_uri(f"/m/{share_code}")
    entry_url = request.build_absolute_uri(
        f"/my/meetings/{meeting_ref}?autojoin=1"
    )
    host_name = _host_without_port(request.get_host()) or "smart-meeting.local"
    uid = f"meeting-{meeting.id}-{_ics_utc(scheduled_start)}@{host_name}"

    description_lines = [
        f"会议号: {meeting.room_name}",
        f"参会链接: {entry_url}",
        f"分享链接: {share_url}",
    ]
    if meeting.description:
        description_lines.insert(0, meeting.description.strip())
    if meeting.meeting_password:
        description_lines.append(f"会议密码: {meeting.meeting_password}")

    title = (meeting.title or "").strip() or f"会议 {meeting.room_name}"
    calendar_lines = [
        "BEGIN:VCALENDAR",
        "PRODID:-//Smart Meeting//Meeting Calendar//CN",
        "VERSION:2.0",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "BEGIN:VEVENT",
        f"UID:{uid}",
        f"DTSTAMP:{_ics_utc(timezone.now())}",
        f"DTSTART:{_ics_utc(scheduled_start)}",
        f"DTEND:{_ics_utc(scheduled_end)}",
        f"SUMMARY:{_ics_escape_text(title)}",
        f"DESCRIPTION:{_ics_escape_text(chr(10).join(description_lines))}",
        "LOCATION:Online Meeting",
        f"URL:{share_url}",
        "SEQUENCE:0",
        "STATUS:CONFIRMED",
        "TRANSP:OPAQUE",
        "END:VEVENT",
        "END:VCALENDAR",
        "",
    ]
    ics_content = "\r\n".join(calendar_lines)

    safe_title = re.sub(r"[^A-Za-z0-9_-]+", "-", title).strip("-")[:60] or f"meeting-{meeting.id}"
    response = HttpResponse(ics_content, content_type="text/calendar; charset=utf-8")
    response["Content-Disposition"] = f'attachment; filename="{safe_title}.ics"'
    response["Cache-Control"] = "no-cache"
    return response


def _ensure_actual_started_at(meeting) -> None:
    if meeting.actual_started_at is not None:
        return
    meeting.actual_started_at = timezone.now()
    meeting.save(update_fields=["actual_started_at"])


_WAITING_ROOM_DENIED_DETAIL = (
    "This meeting has waiting room enabled. Ask the host to admit you before joining."
)
_WAITING_ROOM_REJECTED_DETAIL = "Your waiting room request has been rejected by host/cohost."
_REMOVED_AND_BLOCKED_DETAIL = "You were removed by host/cohost and cannot rejoin this meeting."
_GUEST_LINK_JOIN_DISABLED_DETAIL = "Guest link join is disabled for this meeting."
_MESSAGE_RECALL_WINDOW = timedelta(minutes=3)


def _meeting_role_for_user(meeting, user, membership=None):
    if user.is_superuser or meeting.owner_id == user.id:
        return MeetingRole.HOST
    record = membership
    if record is None:
        record = MeetingMember.objects.filter(meeting=meeting, user=user).first()
    return record.role if record else None


def _can_bypass_waiting_room(meeting, user, membership=None) -> bool:
    if not meeting.waiting_room_enabled:
        return True
    role = _meeting_role_for_user(meeting, user, membership=membership)
    return role in {MeetingRole.HOST, MeetingRole.COHOST}


def _bool_value(value, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
    return default


def _is_moderator_role(role: str) -> bool:
    return role in {MeetingRole.HOST, MeetingRole.COHOST}


def _is_blocked_member(meeting, user) -> bool:
    return MeetingBlockedMember.objects.filter(meeting=meeting, user=user).exists()


def _resolve_member_control_override(default_value: bool, override_value) -> bool:
    if override_value is None:
        return default_value
    return bool(override_value)


def _member_can_self_unmute(meeting, membership) -> bool:
    if _is_moderator_role(membership.role):
        return True
    return _resolve_member_control_override(
        meeting.allow_self_unmute,
        membership.allow_self_unmute_override,
    )


def _member_can_video(meeting, membership) -> bool:
    if _is_moderator_role(membership.role):
        return True
    return _resolve_member_control_override(
        meeting.allow_member_video,
        membership.allow_member_video_override,
    )


def _member_can_chat(meeting, membership) -> bool:
    if _is_moderator_role(membership.role):
        return True
    return _resolve_member_control_override(
        meeting.allow_chat,
        membership.allow_chat_override,
    )


def _member_can_screen_share(meeting, membership) -> bool:
    if _is_moderator_role(membership.role):
        return True
    return _resolve_member_control_override(
        meeting.allow_screen_share,
        membership.allow_screen_share_override,
    )


def _meeting_publish_policy(meeting, membership) -> dict:
    allow_mic = _member_can_self_unmute(meeting, membership)
    allow_video = _member_can_video(meeting, membership)
    allow_screen_share = _member_can_screen_share(meeting, membership)
    allow_chat = _member_can_chat(meeting, membership)

    publish_sources: list[str] = []
    if allow_mic:
        publish_sources.append("microphone")
    if allow_video:
        publish_sources.append("camera")
    if allow_screen_share:
        publish_sources.extend(["screen_share", "screen_share_audio"])

    return {
        "can_publish": bool(publish_sources),
        "can_subscribe": True,
        "can_publish_data": allow_chat,
        "can_publish_sources": publish_sources,
        "allow_mic": allow_mic,
        "allow_video": allow_video,
        "allow_screen_share": allow_screen_share,
        "allow_chat": allow_chat,
    }


def _sync_livekit_permissions_for_member(
    meeting,
    membership,
    *,
    force_unmute_microphone: bool = False,
    force_unmute_camera: bool = False,
) -> None:
    policy = _meeting_publish_policy(meeting, membership)
    identity = _stable_participant_identity(membership.user)
    livekit_service.update_participant_permissions(
        meeting.room_name,
        identity,
        can_publish=policy["can_publish"],
        can_subscribe=policy["can_subscribe"],
        can_publish_data=policy["can_publish_data"],
        can_publish_sources=policy["can_publish_sources"],
    )

    if not policy["allow_mic"] or membership.muted_by_host:
        livekit_service.mute_participant_track_sources(
            meeting.room_name,
            identity,
            track_sources=["microphone"],
            muted=True,
        )
    elif force_unmute_microphone:
        livekit_service.mute_participant_track_sources(
            meeting.room_name,
            identity,
            track_sources=["microphone"],
            muted=False,
        )

    if not policy["allow_video"] or membership.video_blocked_by_host:
        livekit_service.mute_participant_track_sources(
            meeting.room_name,
            identity,
            track_sources=["camera"],
            muted=True,
        )
    elif force_unmute_camera:
        livekit_service.mute_participant_track_sources(
            meeting.room_name,
            identity,
            track_sources=["camera"],
            muted=False,
        )

    if not policy["allow_screen_share"]:
        livekit_service.mute_participant_track_sources(
            meeting.room_name,
            identity,
            track_sources=["screen_share", "screen_share_audio"],
            muted=True,
        )


def _sync_livekit_permissions_for_members(meeting, members: Iterable[MeetingMember]) -> None:
    for membership in members:
        try:
            _sync_livekit_permissions_for_member(meeting, membership)
        except Exception:
            # Runtime media control should not break API behavior.
            continue


def _mark_waiting_room_status(
    meeting,
    user,
    status_value: str,
    *,
    reviewed_by=None,
) -> MeetingWaitingRoomEntry:
    entry, _ = MeetingWaitingRoomEntry.objects.get_or_create(
        meeting=meeting,
        user=user,
        defaults={
            "status": status_value,
            "reviewed_by": reviewed_by,
        },
    )

    changed_fields = []
    if entry.status != status_value:
        entry.status = status_value
        changed_fields.append("status")
    if reviewed_by is not None and entry.reviewed_by_id != reviewed_by.id:
        entry.reviewed_by = reviewed_by
        changed_fields.append("reviewed_by")
    if changed_fields:
        changed_fields.append("updated_at")
        entry.save(update_fields=changed_fields)
    return entry


def _waiting_room_gate_response(meeting, user, membership=None):
    if not meeting.waiting_room_enabled:
        return None
    role = _meeting_role_for_user(meeting, user, membership=membership)
    if role in {MeetingRole.HOST, MeetingRole.COHOST}:
        return None

    entry, _ = MeetingWaitingRoomEntry.objects.get_or_create(
        meeting=meeting,
        user=user,
        defaults={"status": WaitingRoomStatus.PENDING},
    )
    if entry.status == WaitingRoomStatus.APPROVED:
        return None
    response_payload = {
        "waiting_room_status": entry.status,
        "meeting_ref": ensure_meeting_ref(meeting, user),
        "room_name": meeting.room_name,
    }
    if entry.status == WaitingRoomStatus.REJECTED:
        response_payload["detail"] = _WAITING_ROOM_REJECTED_DETAIL
        return Response(
            response_payload,
            status=status.HTTP_403_FORBIDDEN,
        )
    response_payload["detail"] = _WAITING_ROOM_DENIED_DETAIL
    return Response(
        response_payload,
        status=status.HTTP_403_FORBIDDEN,
    )


def _stable_participant_identity(user: User) -> str:
    # Keep identity stable per account so each account has only one participant in the same room.
    normalized_username = "".join(
        ch if ch.isalnum() or ch in {"-", "_"} else "_"
        for ch in user.username
    )
    base = f"u{user.id}_{normalized_username or 'user'}"
    return base[:64]


def _guest_participant_identity(display_name: str) -> str:
    normalized_name = "".join(
        ch if ch.isascii() and (ch.isalnum() or ch in {"-", "_"}) else "_"
        for ch in display_name
    ).strip("_")
    suffix = normalized_name.lower() or "guest"
    return f"g_{uuid4().hex[:10]}_{suffix}"[:64]


_TRACK_SOURCE_ORDER = ("microphone", "camera", "screen_share", "screen_share_audio")
_TRACK_SOURCE_VALUE_TO_NAME = {
    1: "camera",
    2: "microphone",
    3: "screen_share",
    4: "screen_share_audio",
}
_TRACK_SOURCE_TOKEN_TO_NAME = {
    "camera": "camera",
    "microphone": "microphone",
    "screen_share": "screen_share",
    "screenshare": "screen_share",
    "screen_share_audio": "screen_share_audio",
    "screenshareaudio": "screen_share_audio",
}
_HOST_FORCE_OPEN_MIC_METADATA_KEY = "host_force_open_mic_nonce"
_HOST_FORCE_OPEN_VIDEO_METADATA_KEY = "host_force_open_video_nonce"


def _user_id_from_participant_identity(identity: str) -> int | None:
    trimmed = (identity or "").strip()
    if not trimmed.startswith("u"):
        return None
    marker = trimmed.find("_")
    id_part = trimmed[1:marker] if marker > 1 else trimmed[1:]
    return int(id_part) if id_part.isdigit() else None


def _display_name_conflict_response(
    *,
    current_display_name: str,
    current_display_name_version: int,
):
    return Response(
        {
            "detail": "显示名已被其他操作更新，请刷新后重试。",
            "code": "display_name_version_conflict",
            "current_display_name": current_display_name,
            "current_display_name_version": max(1, int(current_display_name_version or 1)),
        },
        status=status.HTTP_409_CONFLICT,
    )


def _livekit_participant_name(meeting, participant_identity: str) -> str:
    try:
        participants = livekit_service.list_participants(meeting.room_name)
    except Exception:
        return ""
    for participant in participants:
        identity = (getattr(participant, "identity", "") or "").strip()
        if identity != participant_identity:
            continue
        return (getattr(participant, "name", "") or "").strip()
    return ""


def _ensure_guest_participant_record(
    meeting,
    participant_identity: str,
    *,
    fallback_display_name: str = "",
) -> MeetingGuestParticipant:
    identity = (participant_identity or "").strip()
    if not identity:
        raise ValueError("participant_identity is required")
    fallback_name = (fallback_display_name or "").strip()
    if not fallback_name:
        fallback_name = _livekit_participant_name(meeting, identity).strip()
    if not fallback_name:
        fallback_name = "Guest"
    fallback_name = fallback_name[:80]

    record, _ = MeetingGuestParticipant.objects.get_or_create(
        meeting=meeting,
        participant_identity=identity,
        defaults={
            "display_name": fallback_name,
            "display_name_version": 1,
        },
    )
    current_version = max(1, int(record.display_name_version or 1))
    update_fields: list[str] = []
    if not (record.display_name or "").strip():
        record.display_name = fallback_name
        update_fields.append("display_name")
    if record.display_name_version != current_version:
        record.display_name_version = current_version
        update_fields.append("display_name_version")
    if update_fields:
        update_fields.append("updated_at")
        record.save(update_fields=update_fields)
    return record


def _update_member_display_name_consistently(
    meeting,
    membership_id: int,
    *,
    next_display_name: str,
    expected_display_name_version: int | None = None,
) -> tuple[MeetingMember | None, MeetingMember | None]:
    normalized = (next_display_name or "").strip()[:80]
    if not normalized:
        raise ValueError("display_name is required")
    with transaction.atomic():
        membership = (
            MeetingMember.objects.select_for_update()
            .select_related("user")
            .filter(id=membership_id, meeting=meeting)
            .first()
        )
        if membership is None:
            return None, None
        current_version = max(1, int(membership.display_name_version or 1))
        if (
            expected_display_name_version is not None
            and current_version != expected_display_name_version
        ):
            membership.display_name_version = current_version
            return None, membership

        update_fields: list[str] = []
        if membership.display_name != normalized:
            membership.display_name = normalized
            membership.display_name_version = current_version + 1
            update_fields.extend(["display_name", "display_name_version"])
        elif membership.display_name_version != current_version:
            membership.display_name_version = current_version
            update_fields.append("display_name_version")
        if update_fields:
            membership.save(update_fields=update_fields)
        return membership, None


def _update_guest_display_name_consistently(
    meeting,
    participant_identity: str,
    *,
    next_display_name: str,
    expected_display_name_version: int | None = None,
) -> tuple[MeetingGuestParticipant, MeetingGuestParticipant | None]:
    identity = (participant_identity or "").strip()
    if not identity:
        raise ValueError("participant_identity is required")
    normalized = (next_display_name or "").strip()[:80]
    if not normalized:
        raise ValueError("display_name is required")

    with transaction.atomic():
        guest = (
            MeetingGuestParticipant.objects.select_for_update()
            .filter(meeting=meeting, participant_identity=identity)
            .first()
        )
        if guest is None:
            initial_name = _livekit_participant_name(meeting, identity).strip() or normalized
            guest = MeetingGuestParticipant.objects.create(
                meeting=meeting,
                participant_identity=identity,
                display_name=initial_name[:80],
                display_name_version=1,
            )

        current_version = max(1, int(guest.display_name_version or 1))
        if (
            expected_display_name_version is not None
            and current_version != expected_display_name_version
        ):
            guest.display_name_version = current_version
            return guest, guest

        update_fields: list[str] = []
        if guest.display_name != normalized:
            guest.display_name = normalized
            guest.display_name_version = current_version + 1
            update_fields.extend(["display_name", "display_name_version"])
        elif guest.display_name_version != current_version:
            guest.display_name_version = current_version
            update_fields.append("display_name_version")

        if update_fields:
            update_fields.append("updated_at")
            guest.save(update_fields=update_fields)

        return guest, None


def _normalize_track_source_name(value) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        normalized = value.strip().lower()
        if "." in normalized:
            normalized = normalized.rsplit(".", 1)[-1]
        return _TRACK_SOURCE_TOKEN_TO_NAME.get(normalized)
    try:
        numeric_value = int(value)
    except (TypeError, ValueError):
        numeric_value = None
    if numeric_value is not None:
        mapped = _TRACK_SOURCE_VALUE_TO_NAME.get(numeric_value)
        if mapped:
            return mapped

    raw_value = getattr(value, "value", None)
    if raw_value is not None and raw_value is not value:
        mapped = _normalize_track_source_name(raw_value)
        if mapped:
            return mapped

    raw_name = getattr(value, "name", None)
    if raw_name is not None:
        mapped = _normalize_track_source_name(str(raw_name))
        if mapped:
            return mapped

    normalized = str(value).strip().lower()
    if "." in normalized:
        normalized = normalized.rsplit(".", 1)[-1]
    return _TRACK_SOURCE_TOKEN_TO_NAME.get(normalized)


def _default_guest_publish_sources(meeting) -> set[str]:
    sources: set[str] = set()
    if not meeting.mute_on_entry or meeting.allow_self_unmute:
        sources.add("microphone")
    if meeting.allow_member_video:
        sources.add("camera")
    if meeting.allow_screen_share:
        sources.update({"screen_share", "screen_share_audio"})
    return sources


def _participant_publish_sources(meeting, participant_identity: str) -> set[str] | None:
    try:
        participants = livekit_service.list_participants(meeting.room_name)
    except Exception:
        return None
    for participant in participants:
        if getattr(participant, "identity", "") != participant_identity:
            continue
        permission = getattr(participant, "permission", None)
        if permission is None:
            return set()
        sources: set[str] = set()
        for source in getattr(permission, "can_publish_sources", []):
            normalized = _normalize_track_source_name(source)
            if normalized:
                sources.add(normalized)
        if sources:
            return sources
        if getattr(permission, "can_publish", False):
            return set(_TRACK_SOURCE_ORDER)
        return set()
    return None


def _participant_publish_data_allowed(meeting, participant_identity: str) -> bool | None:
    try:
        participants = livekit_service.list_participants(meeting.room_name)
    except Exception:
        return None
    for participant in participants:
        if getattr(participant, "identity", "") != participant_identity:
            continue
        permission = getattr(participant, "permission", None)
        if permission is None:
            return None
        if getattr(permission, "can_publish_data", None) is None:
            return None
        return bool(getattr(permission, "can_publish_data", False))
    return None


def _resolved_guest_publish_sources(meeting, participant_identity: str) -> set[str]:
    livekit_sources = _participant_publish_sources(meeting, participant_identity)
    if livekit_sources is not None:
        return livekit_sources
    return _default_guest_publish_sources(meeting)


def _resolved_guest_publish_data_allowed(meeting, participant_identity: str) -> bool:
    # Guest chat permission follows meeting-level switch only.
    return bool(meeting.allow_chat)


def _effective_guest_publish_sources(meeting, sources: set[str]) -> list[str]:
    filtered = set(sources)
    if not meeting.allow_member_video:
        filtered.discard("camera")
    if not meeting.allow_screen_share:
        filtered.discard("screen_share")
        filtered.discard("screen_share_audio")
    return [source for source in _TRACK_SOURCE_ORDER if source in filtered]


def _participant_metadata_map(meeting, participant_identity: str) -> dict:
    try:
        participants = livekit_service.list_participants(meeting.room_name)
    except Exception:
        return {}

    for participant in participants:
        if getattr(participant, "identity", "") != participant_identity:
            continue
        raw_metadata = (getattr(participant, "metadata", "") or "").strip()
        if not raw_metadata:
            return {}
        try:
            payload = json.loads(raw_metadata)
        except Exception:
            return {}
        if not isinstance(payload, dict):
            return {}
        return {str(key): value for key, value in payload.items()}
    return {}


def _request_participant_device_open(
    meeting,
    participant_identity: str,
    *,
    open_microphone: bool = False,
    open_camera: bool = False,
) -> None:
    if not open_microphone and not open_camera:
        return

    payload = _participant_metadata_map(meeting, participant_identity)
    if open_microphone:
        payload[_HOST_FORCE_OPEN_MIC_METADATA_KEY] = uuid4().hex
    if open_camera:
        payload[_HOST_FORCE_OPEN_VIDEO_METADATA_KEY] = uuid4().hex

    livekit_service.update_participant_metadata(
        meeting.room_name,
        participant_identity,
        metadata=json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
    )


def _list_guest_participant_identities(meeting) -> list[str]:
    try:
        participants = livekit_service.list_participants(meeting.room_name)
    except Exception:
        return []

    identities: list[str] = []
    for participant in participants:
        identity = (getattr(participant, "identity", "") or "").strip()
        if not identity:
            continue
        if _user_id_from_participant_identity(identity) is not None:
            continue
        identities.append(identity)
    return identities


def _list_registered_participant_user_ids(meeting) -> set[int] | None:
    try:
        participants = livekit_service.list_participants(meeting.room_name)
    except Exception:
        return None

    user_ids: set[int] = set()
    for participant in participants:
        identity = (getattr(participant, "identity", "") or "").strip()
        if not identity:
            continue
        user_id = _user_id_from_participant_identity(identity)
        if user_id is None:
            continue
        user_ids.add(user_id)
    return user_ids


def _sync_livekit_permissions_for_guest_participants(meeting, identities: Iterable[str] | None = None) -> None:
    targets = list(identities) if identities is not None else _list_guest_participant_identities(meeting)
    for identity in targets:
        try:
            sources = _resolved_guest_publish_sources(meeting, identity)
            effective_sources = _effective_guest_publish_sources(meeting, sources)
            can_publish_data = _resolved_guest_publish_data_allowed(meeting, identity)
            _sync_livekit_permissions_for_guest_participant(
                meeting,
                identity,
                publish_sources=effective_sources,
                can_publish_data=can_publish_data,
            )
        except Exception:
            continue


def _sync_livekit_permissions_for_guest_participant(
    meeting,
    participant_identity: str,
    *,
    publish_sources: list[str],
    can_publish_data: bool | None = None,
    force_unmute_microphone: bool = False,
    force_unmute_camera: bool = False,
) -> None:
    source_set = set(publish_sources)
    effective_can_publish_data = meeting.allow_chat if can_publish_data is None else bool(can_publish_data and meeting.allow_chat)
    livekit_service.update_participant_permissions(
        meeting.room_name,
        participant_identity,
        can_publish=bool(publish_sources),
        can_subscribe=True,
        can_publish_data=effective_can_publish_data,
        can_publish_sources=publish_sources or None,
    )

    mic_allowed = "microphone" in source_set
    if not mic_allowed:
        livekit_service.mute_participant_track_sources(
            meeting.room_name,
            participant_identity,
            track_sources=["microphone"],
            muted=True,
        )
    elif force_unmute_microphone:
        livekit_service.mute_participant_track_sources(
            meeting.room_name,
            participant_identity,
            track_sources=["microphone"],
            muted=False,
        )

    camera_allowed = "camera" in source_set
    if not camera_allowed:
        livekit_service.mute_participant_track_sources(
            meeting.room_name,
            participant_identity,
            track_sources=["camera"],
            muted=True,
        )
    elif force_unmute_camera:
        livekit_service.mute_participant_track_sources(
            meeting.room_name,
            participant_identity,
            track_sources=["camera"],
            muted=False,
        )

    if "screen_share" not in source_set and "screen_share_audio" not in source_set:
        livekit_service.mute_participant_track_sources(
            meeting.room_name,
            participant_identity,
            track_sources=["screen_share", "screen_share_audio"],
            muted=True,
        )


@api_view(["POST", "GET"])
@permission_classes([IsAuthenticated])
def meetings(request):
    user = request.user
    if request.method == "POST":
        serializer = MeetingCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        payload = serializer.validated_data
        requested_max_participants = int(payload.get("max_participants", 100))
        projected_meeting_count = _user_meeting_count(user) + 1
        projected_room_participants = max(_user_max_room_participants(user), requested_max_participants)
        billing_limit_message = _billing_limit_message_for_action(
            user,
            projected_meeting_count=projected_meeting_count,
            projected_room_participants=projected_room_participants,
        )
        if billing_limit_message:
            return Response({"detail": billing_limit_message}, status=status.HTTP_403_FORBIDDEN)

        title = (payload.get("title") or "").strip()
        if not title:
            title = f"{_fallback_display_name(user)}预定的会议"
        title = title[:120]

        room_name = f"room-{uuid4().hex[:12]}"
        livekit_service.create_room(room_name)

        meeting = Meeting.objects.create(
            title=title,
            description=payload.get("description"),
            scheduled_start=payload.get("scheduled_start"),
            meeting_recurrence=payload.get("meeting_recurrence", "once"),
            meeting_timezone=payload.get("meeting_timezone", "Asia/Shanghai"),
            duration_minutes=payload.get("duration_minutes", 30),
            meeting_password=(payload.get("meeting_password") or "").strip() or None,
            waiting_room_enabled=payload.get("waiting_room_enabled", False),
            max_participants=payload.get("max_participants", 100),
            allow_guest_link_join=payload.get("allow_guest_link_join", True),
            allow_recording=payload.get("allow_recording", True),
            allow_screen_share=payload.get("allow_screen_share", True),
            allow_chat=payload.get("allow_chat", True),
            allow_self_unmute=payload.get("allow_self_unmute", True),
            allow_member_video=payload.get("allow_member_video", True),
            mute_on_entry=payload.get("mute_on_entry", False),
            room_name=room_name,
            owner=user,
        )
        MeetingMember.objects.create(
            meeting=meeting,
            user=user,
            role=MeetingRole.HOST,
            display_name=_fallback_display_name(user),
            muted_by_host=False,
        )

        org_membership = OrganizationMember.objects.filter(user=user).first()
        if org_membership:
            MeetingOrganization.objects.get_or_create(
                meeting=meeting,
                organization=org_membership.organization,
            )
        log_audit(
            user=user,
            action="meeting.create",
            resource_type="meeting",
            resource_id=meeting.id,
            detail=f"title={meeting.title}, room={meeting.room_name}",
            ip_address=client_ip(request),
        )
        return Response(MeetingSerializer(meeting, context={"request": request}).data)

    if user.is_superuser:
        qs = Meeting.objects.all().order_by("-created_at")
    else:
        qs = (
            Meeting.objects.filter(
                Q(owner=user)
                | Q(members__user=user)
            )
            .distinct()
            .order_by("-created_at")
        )
    return Response(MeetingSerializer(qs, many=True, context={"request": request}).data)


@api_view(["GET", "PATCH", "DELETE"])
@permission_classes([IsAuthenticated])
def meeting_detail(request, meeting_id: int):
    return _meeting_endpoint_by_id(request, meeting_id, _meeting_detail_impl)


def _meeting_detail_impl(request, meeting):
    if request.method == "GET":
        return Response(MeetingSerializer(meeting, context={"request": request}).data)

    if request.method == "PATCH":
        if not _can_edit_meeting(request.user, meeting):
            return Response({"detail": "No permission to edit this meeting"}, status=status.HTTP_403_FORBIDDEN)
        serializer = MeetingUpdateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        payload = serializer.validated_data
        if "max_participants" in payload:
            quota_user = meeting.owner
            projected_room_participants = max(
                int(payload["max_participants"]),
                _user_max_room_participants(quota_user),
            )
            if int(meeting.max_participants) == _user_max_room_participants(quota_user):
                projected_room_participants = max(
                    int(payload["max_participants"]),
                    _owned_meetings(quota_user)
                    .exclude(id=meeting.id)
                    .aggregate(value=Max("max_participants"))
                    .get("value")
                    or 0,
                )
            billing_limit_message = _billing_limit_message_for_action(
                quota_user,
                projected_room_participants=projected_room_participants,
            )
            if billing_limit_message:
                return Response({"detail": billing_limit_message}, status=status.HTTP_403_FORBIDDEN)
        if "max_participants" in payload:
            member_count = MeetingMember.objects.filter(meeting=meeting).count()
            if payload["max_participants"] < member_count:
                return Response(
                    {"detail": f"max_participants cannot be less than current members ({member_count})"},
                    status=status.HTTP_400_BAD_REQUEST,
                )
        changed_keys = list(payload.keys())
        _apply_meeting_payload(meeting, payload)
        meeting.save()
        if {
            "allow_chat",
            "allow_screen_share",
            "allow_self_unmute",
            "allow_member_video",
        }.intersection(changed_keys):
            members = MeetingMember.objects.filter(meeting=meeting).select_related("user")
            _sync_livekit_permissions_for_members(meeting, members)
        log_audit(
            user=request.user,
            action="meeting.update",
            resource_type="meeting",
            resource_id=meeting.id,
            detail=f"fields={','.join(payload.keys())}",
            ip_address=client_ip(request),
        )
        return Response(MeetingSerializer(meeting, context={"request": request}).data)

    if not _can_delete_meeting(request.user, meeting):
        return Response({"detail": "No permission to delete this meeting"}, status=status.HTTP_403_FORBIDDEN)
    room_name = meeting.room_name
    _finalize_room_session_if_needed(meeting)
    meeting.delete()
    try:
        livekit_service.delete_room(room_name)
    except Exception:
        # Do not fail the API when room deletion is unavailable; DB state remains the source of truth.
        pass
    log_audit(
        user=request.user,
        action="meeting.delete",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=f"room={room_name}",
        ip_address=client_ip(request),
    )
    return Response({"ok": True})


@api_view(["GET", "PATCH", "DELETE"])
@permission_classes([IsAuthenticated])
def meeting_detail_ref(request, meeting_ref: str):
    return _meeting_endpoint(
        request,
        lookup=MeetingLookup(
            meeting_ref=meeting_ref,
            hidden_forbidden=True,
        ),
        impl=_meeting_detail_impl,
        allow_waiting_room=request.method == "GET",
    )


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_outlook_ics(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_outlook_ics_response(request, meeting)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_outlook_ics_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(
        request.user,
        meeting_ref,
        allow_waiting_room=True,
    )
    if error:
        return error
    return _meeting_outlook_ics_response(request, meeting)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def join_meeting(request):
    serializer = MeetingJoinSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    payload = serializer.validated_data

    meeting = Meeting.objects.filter(room_name=payload["room_name"]).first()

    if not meeting:
        return Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)
    if meeting.meeting_password:
        input_password = (payload.get("meeting_password") or "").strip()
        if input_password != meeting.meeting_password:
            return Response({"detail": "Meeting password is incorrect"}, status=status.HTTP_403_FORBIDDEN)

    requested_display_name = (payload.get("display_name") or "").strip()
    if requested_display_name and len(requested_display_name) > 80:
        return Response({"detail": "display_name exceeds max length 80"}, status=status.HTTP_400_BAD_REQUEST)

    if _is_blocked_member(meeting, request.user):
        return Response({"detail": _REMOVED_AND_BLOCKED_DETAIL}, status=status.HTTP_403_FORBIDDEN)

    existing_member = MeetingMember.objects.filter(meeting=meeting, user=request.user).first()
    waiting_gate_response = _waiting_room_gate_response(
        meeting,
        request.user,
        membership=existing_member,
    )
    if waiting_gate_response:
        return waiting_gate_response

    if not existing_member:
        member_count = MeetingMember.objects.filter(meeting=meeting).count()
        if member_count >= meeting.max_participants:
            return Response({"detail": "Meeting has reached max participants"}, status=status.HTTP_400_BAD_REQUEST)

    membership, created = MeetingMember.objects.get_or_create(
        meeting=meeting,
        user=request.user,
        defaults={
            "role": MeetingRole.PARTICIPANT,
            "display_name": requested_display_name or _fallback_display_name(request.user),
            "muted_by_host": meeting.mute_on_entry,
        },
    )
    if meeting.waiting_room_enabled:
        _mark_waiting_room_status(
            meeting,
            request.user,
            WaitingRoomStatus.APPROVED,
            reviewed_by=request.user if _can_bypass_waiting_room(meeting, request.user, membership) else None,
        )
    if not created and requested_display_name and requested_display_name != membership.display_name:
        membership, conflict = _update_member_display_name_consistently(
            meeting,
            membership.id,
            next_display_name=requested_display_name,
        )
        if conflict is not None:
            return _display_name_conflict_response(
                current_display_name=conflict.display_name,
                current_display_name_version=conflict.display_name_version,
            )
    log_audit(
        user=request.user,
        action="meeting.join",
        resource_type="meeting",
        resource_id=meeting.id,
        ip_address=client_ip(request),
    )
    return Response(MeetingSerializer(meeting, context={"request": request}).data)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_join_token(request, meeting_id: int):
    return _meeting_join_token(
        request,
        lookup=MeetingLookup(meeting_id=meeting_id),
    )


def _meeting_join_token(
    request,
    *,
    lookup: MeetingLookup,
    allow_waiting_room: bool = False,
):
    meeting, membership, error = _resolve_user_meeting_with_membership(
        request.user,
        lookup,
        allow_waiting_room=allow_waiting_room,
    )
    if error:
        return error
    return _meeting_join_token_impl(request, meeting, membership=membership)


def _meeting_join_token_impl(request, meeting, *, membership=None):
    requested_display_name = (request.data.get("display_name") or "").strip()
    if requested_display_name and len(requested_display_name) > 80:
        return Response({"detail": "display_name exceeds max length 80"}, status=status.HTTP_400_BAD_REQUEST)

    input_password = (request.data.get("meeting_password") or "").strip()
    if _is_blocked_member(meeting, request.user):
        return Response({"detail": _REMOVED_AND_BLOCKED_DETAIL}, status=status.HTTP_403_FORBIDDEN)

    if membership is None:
        membership = MeetingMember.objects.filter(meeting=meeting, user=request.user).first()
    waiting_gate_response = _waiting_room_gate_response(
        meeting,
        request.user,
        membership=membership,
    )
    if waiting_gate_response:
        return waiting_gate_response

    if not membership:
        if meeting.meeting_password and input_password != meeting.meeting_password:
            return Response({"detail": "Meeting password is incorrect"}, status=status.HTTP_403_FORBIDDEN)
        member_count = MeetingMember.objects.filter(meeting=meeting).count()
        if member_count >= meeting.max_participants:
            return Response({"detail": "Meeting has reached max participants"}, status=status.HTTP_400_BAD_REQUEST)
        membership = MeetingMember.objects.create(
            meeting=meeting,
            user=request.user,
            role=MeetingRole.PARTICIPANT,
            display_name=requested_display_name or _fallback_display_name(request.user),
            muted_by_host=meeting.mute_on_entry,
        )
    elif meeting.mute_on_entry and membership.role == MeetingRole.PARTICIPANT and not membership.muted_by_host:
        membership.muted_by_host = True
        membership.save(update_fields=["muted_by_host"])

    if meeting.waiting_room_enabled:
        _mark_waiting_room_status(
            meeting,
            request.user,
            WaitingRoomStatus.APPROVED,
            reviewed_by=request.user if _can_bypass_waiting_room(meeting, request.user, membership) else None,
        )

    if requested_display_name and requested_display_name != membership.display_name:
        membership, conflict = _update_member_display_name_consistently(
            meeting,
            membership.id,
            next_display_name=requested_display_name,
        )
        if conflict is not None:
            return _display_name_conflict_response(
                current_display_name=conflict.display_name,
                current_display_name_version=conflict.display_name_version,
            )
    elif not membership.display_name:
        membership, conflict = _update_member_display_name_consistently(
            meeting,
            membership.id,
            next_display_name=_fallback_display_name(request.user),
        )
        if conflict is not None:
            return _display_name_conflict_response(
                current_display_name=conflict.display_name,
                current_display_name_version=conflict.display_name_version,
            )

    quota_user = meeting.owner
    projected_active_rooms = None
    if meeting.room_session_started_at is None:
        projected_active_rooms = _user_active_room_count(quota_user) + 1
    billing_limit_message = _billing_limit_message_for_action(
        quota_user,
        projected_active_rooms=projected_active_rooms,
    )
    if billing_limit_message:
        return Response({"detail": billing_limit_message}, status=status.HTTP_403_FORBIDDEN)

    _ensure_actual_started_at(meeting)

    participant_identity = _stable_participant_identity(request.user)
    policy = _meeting_publish_policy(meeting, membership)
    can_publish = policy["can_publish"]
    can_publish_sources = policy["can_publish_sources"]
    token = livekit_service.create_participant_token(
        identity=participant_identity,
        room_name=meeting.room_name,
        name=membership.display_name,
        can_publish=can_publish,
        can_subscribe=policy["can_subscribe"],
        can_publish_data=policy["can_publish_data"],
        can_publish_sources=can_publish_sources,
        can_update_own_metadata=True,
    )
    log_audit(
        user=request.user,
        action="meeting.join_token",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=(
            f"can_publish={can_publish}, "
            f"allow_screen_share={meeting.allow_screen_share}, "
            f"allow_chat={meeting.allow_chat}"
        ),
        ip_address=client_ip(request),
    )
    meeting_ref = ensure_meeting_ref(meeting, request.user)
    return Response(
        {
            "meeting_ref": meeting_ref,
            "room_name": meeting.room_name,
            "participant_identity": participant_identity,
            "livekit_url": _meeting_livekit_url_for_client(request),
            "livekit_meet_url": settings.LIVEKIT_MEET_URL,
            "display_name": membership.display_name,
            "display_name_version": membership.display_name_version,
            "waiting_room_enabled": meeting.waiting_room_enabled,
            "max_participants": meeting.max_participants,
            "actual_started_at": meeting.actual_started_at,
            "mute_on_entry": meeting.mute_on_entry,
            "allow_guest_link_join": meeting.allow_guest_link_join,
            "allow_recording": meeting.allow_recording,
            "allow_screen_share": meeting.allow_screen_share,
            "allow_chat": meeting.allow_chat,
            "allow_self_unmute": meeting.allow_self_unmute,
            "allow_member_video": meeting.allow_member_video,
            "can_publish": can_publish,
            "token": token,
        }
    )


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_join_token_ref(request, meeting_ref: str):
    return _meeting_join_token(
        request,
        lookup=MeetingLookup(
            meeting_ref=meeting_ref,
            hidden_forbidden=True,
        ),
        allow_waiting_room=True,
    )


@api_view(["GET"])
@authentication_classes([])
@permission_classes([AllowAny])
def public_meeting_detail(request, share_code: str):
    meeting = _meeting_by_share_code(share_code)
    if not meeting:
        return Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)
    return Response(MeetingSerializer(meeting, context={"request": request}).data)


@api_view(["GET"])
@authentication_classes([])
@permission_classes([AllowAny])
def public_meeting_members(request, share_code: str):
    meeting = _meeting_by_share_code(share_code)
    if not meeting:
        return Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)
    members = MeetingMember.objects.filter(meeting=meeting).select_related("user").order_by("created_at")
    return Response(MeetingMemberSerializer(members, many=True, context={"meeting": meeting}).data)


@api_view(["GET", "POST"])
@permission_classes([AllowAny])
def public_meeting_messages(request, share_code: str):
    meeting = _meeting_by_share_code(share_code)
    if not meeting:
        return Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)
    if request.method == "GET":
        if not meeting.allow_chat:
            return Response([])
        limit = int(request.GET.get("limit", 50))
        limit = max(1, min(limit, 200))
        messages = list(
            MeetingMessage.objects.filter(meeting=meeting)
            .select_related("sender_user")
            .order_by("-created_at")[:limit]
        )
        messages.reverse()
        return Response(MeetingMessageSerializer(messages, many=True).data)

    if not request.user.is_authenticated:
        return Response(
            {"detail": "Sign in first to send messages from share link"},
            status=status.HTTP_403_FORBIDDEN,
        )
    if not has_meeting_access(request.user, meeting):
        return Response(
            {"detail": "Join meeting first before sending messages"},
            status=status.HTTP_403_FORBIDDEN,
        )
    if not meeting.allow_chat:
        return Response({"detail": "Chat is disabled for this meeting"}, status=status.HTTP_403_FORBIDDEN)
    membership = MeetingMember.objects.filter(meeting=meeting, user=request.user).first()
    if membership and not _member_can_chat(meeting, membership):
        return Response({"detail": "Your chat permission is disabled by host/cohost"}, status=status.HTTP_403_FORBIDDEN)

    serializer = MeetingMessageCreateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    content = serializer.validated_data["content"].strip()
    if not content:
        return Response({"detail": "Message content cannot be empty"}, status=status.HTTP_400_BAD_REQUEST)

    msg = MeetingMessage.objects.create(meeting=meeting, sender_user=request.user, content=content)
    log_audit(
        user=request.user,
        action="meeting.chat_send_share",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=f"message_id={msg.id}, share={share_code}",
        ip_address=client_ip(request),
    )
    return Response(MeetingMessageSerializer(msg).data)


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def public_meeting_message_recall(request, share_code: str, message_id: int):
    meeting = _meeting_by_share_code(share_code)
    if not meeting:
        return Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)
    if not has_meeting_access(request.user, meeting):
        return Response({"detail": "No permission to access this meeting"}, status=status.HTTP_403_FORBIDDEN)
    return _meeting_message_recall_impl(request, meeting, message_id, meeting.id)


@api_view(["POST"])
@permission_classes([AllowAny])
def public_meeting_join_token(request, share_code: str):
    meeting = _meeting_by_share_code(share_code)
    if not meeting:
        return Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)
    if request.user.is_authenticated:
        return _meeting_join_token_impl(request, meeting)
    if not meeting.allow_guest_link_join:
        return Response(
            {
                "detail": _GUEST_LINK_JOIN_DISABLED_DETAIL,
                "guest_link_join_status": "disabled",
                "room_name": meeting.room_name,
            },
            status=status.HTTP_403_FORBIDDEN,
        )
    if meeting.waiting_room_enabled:
        return Response(
            {
                "detail": "This meeting has waiting room enabled. Sign in first, then join via link for host approval.",
                "waiting_room_status": "login_required",
                "room_name": meeting.room_name,
            },
            status=status.HTTP_403_FORBIDDEN,
        )

    input_password = (request.data.get("meeting_password") or "").strip()
    if meeting.meeting_password and input_password != meeting.meeting_password:
        return Response({"detail": "Meeting password is incorrect"}, status=status.HTTP_403_FORBIDDEN)

    requested_display_name = (request.data.get("display_name") or "").strip()
    if len(requested_display_name) > 80:
        return Response({"detail": "display_name exceeds max length 80"}, status=status.HTTP_400_BAD_REQUEST)
    display_name = requested_display_name or f"Guest-{uuid4().hex[:4]}"

    quota_user = meeting.owner
    projected_active_rooms = None
    if meeting.room_session_started_at is None:
        projected_active_rooms = _user_active_room_count(quota_user) + 1
    billing_limit_message = _billing_limit_message_for_action(
        quota_user,
        projected_active_rooms=projected_active_rooms,
    )
    if billing_limit_message:
        return Response({"detail": billing_limit_message}, status=status.HTTP_403_FORBIDDEN)

    _ensure_actual_started_at(meeting)

    participant_identity = _guest_participant_identity(display_name)
    guest = _ensure_guest_participant_record(
        meeting,
        participant_identity,
        fallback_display_name=display_name,
    )
    display_name = guest.display_name
    default_sources = _default_guest_publish_sources(meeting)
    can_publish_sources = [source for source in _TRACK_SOURCE_ORDER if source in default_sources]
    can_publish = bool(can_publish_sources)
    token = livekit_service.create_participant_token(
        identity=participant_identity,
        room_name=meeting.room_name,
        name=display_name,
        can_publish=can_publish,
        can_subscribe=True,
        can_publish_data=meeting.allow_chat,
        can_publish_sources=can_publish_sources if can_publish_sources else None,
        can_update_own_metadata=True,
    )
    log_audit(
        action="meeting.public_join_token",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=(
            f"can_publish={can_publish}, "
            f"allow_screen_share={meeting.allow_screen_share}, "
            f"allow_chat={meeting.allow_chat}, "
            f"share={build_meeting_share_code(meeting.room_name)}"
        ),
        ip_address=client_ip(request),
    )
    return Response(
        {
            "room_name": meeting.room_name,
            "participant_identity": participant_identity,
            "livekit_url": _meeting_livekit_url_for_client(request),
            "livekit_meet_url": settings.LIVEKIT_MEET_URL,
            "display_name": display_name,
            "display_name_version": guest.display_name_version,
            "waiting_room_enabled": meeting.waiting_room_enabled,
            "max_participants": meeting.max_participants,
            "actual_started_at": meeting.actual_started_at,
            "mute_on_entry": meeting.mute_on_entry,
            "allow_guest_link_join": meeting.allow_guest_link_join,
            "allow_recording": meeting.allow_recording,
            "allow_screen_share": meeting.allow_screen_share,
            "allow_chat": meeting.allow_chat,
            "allow_self_unmute": meeting.allow_self_unmute,
            "allow_member_video": meeting.allow_member_video,
            "can_publish": can_publish,
            "token": token,
        }
    )


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def my_meeting_display_name(request, meeting_id: int):
    return _meeting_endpoint_by_id(request, meeting_id, _my_meeting_display_name_impl)


def _my_meeting_display_name_impl(request, meeting):
    serializer = MeetingDisplayNameUpdateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    display_name = serializer.validated_data["display_name"].strip()
    expected_display_name_version = serializer.validated_data.get(
        "expected_display_name_version"
    )

    membership = MeetingMember.objects.filter(meeting=meeting, user=request.user).first()
    if not membership:
        member_count = MeetingMember.objects.filter(meeting=meeting).count()
        if member_count >= meeting.max_participants:
            return Response({"detail": "Meeting has reached max participants"}, status=status.HTTP_400_BAD_REQUEST)
        membership = MeetingMember.objects.create(
            meeting=meeting,
            user=request.user,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=meeting.mute_on_entry,
        )

    membership, conflict = _update_member_display_name_consistently(
        meeting,
        membership.id,
        next_display_name=display_name,
        expected_display_name_version=expected_display_name_version,
    )
    if conflict is not None:
        return _display_name_conflict_response(
            current_display_name=conflict.display_name,
            current_display_name_version=conflict.display_name_version,
        )
    if membership is None:
        return Response({"detail": "Member not found"}, status=status.HTTP_404_NOT_FOUND)
    try:
        identity = _stable_participant_identity(request.user)
        livekit_service.update_participant_name(
            meeting.room_name,
            identity,
            name=display_name,
        )
    except Exception:
        pass
    log_audit(
        user=request.user,
        action="meeting.display_name_update",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=f"display_name={display_name}",
        ip_address=client_ip(request),
    )
    return Response(
        {
            "display_name": membership.display_name,
            "display_name_version": membership.display_name_version,
        }
    )


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def my_meeting_display_name_ref(request, meeting_ref: str):
    return _meeting_endpoint(
        request,
        lookup=MeetingLookup(
            meeting_ref=meeting_ref,
            hidden_forbidden=True,
        ),
        impl=_my_meeting_display_name_impl,
    )


@api_view(["GET", "POST"])
@permission_classes([IsAuthenticated])
def meeting_members(request, meeting_id: int):
    return _meeting_endpoint_by_id(request, meeting_id, _meeting_members_impl)


def _meeting_members_impl(request, meeting):
    if request.method == "GET":
        members = MeetingMember.objects.filter(meeting=meeting).select_related("user").order_by("created_at")
        return Response(MeetingMemberSerializer(members, many=True, context={"meeting": meeting}).data)

    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can add members"}, status=status.HTTP_403_FORBIDDEN)

    serializer = MeetingMemberAddSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    target = User.objects.filter(username=serializer.validated_data["username"]).first()
    if not target:
        return Response({"detail": "Target user not found"}, status=status.HTTP_404_NOT_FOUND)

    MeetingBlockedMember.objects.filter(meeting=meeting, user=target).delete()
    member, _ = MeetingMember.objects.get_or_create(
        meeting=meeting,
        user=target,
        defaults={
            "role": serializer.validated_data["role"],
            "display_name": _fallback_display_name(target),
        },
    )
    if member.role != serializer.validated_data["role"]:
        member.role = serializer.validated_data["role"]
        member.save(update_fields=["role"])
    if not member.display_name:
        member, conflict = _update_member_display_name_consistently(
            meeting,
            member.id,
            next_display_name=_fallback_display_name(target),
        )
        if conflict is not None:
            return _display_name_conflict_response(
                current_display_name=conflict.display_name,
                current_display_name_version=conflict.display_name_version,
            )
        if member is None:
            return Response({"detail": "Member not found"}, status=status.HTTP_404_NOT_FOUND)
    log_audit(
        user=request.user,
        action="meeting.member_add",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=f"target={target.username}, role={member.role}",
        ip_address=client_ip(request),
    )
    return Response(MeetingMemberSerializer(member, context={"meeting": meeting}).data)


@api_view(["GET", "POST"])
@permission_classes([IsAuthenticated])
def meeting_members_ref(request, meeting_ref: str):
    return _meeting_endpoint(
        request,
        lookup=MeetingLookup(
            meeting_ref=meeting_ref,
            hidden_forbidden=True,
        ),
        impl=_meeting_members_impl,
    )


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_raise_hand(request, meeting_id: int):
    return _meeting_endpoint_by_id(request, meeting_id, _meeting_raise_hand_impl)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_raise_hand_ref(request, meeting_ref: str):
    return _meeting_endpoint(
        request,
        lookup=MeetingLookup(
            meeting_ref=meeting_ref,
            hidden_forbidden=True,
        ),
        impl=_meeting_raise_hand_impl,
    )


def _meeting_raise_hand_impl(request, meeting):
    membership = MeetingMember.objects.filter(meeting=meeting, user=request.user).select_related("user").first()
    if not membership:
        return Response({"detail": "Join meeting first before raising hand"}, status=status.HTTP_403_FORBIDDEN)
    if _is_moderator_role(membership.role):
        return Response({"detail": "Host/cohost does not need raise hand"}, status=status.HTTP_400_BAD_REQUEST)

    serializer = MeetingRaiseHandSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    request_type = serializer.validated_data["request"]

    update_fields: list[str] = []
    if request_type == "mic":
        if _member_can_self_unmute(meeting, membership):
            return Response(
                {"detail": "Microphone is already allowed for this member"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if not membership.mic_request_pending:
            membership.mic_request_pending = True
            update_fields.append("mic_request_pending")
    else:
        if _member_can_video(meeting, membership):
            return Response(
                {"detail": "Video is already allowed for this member"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if not membership.video_request_pending:
            membership.video_request_pending = True
            update_fields.append("video_request_pending")

    if update_fields:
        membership.save(update_fields=update_fields)

    log_audit(
        user=request.user,
        action="meeting.raise_hand",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=f"request={request_type}",
        ip_address=client_ip(request),
    )
    return Response(MeetingMemberSerializer(membership, context={"meeting": meeting}).data)


@api_view(["GET", "POST"])
@permission_classes([IsAuthenticated])
def meeting_messages(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_messages_impl(request, meeting, meeting_id)


def _meeting_messages_impl(request, meeting, resource_id_for_log: int):
    if request.method == "GET":
        if not meeting.allow_chat:
            return Response([])
        limit = int(request.GET.get("limit", 50))
        limit = max(1, min(limit, 200))
        messages = list(
            MeetingMessage.objects.filter(meeting=meeting)
            .select_related("sender_user")
            .order_by("-created_at")[:limit]
        )
        messages.reverse()
        return Response(MeetingMessageSerializer(messages, many=True).data)

    if not meeting.allow_chat:
        return Response({"detail": "Chat is disabled for this meeting"}, status=status.HTTP_403_FORBIDDEN)
    membership = MeetingMember.objects.filter(meeting=meeting, user=request.user).first()
    if membership and not _member_can_chat(meeting, membership):
        return Response({"detail": "Your chat permission is disabled by host/cohost"}, status=status.HTTP_403_FORBIDDEN)
    serializer = MeetingMessageCreateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    content = serializer.validated_data["content"].strip()
    if not content:
        return Response({"detail": "Message content cannot be empty"}, status=status.HTTP_400_BAD_REQUEST)
    msg = MeetingMessage.objects.create(meeting=meeting, sender_user=request.user, content=content)
    log_audit(
        user=request.user,
        action="meeting.chat_send",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"message_id={msg.id}",
        ip_address=client_ip(request),
    )
    return Response(MeetingMessageSerializer(msg).data)


def _can_recall_message(actor, meeting, message) -> bool:
    role = _meeting_role_for_user(meeting, actor)
    if _is_moderator_role(role):
        return True
    if message.sender_user_id != actor.id:
        return False
    return message.created_at >= timezone.now() - _MESSAGE_RECALL_WINDOW


def _meeting_message_recall_impl(request, meeting, message_id: int, resource_id_for_log: int):
    message = MeetingMessage.objects.filter(meeting=meeting, id=message_id).first()
    if not message:
        return Response({"detail": "Message not found"}, status=status.HTTP_404_NOT_FOUND)

    if not _can_recall_message(request.user, meeting, message):
        return Response(
            {
                "detail": (
                    "Only host/cohost can recall any message. "
                    "Members can only recall their own messages within 3 minutes."
                )
            },
            status=status.HTTP_403_FORBIDDEN,
        )

    sender_user_id = message.sender_user_id
    message.delete()
    log_audit(
        user=request.user,
        action="meeting.chat_recall",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"message_id={message_id}, sender_user_id={sender_user_id}",
        ip_address=client_ip(request),
    )
    return Response({"ok": True, "message_id": message_id})


@api_view(["GET", "POST"])
@permission_classes([IsAuthenticated])
def meeting_messages_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_messages_impl(request, meeting, meeting.id)


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def meeting_message_recall(request, meeting_id: int, message_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_message_recall_impl(request, meeting, message_id, meeting_id)


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def meeting_message_recall_ref(request, meeting_ref: str, message_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_message_recall_impl(request, meeting, message_id, meeting.id)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def my_orgs(request):
    user = request.user
    if user.is_superuser:
        orgs = Organization.objects.all().order_by("-created_at")
    else:
        org_ids = OrganizationMember.objects.filter(user=user).values_list("organization_id", flat=True)
        orgs = Organization.objects.filter(id__in=org_ids).order_by("-created_at")
    return Response(OrganizationSerializer(orgs, many=True).data)


def _org_member_or_403(user, org_id):
    if user.is_superuser:
        return OrganizationMember(is_org_admin=True)
    member = OrganizationMember.objects.filter(organization_id=org_id, user=user).first()
    if not member:
        return None
    return member


@api_view(["GET", "POST"])
@permission_classes([IsAuthenticated])
def org_members(request, org_id: int):
    membership = _org_member_or_403(request.user, org_id)
    if not membership:
        return Response({"detail": "No organization permission"}, status=status.HTTP_403_FORBIDDEN)

    if request.method == "GET":
        members = (
            OrganizationMember.objects.filter(organization_id=org_id)
            .select_related("user")
            .order_by("created_at")
        )
        return Response(OrganizationMemberSerializer(members, many=True).data)

    if not request.user.is_superuser and not membership.is_org_admin:
        return Response({"detail": "Only org admin can add member"}, status=status.HTTP_403_FORBIDDEN)
    serializer = OrganizationMemberAddSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    target = User.objects.filter(username=serializer.validated_data["username"]).first()
    if not target:
        return Response({"detail": "User not found"}, status=status.HTTP_404_NOT_FOUND)

    member, _ = OrganizationMember.objects.get_or_create(
        organization_id=org_id,
        user=target,
        defaults={"is_org_admin": serializer.validated_data["is_org_admin"]},
    )
    if member.is_org_admin != serializer.validated_data["is_org_admin"]:
        member.is_org_admin = serializer.validated_data["is_org_admin"]
        member.save(update_fields=["is_org_admin"])
    log_audit(
        user=request.user,
        action="org.member_add",
        resource_type="organization",
        resource_id=org_id,
        detail=f"target={target.username}, is_org_admin={member.is_org_admin}",
        ip_address=client_ip(request),
    )
    return Response(OrganizationMemberSerializer(member).data)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def audit_logs(request):
    meeting_id = request.GET.get("meeting_id")
    limit = int(request.GET.get("limit", 100))
    limit = max(1, min(limit, 500))

    query = AuditLog.objects.all().order_by("-created_at")
    if meeting_id:
        meeting = Meeting.objects.filter(id=meeting_id).first()
        if not meeting:
            return Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)
        member = meeting_membership(meeting.id, request.user.id)
        if not request.user.is_superuser and not member:
            return Response({"detail": "No permission to view meeting logs"}, status=status.HTTP_403_FORBIDDEN)
        if not request.user.is_superuser and member.role not in {MeetingRole.HOST, MeetingRole.COHOST}:
            return Response({"detail": "Only host/cohost can view meeting logs"}, status=status.HTTP_403_FORBIDDEN)
        query = query.filter(resource_type="meeting", resource_id=str(meeting_id))
    else:
        if not request.user.is_superuser:
            return Response({"detail": "Admin only for global logs"}, status=status.HTTP_403_FORBIDDEN)

    rows = query[:limit]
    return Response(AuditLogSerializer(rows, many=True).data)
