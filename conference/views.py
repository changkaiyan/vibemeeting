import base64
import gzip
import json
import io
import logging
import math
import os
import re
import threading
import time
import csv
import wave
from array import array
from datetime import timedelta, timezone as dt_timezone
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen
from typing import Iterable
from uuid import uuid4

from django.conf import settings
from django.contrib.auth import authenticate, login as auth_login, logout as auth_logout
from django.contrib.auth import views as auth_views
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

from conference.forms import MeetingAuthenticationForm, MeetingRegisterForm
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
    RealtimeBotProvider,
    RecordingStorageConfig,
    SystemAuthConfig,
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
    MeetingRealtimeBotConnectivityTestSerializer,
    MeetingRealtimeBotAudioIngressSerializer,
    MeetingRealtimeBotControlSerializer,
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
    SystemAuthConfigUpdateSerializer,
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
_TECHCLOUD_OAUTH_STATE_KEY = "techcloud_oauth_state"
_TECHCLOUD_OAUTH_NEXT_KEY = "techcloud_oauth_next"
_TECHCLOUD_AUTHENTICATED_SESSION_KEY = "techcloud_oauth_authenticated"


def _setting_int(name: str, default: int) -> int:
    raw = getattr(settings, name, default)
    try:
        return int(raw)
    except (TypeError, ValueError):
        return int(default)


def _setting_float(name: str, default: float) -> float:
    raw = getattr(settings, name, default)
    try:
        return float(raw)
    except (TypeError, ValueError):
        return float(default)


_REALTIME_BOT_SYSTEM_USERNAME = "__meeting_realtime_bot__"
_REALTIME_BOT_SYSTEM_EMAIL = "meeting-realtime-bot@local.invalid"
_REALTIME_BOT_DEFAULT_BASE_URL = (
    str(getattr(settings, "REALTIME_BOT_DEFAULT_BASE_URL", "https://api.openai.com") or "").strip()
    or "https://api.openai.com"
)
_REALTIME_BOT_DEFAULT_MODEL = (
    str(getattr(settings, "REALTIME_BOT_DEFAULT_MODEL", "gpt-realtime") or "").strip()
    or "gpt-realtime"
)
_REALTIME_BOT_DEFAULT_VOLC_MODEL = (
    str(getattr(settings, "REALTIME_BOT_DEFAULT_VOLC_MODEL", "2.2.0.0") or "").strip()
    or "2.2.0.0"
)
_REALTIME_BOT_DEFAULT_VOICE = (
    str(getattr(settings, "REALTIME_BOT_DEFAULT_VOICE", "marin") or "").strip()
    or "marin"
)
_REALTIME_BOT_DEFAULT_PROVIDER = (
    RealtimeBotProvider.VOLCENGINE
    if str(getattr(settings, "REALTIME_BOT_DEFAULT_PROVIDER", RealtimeBotProvider.OPENAI)).strip().lower()
    == RealtimeBotProvider.VOLCENGINE
    else RealtimeBotProvider.OPENAI
)
_REALTIME_BOT_DEFAULT_API_KEY = str(getattr(settings, "REALTIME_BOT_DEFAULT_API_KEY", "") or "").strip()
_REALTIME_BOT_DEFAULT_VOLC_APP_ID = str(getattr(settings, "REALTIME_BOT_DEFAULT_VOLC_APP_ID", "") or "").strip()
_REALTIME_BOT_DEFAULT_VOLC_WS_URL = (
    str(
        getattr(
            settings,
            "REALTIME_BOT_DEFAULT_VOLC_WS_URL",
            "wss://openspeech.bytedance.com/api/v3/realtime/dialogue",
        )
        or ""
    ).strip()
    or "wss://openspeech.bytedance.com/api/v3/realtime/dialogue"
)
_REALTIME_BOT_DEFAULT_VOLC_RESOURCE_ID = (
    str(getattr(settings, "REALTIME_BOT_DEFAULT_VOLC_RESOURCE_ID", "volc.speech.dialog") or "").strip()
    or "volc.speech.dialog"
)
_REALTIME_BOT_DEFAULT_VOLC_APP_KEY = (
    str(getattr(settings, "REALTIME_BOT_DEFAULT_VOLC_APP_KEY", "PlgvMymc7f3tQnJ6") or "").strip()
    or "PlgvMymc7f3tQnJ6"
)
_REALTIME_BOT_DEFAULT_VOLC_ACCESS_KEY = str(getattr(settings, "REALTIME_BOT_DEFAULT_VOLC_ACCESS_KEY", "") or "").strip()
_REALTIME_BOT_DEFAULT_VOLC_UID = str(getattr(settings, "REALTIME_BOT_DEFAULT_VOLC_UID", "") or "").strip()
_REALTIME_BOT_DEFAULT_VOLC_O_SPEAKER = (
    str(getattr(settings, "REALTIME_BOT_DEFAULT_VOLC_O_SPEAKER", "zh_female_vv_jupiter_bigtts") or "").strip()
    or "zh_female_vv_jupiter_bigtts"
)
_REALTIME_BOT_DEFAULT_VOLC_SC_SPEAKER = (
    str(getattr(settings, "REALTIME_BOT_DEFAULT_VOLC_SC_SPEAKER", "") or "").strip()
)
_REALTIME_BOT_DEFAULT_DISPLAY_NAME = (
    str(getattr(settings, "REALTIME_BOT_DEFAULT_DISPLAY_NAME", "实时语音助手") or "").strip()
    or "实时语音助手"
)
_REALTIME_BOT_DEFAULT_VOLC_AUDIO_INPUT_MODE = (
    str(getattr(settings, "REALTIME_BOT_VOLC_AUDIO_INPUT_MODE", "push_to_talk") or "").strip().lower()
)
if _REALTIME_BOT_DEFAULT_VOLC_AUDIO_INPUT_MODE not in {
    "audio_file",
    "push_to_talk",
    "keep_alive",
    "mic_silence",
}:
    _REALTIME_BOT_DEFAULT_VOLC_AUDIO_INPUT_MODE = "audio_file"
_REALTIME_BOT_VOLC_JSON_COMPRESSION_MODE = (
    str(getattr(settings, "REALTIME_BOT_VOLC_JSON_COMPRESSION", "none") or "").strip().lower()
)
if _REALTIME_BOT_VOLC_JSON_COMPRESSION_MODE not in {"none", "gzip"}:
    _REALTIME_BOT_VOLC_JSON_COMPRESSION_MODE = "none"
_REALTIME_BOT_VOLC_AUDIO_CHUNK_BYTES = max(320, _setting_int("REALTIME_BOT_VOLC_AUDIO_CHUNK_BYTES", 640))
_REALTIME_BOT_VOLC_AUDIO_CHUNK_SLEEP_SECONDS = max(
    0.0,
    _setting_float("REALTIME_BOT_VOLC_AUDIO_CHUNK_INTERVAL_MS", 20.0) / 1000.0,
)
_REALTIME_BOT_VOLC_DEBUG_EVENTS = bool(getattr(settings, "REALTIME_BOT_VOLC_DEBUG_EVENTS", False))
_REALTIME_BOT_VOLC_DEBUG_EVENTS_MAX_PAYLOAD_CHARS = max(
    200,
    _setting_int("REALTIME_BOT_VOLC_DEBUG_EVENTS_MAX_PAYLOAD_CHARS", 2000),
)
_REALTIME_BOT_WS_CONNECT_TIMEOUT_SECONDS = max(
    3,
    _setting_int("REALTIME_BOT_WS_CONNECT_TIMEOUT_SECONDS", 10),
)
_REALTIME_BOT_RESPONSE_TIMEOUT_SECONDS = max(
    5,
    _setting_int("REALTIME_BOT_RESPONSE_TIMEOUT_SECONDS", 20),
)
_REALTIME_BOT_OUTPUT_LEADING_SILENCE_MS = max(
    0,
    min(300, _setting_int("REALTIME_BOT_OUTPUT_LEADING_SILENCE_MS", 60)),
)
_VOLCENGINE_EVENT_LOGGER = logging.getLogger("conference.volcengine.realtime")

_VOLCENGINE_PROTOCOL_VERSION = 0b0001
_VOLCENGINE_CLIENT_FULL_REQUEST = 0b0001
_VOLCENGINE_CLIENT_AUDIO_ONLY_REQUEST = 0b0010
_VOLCENGINE_SERVER_FULL_RESPONSE = 0b1001
_VOLCENGINE_SERVER_ACK = 0b1011
_VOLCENGINE_SERVER_ERROR_RESPONSE = 0b1111
_VOLCENGINE_SEQUENCE_FLAGS = 0b0011
_VOLCENGINE_MSG_WITH_EVENT = 0b0100
_VOLCENGINE_SERIALIZATION_NONE = 0b0000
_VOLCENGINE_SERIALIZATION_JSON = 0b0001
_VOLCENGINE_COMPRESSION_NONE = 0b0000
_VOLCENGINE_COMPRESSION_GZIP = 0b0001
_VOLCENGINE_EVENT_START_CONNECTION = 1
_VOLCENGINE_EVENT_FINISH_CONNECTION = 2
_VOLCENGINE_EVENT_START_SESSION = 100
_VOLCENGINE_EVENT_FINISH_SESSION = 102
_VOLCENGINE_EVENT_AUDIO_REQUEST = 200
_VOLCENGINE_EVENT_END_ASR = 400
_VOLCENGINE_EVENT_CHAT_TEXT_QUERY_LEGACY = 300
_VOLCENGINE_EVENT_CHAT_TEXT_QUERY = 501
_VOLCENGINE_EVENT_CLIENT_INTERRUPT = 515
_VOLCENGINE_EVENT_ASR_INFO = 450
_VOLCENGINE_EVENT_ASR_RESPONSE = 451
_VOLCENGINE_EVENT_TEXT_DELTA = 550
_VOLCENGINE_EVENT_TEXT_DONE = 559
_VOLCENGINE_EVENT_TTS_AUDIO = 352
_VOLCENGINE_EVENT_TTS_DONE = 359
_VOLCENGINE_EVENT_DIALOG_DONE = 459
_VOLCENGINE_EVENT_ASR_DONE = 459
_VOLCENGINE_EVENT_CONNECTION_STARTED = 50
_VOLCENGINE_EVENT_CONNECTION_FAILED = 51
_VOLCENGINE_EVENT_SESSION_STARTED = 150
_VOLCENGINE_EVENT_SESSION_FAILED = 153
_VOLCENGINE_EVENT_DIALOG_COMMON_ERROR = 599
_VOLCENGINE_MAX_SESSION_ID_BYTES = 512
_VOLCENGINE_ALLOWED_MODELS = {"1.2.1.1", "2.2.0.0"}
_VOLCENGINE_MODEL_O2 = "1.2.1.1"
_VOLCENGINE_MODEL_SC2 = "2.2.0.0"
_VOLCENGINE_O2_SPEAKERS = {
    "zh_female_vv_jupiter_bigtts",
    "zh_female_xiaohe_jupiter_bigtts",
    "zh_male_yunzhou_jupiter_bigtts",
    "zh_male_xiaotian_jupiter_bigtts",
}
_VOLCENGINE_SC2_SPEAKERS = {
    "saturn_zh_female_aojiaonvyou_tob",
    "saturn_zh_female_bingjiaojiejie_tob",
    "saturn_zh_female_chengshujiejie_tob",
    "saturn_zh_female_keainvsheng_tob",
    "saturn_zh_female_nuanxinxuejie_tob",
    "saturn_zh_female_tiexinnvyou_tob",
    "saturn_zh_female_wenrouwenya_tob",
    "saturn_zh_female_wumeiyujie_tob",
    "saturn_zh_female_xingganyujie_tob",
    "saturn_zh_male_aiqilingren_tob",
    "saturn_zh_male_aojiaogongzi_tob",
    "saturn_zh_male_aojiaojingying_tob",
    "saturn_zh_male_aomanshaoye_tob",
    "saturn_zh_male_badaoshaoye_tob",
    "saturn_zh_male_bingjiaobailian_tob",
    "saturn_zh_male_bujiqingnian_tob",
    "saturn_zh_male_chengshuzongcai_tob",
    "saturn_zh_male_cixingnansang_tob",
    "saturn_zh_male_dongbeilaotie_tob",
    "saturn_zh_male_guangxibaobiao_tob",
    "saturn_zh_male_jizhiqingnian_tob",
    "saturn_zh_male_junlangnanyou_tob",
    "saturn_zh_male_lengdanxueba_tob",
    "saturn_zh_male_posuijsj_tob",
    "saturn_zh_male_shenmidashu_tob",
    "saturn_zh_male_tiancaixueba_tob",
    "saturn_zh_male_wenrouxuezhang_tob",
    "saturn_zh_male_yangguangqingnian_tob",
    "saturn_zh_male_yujieboss_tob",
    "saturn_zh_male_yuanqixuedi_tob",
}


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


def _safe_next_path(raw_target: str) -> str:
    target = (raw_target or "").strip()
    if not target or not target.startswith("/"):
        return ""
    if target.startswith("//"):
        return ""
    return target


def _ensure_default_workspace_for_user(user: User, *, seed: str | None = None) -> None:
    if OrganizationMember.objects.filter(user=user, is_org_admin=True).exists():
        return

    normalized_seed = re.sub(r"[^0-9A-Za-z._-]+", "-", (seed or user.username or "user").strip()).strip("-_.")
    if not normalized_seed:
        normalized_seed = f"user-{user.id}"
    base_org_name = f"{normalized_seed[:88]}-workspace"
    if len(base_org_name) > 100:
        base_org_name = base_org_name[:100]

    org_name = base_org_name
    suffix = 1
    while Organization.objects.filter(name=org_name).exists():
        suffix += 1
        suffix_part = f"-{suffix}"
        org_name = f"{base_org_name[: max(1, 100 - len(suffix_part))]}{suffix_part}"
    org = Organization.objects.create(name=org_name, owner_user=user)
    OrganizationMember.objects.create(organization=org, user=user, is_org_admin=True)


def _techcloud_oauth_configured() -> bool:
    client_id = (getattr(settings, "TECHCLOUD_OAUTH_CLIENT_ID", "") or "").strip()
    client_secret = (getattr(settings, "TECHCLOUD_OAUTH_CLIENT_SECRET", "") or "").strip()
    redirect_uri = (getattr(settings, "TECHCLOUD_OAUTH_REDIRECT_URI", "") or "").strip()
    authorize_url = (getattr(settings, "TECHCLOUD_OAUTH_AUTHORIZE_URL", "") or "").strip()
    token_url = (getattr(settings, "TECHCLOUD_OAUTH_TOKEN_URL", "") or "").strip()
    return bool(client_id and client_secret and redirect_uri and authorize_url and token_url)


def _system_auth_config() -> SystemAuthConfig:
    config = SystemAuthConfig.objects.order_by("id").first()
    if config:
        return config
    return SystemAuthConfig.objects.create()


def _system_auth_options_payload(*, config: SystemAuthConfig | None = None) -> dict:
    config = config or _system_auth_config()
    techcloud_configured = _techcloud_oauth_configured()
    return {
        "allow_techcloud_oauth_login": bool(config.allow_techcloud_oauth_login),
        "allow_local_register": bool(config.allow_local_register),
        "allow_local_login": bool(config.allow_local_login),
        "techcloud_oauth_configured": bool(techcloud_configured),
        "effective_techcloud_oauth_login": bool(config.allow_techcloud_oauth_login and techcloud_configured),
        "updated_by_username": config.updated_by.username if config.updated_by_id else "",
        "updated_at": config.updated_at,
    }


def _effective_techcloud_oauth_enabled(*, options: dict | None = None) -> bool:
    options = options or _system_auth_options_payload()
    return bool(options.get("effective_techcloud_oauth_login"))


def _local_register_enabled(*, options: dict | None = None) -> bool:
    options = options or _system_auth_options_payload()
    return bool(options.get("allow_local_register"))


def _local_login_enabled(*, options: dict | None = None) -> bool:
    options = options or _system_auth_options_payload()
    return bool(options.get("allow_local_login"))


class ControlledLoginView(auth_views.LoginView):
    template_name = "registration/login.html"
    authentication_form = MeetingAuthenticationForm
    redirect_authenticated_user = True

    def _auth_context(self) -> dict:
        options = _system_auth_options_payload()
        return {
            "techcloud_oauth_enabled": _effective_techcloud_oauth_enabled(options=options),
            "local_register_enabled": _local_register_enabled(options=options),
            "local_login_enabled": _local_login_enabled(options=options),
            "techcloud_oauth_configured": bool(options.get("techcloud_oauth_configured")),
        }

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context.update(self._auth_context())
        return context

    def post(self, request, *args, **kwargs):
        options = _system_auth_options_payload()
        if not _local_login_enabled(options=options):
            form = self.get_form()
            form.add_error(None, "管理员已关闭用户名密码登录")
            context = self.get_context_data(form=form)
            context.update(self._auth_context())
            return self.render_to_response(context)
        return super().post(request, *args, **kwargs)

    def form_valid(self, form):
        response = super().form_valid(form)
        self.request.session.pop(_TECHCLOUD_AUTHENTICATED_SESSION_KEY, None)
        return response


def _techcloud_authorize_url(state: str) -> str:
    params = {
        "response_type": "code",
        "redirect_uri": settings.TECHCLOUD_OAUTH_REDIRECT_URI,
        "client_id": settings.TECHCLOUD_OAUTH_CLIENT_ID,
        "theme": settings.TECHCLOUD_OAUTH_THEME,
        "state": state,
    }
    scope = (getattr(settings, "TECHCLOUD_OAUTH_SCOPE", "") or "").strip()
    if scope:
        params["scope"] = scope
    return f"{settings.TECHCLOUD_OAUTH_AUTHORIZE_URL}?{urlencode(params)}"


def _techcloud_login_error_redirect(message: str):
    return redirect(f"/accounts/login?{urlencode({'oauth_error': message})}")


def _techcloud_logout_url(request, *, next_path: str = "/") -> str:
    logout_url = (
        getattr(settings, "TECHCLOUD_OAUTH_LOGOUT_URL", "")
        or "https://passport.escience.cn/logout"
    ).strip()
    if not logout_url:
        return ""
    redirect_param = (
        getattr(settings, "TECHCLOUD_OAUTH_LOGOUT_REDIRECT_PARAM", "")
        or "WebServerURL"
    ).strip() or "WebServerURL"
    parsed = urlsplit(logout_url)
    query_items = parse_qsl(parsed.query, keep_blank_values=True)
    if not any(key == redirect_param for key, _ in query_items):
        query_items.append((redirect_param, request.build_absolute_uri(next_path)))
    return urlunsplit(
        (
            parsed.scheme,
            parsed.netloc,
            parsed.path,
            urlencode(query_items),
            parsed.fragment,
        )
    )


def _techcloud_exchange_code_for_token(code: str) -> dict:
    payload = urlencode(
        {
            "client_id": settings.TECHCLOUD_OAUTH_CLIENT_ID,
            "client_secret": settings.TECHCLOUD_OAUTH_CLIENT_SECRET,
            "grant_type": "authorization_code",
            "redirect_uri": settings.TECHCLOUD_OAUTH_REDIRECT_URI,
            "code": code,
        }
    ).encode("utf-8")
    request = Request(
        settings.TECHCLOUD_OAUTH_TOKEN_URL,
        data=payload,
        method="POST",
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
    )

    raw_response = ""
    try:
        with urlopen(request, timeout=10) as response:
            raw_response = response.read().decode("utf-8", errors="replace")
    except HTTPError as exc:
        raw_response = exc.read().decode("utf-8", errors="replace")
        message = "科技云登录失败，请稍后重试"
        if raw_response:
            try:
                error_payload = json.loads(raw_response)
            except json.JSONDecodeError:
                error_payload = {}
            description = (error_payload.get("error_description") or error_payload.get("error") or "").strip()
            if description:
                message = f"科技云登录失败：{description}"
        raise ValueError(message) from exc
    except URLError as exc:
        raise ValueError("无法连接科技云通行证服务") from exc

    try:
        token_payload = json.loads(raw_response)
    except json.JSONDecodeError as exc:
        raise ValueError("科技云通行证返回了无效响应") from exc

    error_code = (token_payload.get("error") or "").strip()
    if error_code:
        description = (token_payload.get("error_description") or error_code).strip()
        raise ValueError(f"科技云登录失败：{description}")
    return token_payload


def _techcloud_user_info_from_token_payload(token_payload: dict) -> dict:
    user_info = token_payload.get("userInfo")
    if user_info is None:
        user_info = token_payload.get("userinfo")
    if isinstance(user_info, str):
        try:
            user_info = json.loads(user_info)
        except json.JSONDecodeError as exc:
            raise ValueError("科技云用户信息解析失败") from exc
    if not isinstance(user_info, dict):
        raise ValueError("科技云返回了不完整的用户信息")
    return user_info


def _normalized_email_candidate(value: str) -> str:
    candidate = str(value or "").strip().lower()
    if "@" not in candidate or len(candidate) > 254:
        return ""
    return candidate


def _normalized_techcloud_username(raw: str) -> str:
    normalized = re.sub(r"[^0-9A-Za-z._-]+", "_", str(raw or "").strip().lower()).strip("._-")
    if not normalized:
        normalized = uuid4().hex[:24]
    return normalized[:150]


def _upsert_techcloud_user(user_info: dict) -> tuple[User, bool]:
    umt_id = (str(user_info.get("umtId") or "")).strip()
    cstnet_id = _normalized_email_candidate(user_info.get("cstnetId"))
    security_email = _normalized_email_candidate(user_info.get("securityEmail"))
    preferred_email = cstnet_id or security_email
    truename = (str(user_info.get("truename") or "")).strip()

    if umt_id:
        username = _normalized_techcloud_username(f"escience_{umt_id}")
    elif preferred_email:
        username = _normalized_techcloud_username(f"escience_{preferred_email}")
    else:
        username = _normalized_techcloud_username("escience_user")

    user = User.objects.filter(username=username).first()
    if user is None and preferred_email:
        user = User.objects.filter(email__iexact=preferred_email).first()

    created = False
    if user is None:
        user = User.objects.create_user(
            username=username,
            email=preferred_email,
            password=None,
        )
        created = True

    update_fields: list[str] = []
    if preferred_email and user.email.lower() != preferred_email:
        user.email = preferred_email
        update_fields.append("email")
    if truename and user.first_name != truename:
        user.first_name = truename[:150]
        update_fields.append("first_name")
    if update_fields:
        user.save(update_fields=update_fields)

    profile = _profile_for_user(user)
    if truename:
        display_name = truename[:80]
        if not profile.default_display_name or profile.default_display_name == user.username:
            profile.default_display_name = display_name
            profile.save(update_fields=["default_display_name", "updated_at"])
    _billing_profile_for_user(user)
    _ensure_default_workspace_for_user(user, seed=preferred_email or truename or user.username)
    return user, created


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
    js_path = settings.FLUTTER_APP_BUILD_DIR / "main.dart.js"
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
    options = _system_auth_options_payload()
    return render(
        request,
        "home.html",
        {
            "local_login_enabled": _local_login_enabled(options=options),
            "local_register_enabled": _local_register_enabled(options=options),
            "techcloud_oauth_enabled": _effective_techcloud_oauth_enabled(options=options),
        },
    )


@login_required(login_url="/accounts/login")
def dashboard_view(request):
    flutter_index = settings.FLUTTER_APP_BUILD_DIR / "index.html"
    if flutter_index.exists():
        return render(
            request,
            "flutter_app.html",
            {"flutter_cache_bust": _flutter_cache_bust()},
        )
    return HttpResponse(
        "Flutter app static files are missing. Run `flutter build web` in "
        "`flutter_app` and sync `build/web` to `artifacts/flutter_app_web`.",
        status=503,
        content_type="text/plain; charset=utf-8",
    )


@login_required(login_url="/accounts/login")
def billing_dashboard_view(request):
    if not request.user.is_superuser:
        return redirect("/dashboard")
    flutter_index = settings.FLUTTER_APP_BUILD_DIR / "index.html"
    if flutter_index.exists():
        return render(
            request,
            "flutter_app.html",
            {"flutter_cache_bust": _flutter_cache_bust()},
        )
    return HttpResponse(
        "Flutter app static files are missing. Run `flutter build web` in "
        "`flutter_app` and sync `build/web` to `artifacts/flutter_app_web`.",
        status=503,
        content_type="text/plain; charset=utf-8",
    )


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
    options = _system_auth_options_payload()
    if not _local_register_enabled(options=options):
        return render(
            request,
            "registration/register.html",
            {
                "form": MeetingRegisterForm(),
                "register_disabled": True,
                "register_disabled_reason": "管理员已关闭本地注册",
                "local_login_enabled": _local_login_enabled(options=options),
            },
            status=403,
        )

    if request.method == "POST":
        form = MeetingRegisterForm(request.POST)
        if form.is_valid():
            username = form.cleaned_data["username"]
            email = form.cleaned_data["email"]
            if User.objects.filter(Q(username=username) | Q(email=email)).exists():
                form.add_error(None, "用户名或邮箱已存在")
                return render(
                    request,
                    "registration/register.html",
                    {
                        "form": form,
                        "register_disabled": False,
                        "local_login_enabled": _local_login_enabled(options=options),
                    },
                )
            user = form.save(commit=False)
            user.email = email
            user.save()
            _profile_for_user(user)
            _billing_profile_for_user(user)
            _ensure_default_workspace_for_user(user, seed=username)

            log_audit(
                user=user,
                action="auth.register_page",
                resource_type="user",
                resource_id=user.id,
                detail="Registered from web page",
                ip_address=client_ip(request),
            )
            auth_login(request, user)
            request.session.pop(_TECHCLOUD_AUTHENTICATED_SESSION_KEY, None)
            return redirect("/dashboard")
    else:
        form = MeetingRegisterForm()
    return render(
        request,
        "registration/register.html",
        {
            "form": form,
            "register_disabled": False,
            "local_login_enabled": _local_login_enabled(options=options),
        },
    )


def techcloud_oauth_start(request):
    if request.user.is_authenticated:
        return redirect("/dashboard")
    options = _system_auth_options_payload()
    if not _effective_techcloud_oauth_enabled(options=options):
        if not options.get("techcloud_oauth_configured"):
            return _techcloud_login_error_redirect("科技云登录未配置，请联系管理员")
        return _techcloud_login_error_redirect("管理员已关闭科技云登录")

    next_path = _safe_next_path(request.GET.get("next", ""))
    if next_path:
        request.session[_TECHCLOUD_OAUTH_NEXT_KEY] = next_path
    else:
        request.session.pop(_TECHCLOUD_OAUTH_NEXT_KEY, None)

    state = uuid4().hex
    request.session[_TECHCLOUD_OAUTH_STATE_KEY] = state
    return redirect(_techcloud_authorize_url(state))


def techcloud_oauth_callback(request):
    if request.user.is_authenticated:
        return redirect("/dashboard")
    options = _system_auth_options_payload()
    if not _effective_techcloud_oauth_enabled(options=options):
        if not options.get("techcloud_oauth_configured"):
            return _techcloud_login_error_redirect("科技云登录未配置，请联系管理员")
        return _techcloud_login_error_redirect("管理员已关闭科技云登录")

    oauth_error = (request.GET.get("error") or "").strip()
    if oauth_error:
        error_description = (request.GET.get("error_description") or oauth_error).strip()
        return _techcloud_login_error_redirect(f"科技云登录失败：{error_description}")

    code = (request.GET.get("code") or "").strip()
    if not code:
        return _techcloud_login_error_redirect("科技云回调缺少授权码")

    expected_state = (request.session.pop(_TECHCLOUD_OAUTH_STATE_KEY, "") or "").strip()
    state = (request.GET.get("state") or "").strip()
    if not expected_state or expected_state != state:
        return _techcloud_login_error_redirect("科技云登录状态校验失败，请重试")

    try:
        token_payload = _techcloud_exchange_code_for_token(code)
        user_info = _techcloud_user_info_from_token_payload(token_payload)
        user, _created = _upsert_techcloud_user(user_info)
    except ValueError as exc:
        return _techcloud_login_error_redirect(str(exc))

    auth_login(request, user)
    request.session[_TECHCLOUD_AUTHENTICATED_SESSION_KEY] = True
    log_audit(
        user=user,
        action="auth.login_techcloud",
        resource_type="user",
        resource_id=user.id,
        detail=f"umtId={user_info.get('umtId', '')}, cstnetId={user_info.get('cstnetId', '')}",
        ip_address=client_ip(request),
    )

    next_path = _safe_next_path(request.session.pop(_TECHCLOUD_OAUTH_NEXT_KEY, ""))
    if next_path:
        return redirect(next_path)
    return redirect("/dashboard")


@login_required(login_url="/accounts/login")
def session_jwt(request):
    refresh = RefreshToken.for_user(request.user)
    token = str(refresh.access_token)
    return JsonResponse({"access_token": token, "token_type": "bearer"})


def session_logout(request):
    is_techcloud_session = bool(
        request.session.get(_TECHCLOUD_AUTHENTICATED_SESSION_KEY, False)
    )
    if request.user.is_authenticated:
        auth_logout(request)
    if is_techcloud_session:
        techcloud_logout = _techcloud_logout_url(request, next_path="/")
        if techcloud_logout:
            return redirect(techcloud_logout)
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
            "auth_options": _system_auth_options_payload(),
        }
    )


@api_view(["GET", "PATCH"])
@permission_classes([IsAuthenticated])
def system_auth_options(request):
    if not request.user.is_superuser:
        return Response({"detail": "Only super admin can manage auth options"}, status=status.HTTP_403_FORBIDDEN)

    config = _system_auth_config()
    if request.method == "GET":
        return Response(_system_auth_options_payload(config=config))

    serializer = SystemAuthConfigUpdateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    payload = serializer.validated_data

    updated_fields: list[str] = []
    for field in ("allow_techcloud_oauth_login", "allow_local_register", "allow_local_login"):
        if field not in payload:
            continue
        next_value = bool(payload[field])
        if getattr(config, field) == next_value:
            continue
        setattr(config, field, next_value)
        updated_fields.append(field)
    config.updated_by = request.user
    updated_fields.append("updated_by")

    if updated_fields:
        updated_fields.append("updated_at")
        config.save(update_fields=updated_fields)
        log_audit(
            user=request.user,
            action="system.auth_options_update",
            resource_type="system_auth_config",
            resource_id=config.id,
            detail=json.dumps(
                {
                    "allow_techcloud_oauth_login": config.allow_techcloud_oauth_login,
                    "allow_local_register": config.allow_local_register,
                    "allow_local_login": config.allow_local_login,
                },
                ensure_ascii=False,
            ),
            ip_address=client_ip(request),
        )

    return Response(_system_auth_options_payload(config=config))


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def billing_users_export(request):
    if not request.user.is_superuser:
        return Response({"detail": "Only super admin can export users"}, status=status.HTTP_403_FORBIDDEN)

    now = timezone.now()
    users = User.objects.all().order_by("date_joined", "id")

    response = HttpResponse(content_type="text/csv; charset=utf-8")
    stamp = now.strftime("%Y%m%d-%H%M%S")
    response["Content-Disposition"] = f'attachment; filename="billing-users-{stamp}.csv"'
    response.write("\ufeff")

    writer = csv.writer(response)
    writer.writerow(
        [
            "user_id",
            "username",
            "email",
            "is_superuser",
            "plan_name",
            "active_room_count",
            "room_peak_count",
            "max_room_participants_used",
            "meeting_count",
            "cumulative_room_used_seconds",
            "current_room_max_used_seconds",
            "recording_storage_used_bytes",
            "max_active_rooms",
            "max_room_participants",
            "max_meeting_count",
            "max_room_used_seconds",
            "max_current_room_used_seconds",
            "max_recording_storage_bytes",
            "exceeded_keys",
            "date_joined",
            "last_login",
            "billing_updated_at",
        ]
    )

    for user in users:
        payload = _billing_user_payload(user, now=now)
        usage = payload.get("usage", {})
        limits = payload.get("limits", {})
        writer.writerow(
            [
                payload.get("user_id", ""),
                payload.get("username", ""),
                payload.get("email", ""),
                int(bool(payload.get("is_superuser"))),
                payload.get("plan_name") or "",
                usage.get("active_room_count", 0),
                usage.get("room_peak_count", 0),
                usage.get("max_room_participants_used", 0),
                usage.get("meeting_count", 0),
                usage.get("cumulative_room_used_seconds", 0),
                usage.get("current_room_max_used_seconds", 0),
                usage.get("recording_storage_used_bytes", 0),
                limits.get("max_active_rooms", ""),
                limits.get("max_room_participants", ""),
                limits.get("max_meeting_count", ""),
                limits.get("max_room_used_seconds", ""),
                limits.get("max_current_room_used_seconds", ""),
                limits.get("max_recording_storage_bytes", ""),
                ",".join(payload.get("exceeded_keys", [])),
                user.date_joined.isoformat() if user.date_joined else "",
                user.last_login.isoformat() if user.last_login else "",
                payload.get("updated_at").isoformat() if payload.get("updated_at") else "",
            ]
        )

    log_audit(
        user=request.user,
        action="billing.users_export",
        resource_type="user",
        detail=f"rows={users.count()}",
        ip_address=client_ip(request),
    )
    return response


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
    options = _system_auth_options_payload()
    if not _local_register_enabled(options=options):
        return Response({"detail": "Local registration is disabled by super admin"}, status=status.HTTP_403_FORBIDDEN)

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
    _ensure_default_workspace_for_user(user, seed=data["username"])

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
    options = _system_auth_options_payload()
    if not _local_login_enabled(options=options):
        return Response({"detail": "Local username/password login is disabled by super admin"}, status=status.HTTP_403_FORBIDDEN)

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
        elif key == "realtime_bot_provider":
            setattr(meeting, key, _normalized_realtime_provider(value))
        elif key == "realtime_bot_api_key":
            setattr(meeting, key, (value or "").strip())
        elif key == "realtime_bot_base_url":
            setattr(meeting, key, _normalized_realtime_base_url(value))
        elif key == "realtime_bot_volc_ws_url":
            setattr(meeting, key, _normalized_realtime_volc_ws_url(value))
        elif key == "realtime_bot_volc_resource_id":
            setattr(meeting, key, _normalized_realtime_volc_resource_id(value))
        elif key in {
            "realtime_bot_volc_app_id",
            "realtime_bot_volc_app_key",
            "realtime_bot_volc_access_key",
            "realtime_bot_volc_uid",
        }:
            setattr(meeting, key, (value or "").strip())
        elif key in {
            "realtime_bot_model",
            "realtime_bot_voice",
            "realtime_bot_openai_model",
            "realtime_bot_openai_voice",
            "realtime_bot_volc_model",
            "realtime_bot_volc_voice",
            "realtime_bot_display_name",
        }:
            setattr(meeting, key, (value or "").strip())
        else:
            setattr(meeting, key, value)


def _normalized_realtime_provider(raw_value: str) -> str:
    value = (raw_value or "").strip().lower()
    if not value:
        return _REALTIME_BOT_DEFAULT_PROVIDER
    if value == RealtimeBotProvider.VOLCENGINE:
        return RealtimeBotProvider.VOLCENGINE
    if value == RealtimeBotProvider.OPENAI:
        return RealtimeBotProvider.OPENAI
    return _REALTIME_BOT_DEFAULT_PROVIDER


def _normalized_realtime_base_url(raw_value: str) -> str:
    value = (raw_value or "").strip()
    if not value:
        return _REALTIME_BOT_DEFAULT_BASE_URL
    if "://" not in value:
        value = f"https://{value}"
    return value.rstrip("/")


def _normalized_realtime_volc_ws_url(raw_value: str) -> str:
    value = (raw_value or "").strip()
    if not value:
        return _REALTIME_BOT_DEFAULT_VOLC_WS_URL
    if "://" not in value:
        value = f"wss://{value}"
    parsed = urlsplit(value)
    scheme = parsed.scheme.lower()
    if scheme == "http":
        scheme = "ws"
    elif scheme == "https":
        scheme = "wss"
    elif scheme not in {"ws", "wss"}:
        scheme = "wss"
    path = (parsed.path or "").strip() or "/api/v3/realtime/dialogue"
    if not path.startswith("/"):
        path = f"/{path}"
    return urlunsplit((scheme, parsed.netloc, path, parsed.query, parsed.fragment)).rstrip("/")


def _normalized_realtime_volc_resource_id(raw_value: str) -> str:
    value = (raw_value or "").strip()
    if not value:
        return _REALTIME_BOT_DEFAULT_VOLC_RESOURCE_ID
    return value


def _meeting_realtime_bot_provider(meeting) -> str:
    return _normalized_realtime_provider(getattr(meeting, "realtime_bot_provider", ""))


def _meeting_realtime_bot_api_key(meeting) -> str:
    value = (getattr(meeting, "realtime_bot_api_key", "") or "").strip()
    return value or _REALTIME_BOT_DEFAULT_API_KEY


def _meeting_realtime_bot_openai_model(meeting) -> str:
    value = (getattr(meeting, "realtime_bot_openai_model", "") or "").strip()
    if value:
        return value
    legacy_value = (getattr(meeting, "realtime_bot_model", "") or "").strip()
    if legacy_value and legacy_value not in _VOLCENGINE_ALLOWED_MODELS:
        return legacy_value
    return _REALTIME_BOT_DEFAULT_MODEL


def _meeting_realtime_bot_openai_voice(meeting) -> str:
    value = (getattr(meeting, "realtime_bot_openai_voice", "") or "").strip()
    if value:
        return value
    legacy_value = (getattr(meeting, "realtime_bot_voice", "") or "").strip()
    if legacy_value:
        normalized = legacy_value.lower()
        if (
            normalized not in _VOLCENGINE_O2_SPEAKERS
            and normalized not in _VOLCENGINE_SC2_SPEAKERS
            and not normalized.startswith("saturn_")
            and not normalized.startswith("icl_")
            and not normalized.startswith("zh_")
        ):
            return legacy_value
    return _REALTIME_BOT_DEFAULT_VOICE


def _meeting_realtime_bot_volc_model(meeting) -> str:
    value = (getattr(meeting, "realtime_bot_volc_model", "") or "").strip()
    if value in _VOLCENGINE_ALLOWED_MODELS:
        return value
    legacy_value = (getattr(meeting, "realtime_bot_model", "") or "").strip()
    if legacy_value in _VOLCENGINE_ALLOWED_MODELS:
        return legacy_value
    default_value = (_REALTIME_BOT_DEFAULT_VOLC_MODEL or "").strip()
    if default_value in _VOLCENGINE_ALLOWED_MODELS:
        return default_value
    return _VOLCENGINE_MODEL_SC2


def _meeting_realtime_bot_volc_raw_voice(meeting) -> str:
    value = (getattr(meeting, "realtime_bot_volc_voice", "") or "").strip()
    if value:
        return value
    legacy_value = (getattr(meeting, "realtime_bot_voice", "") or "").strip()
    if legacy_value and legacy_value != _REALTIME_BOT_DEFAULT_VOICE:
        return legacy_value
    return ""


def _meeting_realtime_bot_volc_uid(meeting) -> str:
    value = (getattr(meeting, "realtime_bot_volc_uid", "") or "").strip()
    if value:
        return value
    default_uid = (_REALTIME_BOT_DEFAULT_VOLC_UID or "").strip()
    if default_uid:
        return default_uid.replace("{meeting_id}", str(getattr(meeting, "id", "0")))
    return f"meeting-{getattr(meeting, 'id', '0')}"


def _meeting_realtime_bot_volc_app_id(meeting) -> str:
    value = (getattr(meeting, "realtime_bot_volc_app_id", "") or "").strip()
    return value or _REALTIME_BOT_DEFAULT_VOLC_APP_ID


def _meeting_realtime_bot_volc_app_key(meeting) -> str:
    value = (getattr(meeting, "realtime_bot_volc_app_key", "") or "").strip()
    return value or _REALTIME_BOT_DEFAULT_VOLC_APP_KEY


def _meeting_realtime_bot_volc_access_key(meeting) -> str:
    value = (getattr(meeting, "realtime_bot_volc_access_key", "") or "").strip()
    return value or _REALTIME_BOT_DEFAULT_VOLC_ACCESS_KEY


def _meeting_realtime_bot_volc_model_legacy_fallback(meeting) -> str:
    value = (getattr(meeting, "realtime_bot_model", "") or "").strip()
    if value in _VOLCENGINE_ALLOWED_MODELS:
        return value
    default_value = (_REALTIME_BOT_DEFAULT_VOLC_MODEL or "").strip()
    if default_value in _VOLCENGINE_ALLOWED_MODELS:
        return default_value
    return _VOLCENGINE_MODEL_SC2


def _normalize_volc_speaker_for_model(*, speaker: str, dialog_model: str) -> str:
    normalized = (speaker or "").strip()
    if not normalized:
        return ""
    if normalized == _REALTIME_BOT_DEFAULT_VOICE:
        return ""
    normalized_lower = normalized.lower()
    if dialog_model == _VOLCENGINE_MODEL_O2:
        if normalized_lower.startswith("saturn_") or normalized_lower.startswith("icl_"):
            return _REALTIME_BOT_DEFAULT_VOLC_O_SPEAKER
        return normalized
    if dialog_model == _VOLCENGINE_MODEL_SC2:
        if normalized_lower in _VOLCENGINE_O2_SPEAKERS:
            return ""
        if normalized_lower.startswith("icl_"):
            candidate = f"saturn_{normalized[4:]}"
            return candidate if candidate in _VOLCENGINE_SC2_SPEAKERS else normalized
        return normalized
    return normalized


def _meeting_realtime_bot_volc_speaker(meeting, dialog_model: str | None = None) -> str:
    model = (dialog_model or "").strip() or _meeting_realtime_bot_volc_model(meeting)
    if not model:
        model = _meeting_realtime_bot_volc_model_legacy_fallback(meeting)
    raw_value = _meeting_realtime_bot_volc_raw_voice(meeting)
    if not raw_value or raw_value == _REALTIME_BOT_DEFAULT_VOICE:
        return (
            _REALTIME_BOT_DEFAULT_VOLC_O_SPEAKER
            if model == _VOLCENGINE_MODEL_O2
            else _REALTIME_BOT_DEFAULT_VOLC_SC_SPEAKER
        )
    normalized = _normalize_volc_speaker_for_model(speaker=raw_value, dialog_model=model)
    if model == _VOLCENGINE_MODEL_O2 and not normalized:
        return _REALTIME_BOT_DEFAULT_VOLC_O_SPEAKER
    return normalized


def _meeting_realtime_bot_display_name(meeting) -> str:
    value = (meeting.realtime_bot_display_name or "").strip()
    return value or _REALTIME_BOT_DEFAULT_DISPLAY_NAME


def _meeting_realtime_bot_ready(meeting) -> bool:
    if not meeting.realtime_bot_enabled:
        return False
    provider = _meeting_realtime_bot_provider(meeting)
    if provider == RealtimeBotProvider.VOLCENGINE:
        ws_url = _normalized_realtime_volc_ws_url(getattr(meeting, "realtime_bot_volc_ws_url", ""))
        app_id = _meeting_realtime_bot_volc_app_id(meeting)
        app_key = _meeting_realtime_bot_volc_app_key(meeting)
        access_key = _meeting_realtime_bot_volc_access_key(meeting)
        resource_id = _normalized_realtime_volc_resource_id(
            getattr(meeting, "realtime_bot_volc_resource_id", "")
        )
        return bool(ws_url and app_id and app_key and access_key and resource_id)
    return bool(_meeting_realtime_bot_api_key(meeting))


def _meeting_realtime_bot_identity(meeting) -> str:
    return f"ai_realtime_bot_{meeting.id}"[:64]


def _sync_realtime_bot_presence(meeting) -> None:
    identity = _meeting_realtime_bot_identity(meeting)
    if not meeting.realtime_bot_enabled:
        MeetingGuestParticipant.objects.filter(
            meeting=meeting,
            participant_identity=identity,
        ).delete()
        return

    guest, _ = MeetingGuestParticipant.objects.get_or_create(
        meeting=meeting,
        participant_identity=identity,
        defaults={
            "display_name": _meeting_realtime_bot_display_name(meeting),
            "display_name_version": 1,
        },
    )
    desired_display_name = _meeting_realtime_bot_display_name(meeting)
    if (guest.display_name or "").strip() != desired_display_name:
        guest.display_name = desired_display_name
        guest.display_name_version = max(1, int(guest.display_name_version or 1)) + 1
        guest.save(update_fields=["display_name", "display_name_version", "updated_at"])


def _realtime_bot_system_user() -> User:
    user, created = User.objects.get_or_create(
        username=_REALTIME_BOT_SYSTEM_USERNAME,
        defaults={
            "email": _REALTIME_BOT_SYSTEM_EMAIL,
            "is_active": True,
        },
    )
    if created:
        user.set_unusable_password()
        user.save(update_fields=["password"])
    return user


def _iter_json_nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _iter_json_nodes(child)
        return
    if isinstance(value, list):
        for child in value:
            yield from _iter_json_nodes(child)


def _extract_text_from_model_payload(payload) -> str:
    if isinstance(payload, dict):
        output_text = payload.get("output_text")
        if isinstance(output_text, str) and output_text.strip():
            return output_text.strip()
        if isinstance(output_text, list):
            joined = "".join(str(item) for item in output_text if str(item).strip()).strip()
            if joined:
                return joined

    parts: list[str] = []
    for node in _iter_json_nodes(payload):
        if not isinstance(node, dict):
            continue
        node_type = str(node.get("type") or "").strip().lower()
        text_value = node.get("text")
        delta_value = node.get("delta")
        transcript_value = node.get("transcript")
        if node_type in {"output_text", "text"} and isinstance(text_value, str) and text_value.strip():
            parts.append(text_value.strip())
        if "text" in node_type and "delta" in node_type and isinstance(delta_value, str) and delta_value:
            parts.append(delta_value)
        if "transcript" in node_type and isinstance(delta_value, str) and delta_value:
            parts.append(delta_value)
        if isinstance(transcript_value, str) and transcript_value.strip():
            parts.append(transcript_value.strip())
    return "".join(parts).strip()


def _extract_audio_from_model_payload(payload) -> tuple[str, str]:
    candidates: list[tuple[str, str]] = []
    for node in _iter_json_nodes(payload):
        if not isinstance(node, dict):
            continue

        node_type = str(node.get("type") or "").strip().lower()
        mime = str(
            node.get("mime_type")
            or node.get("content_type")
            or node.get("format")
            or "",
        ).strip()

        data_value = node.get("data")
        if (
            isinstance(data_value, str)
            and data_value.strip()
            and ("audio" in node_type or node_type in {"output_audio", "audio"})
        ):
            candidates.append((data_value.strip(), mime or "audio/wav"))

        audio_block = node.get("audio")
        if isinstance(audio_block, dict):
            nested_data = audio_block.get("data")
            nested_mime = str(
                audio_block.get("mime_type")
                or audio_block.get("content_type")
                or audio_block.get("format")
                or "",
            ).strip()
            if isinstance(nested_data, str) and nested_data.strip():
                candidates.append((nested_data.strip(), nested_mime or mime or "audio/wav"))

    if not candidates:
        return "", ""
    return candidates[0]


def _decode_base64_audio_delta(delta: str) -> bytes:
    value = (delta or "").strip()
    if not value:
        return b""
    missing_padding = len(value) % 4
    if missing_padding:
        value = f"{value}{'=' * (4 - missing_padding)}"
    return base64.b64decode(value)


def _pcm16le_to_wav_base64(
    pcm_bytes: bytes,
    *,
    sample_rate: int = 24000,
    channels: int = 1,
) -> str:
    if not pcm_bytes:
        return ""
    if len(pcm_bytes) % 2 != 0:
        pcm_bytes = pcm_bytes[: len(pcm_bytes) - 1]
    if not pcm_bytes:
        return ""
    safe_channels = max(1, int(channels))
    safe_rate = max(8000, int(sample_rate))
    leading_ms = int(_REALTIME_BOT_OUTPUT_LEADING_SILENCE_MS or 0)
    if leading_ms > 0:
        lead_samples = int((safe_rate * leading_ms) / 1000)
        if lead_samples > 0:
            pcm_bytes = (b"\x00\x00" * (lead_samples * safe_channels)) + pcm_bytes
    with io.BytesIO() as buffer:
        with wave.open(buffer, "wb") as wav_file:
            wav_file.setnchannels(safe_channels)
            wav_file.setsampwidth(2)
            wav_file.setframerate(safe_rate)
            wav_file.writeframes(pcm_bytes)
        return base64.b64encode(buffer.getvalue()).decode("ascii")


def _coerce_sample_rate(raw_value, default: int = 16000) -> int:
    try:
        parsed = int(raw_value)
    except (TypeError, ValueError):
        return default
    return max(8000, min(parsed, 96000))


def _coerce_channels(raw_value, default: int = 1) -> int:
    try:
        parsed = int(raw_value)
    except (TypeError, ValueError):
        return default
    return max(1, min(parsed, 2))


def _downmix_pcm16_to_mono(pcm_bytes: bytes, channels: int) -> bytes:
    if channels <= 1:
        return pcm_bytes
    frame_bytes = 2 * channels
    if frame_bytes <= 0:
        return pcm_bytes
    usable = len(pcm_bytes) - (len(pcm_bytes) % frame_bytes)
    if usable <= 0:
        return b""
    raw = array("h")
    raw.frombytes(pcm_bytes[:usable])
    mono = array("h")
    for idx in range(0, len(raw), channels):
        frame = raw[idx : idx + channels]
        if not frame:
            continue
        mixed = int(sum(int(sample) for sample in frame) / len(frame))
        mixed = max(-32768, min(32767, mixed))
        mono.append(mixed)
    return mono.tobytes()


def _resample_pcm16_mono(
    pcm_bytes: bytes,
    *,
    source_rate: int,
    target_rate: int,
) -> bytes:
    if not pcm_bytes:
        return b""
    source_rate = _coerce_sample_rate(source_rate)
    target_rate = _coerce_sample_rate(target_rate)
    if source_rate == target_rate:
        return pcm_bytes
    samples = array("h")
    samples.frombytes(pcm_bytes[: len(pcm_bytes) - (len(pcm_bytes) % 2)])
    if not samples:
        return b""
    output_length = int(len(samples) * target_rate / source_rate)
    output_length = max(1, output_length)
    resampled = array("h")
    for i in range(output_length):
        source_pos = i * source_rate / target_rate
        left_index = int(source_pos)
        right_index = min(left_index + 1, len(samples) - 1)
        fraction = source_pos - left_index
        left_value = int(samples[left_index])
        right_value = int(samples[right_index])
        mixed = int(left_value + (right_value - left_value) * fraction)
        mixed = max(-32768, min(32767, mixed))
        resampled.append(mixed)
    return resampled.tobytes()


def _decode_and_normalize_pcm16_audio(
    *,
    audio_base64: str,
    sample_rate: int,
    channels: int,
    target_sample_rate: int = 16000,
) -> bytes:
    raw = _decode_base64_audio_delta(audio_base64)
    if len(raw) % 2 != 0:
        raw = raw[: len(raw) - 1]
    if not raw:
        return b""
    normalized_channels = _coerce_channels(channels, default=1)
    pcm_mono = _downmix_pcm16_to_mono(raw, normalized_channels)
    if not pcm_mono:
        return b""
    return _resample_pcm16_mono(
        pcm_mono,
        source_rate=_coerce_sample_rate(sample_rate, 16000),
        target_rate=_coerce_sample_rate(target_sample_rate, 16000),
    )


def _pcm16_audio_stats(pcm_bytes: bytes, *, sample_rate: int) -> dict:
    if not pcm_bytes:
        return {
            "samples": 0,
            "duration_ms": 0,
            "rms": 0.0,
            "peak": 0.0,
            "non_zero_ratio": 0.0,
        }
    usable = pcm_bytes[: len(pcm_bytes) - (len(pcm_bytes) % 2)]
    if not usable:
        return {
            "samples": 0,
            "duration_ms": 0,
            "rms": 0.0,
            "peak": 0.0,
            "non_zero_ratio": 0.0,
        }

    samples = array("h")
    samples.frombytes(usable)
    sample_count = len(samples)
    if sample_count <= 0:
        return {
            "samples": 0,
            "duration_ms": 0,
            "rms": 0.0,
            "peak": 0.0,
            "non_zero_ratio": 0.0,
        }

    sum_sq = 0.0
    peak_abs = 0
    non_zero_count = 0
    for sample in samples:
        value = int(sample)
        abs_value = abs(value)
        if abs_value > peak_abs:
            peak_abs = abs_value
        if abs_value > 16:
            non_zero_count += 1
        sum_sq += float(value * value)

    rms = math.sqrt(sum_sq / sample_count) / 32768.0
    peak = float(peak_abs) / 32768.0
    duration_ms = int((sample_count * 1000) / max(1, int(sample_rate)))
    non_zero_ratio = float(non_zero_count) / float(sample_count)
    return {
        "samples": int(sample_count),
        "duration_ms": int(duration_ms),
        "rms": float(round(rms, 6)),
        "peak": float(round(peak, 6)),
        "non_zero_ratio": float(round(non_zero_ratio, 6)),
    }


def _auto_gain_pcm16_for_asr(
    pcm_bytes: bytes,
    *,
    sample_rate: int = 16000,
    target_rms: float = 0.02,
    min_rms_to_boost: float = 0.004,
    max_gain: float = 24.0,
) -> tuple[bytes, dict, dict, float]:
    before = _pcm16_audio_stats(pcm_bytes, sample_rate=sample_rate)
    if not pcm_bytes:
        return pcm_bytes, before, before, 1.0

    rms = float(before.get("rms") or 0.0)
    peak = float(before.get("peak") or 0.0)
    if rms <= 0.0 or rms >= float(min_rms_to_boost):
        return pcm_bytes, before, before, 1.0

    gain = float(target_rms) / max(rms, 1e-9)
    gain = max(1.0, min(float(max_gain), gain))
    if peak > 0:
        gain = min(gain, 0.95 / peak)
    if gain <= 1.05:
        return pcm_bytes, before, before, 1.0

    samples = array("h")
    usable = pcm_bytes[: len(pcm_bytes) - (len(pcm_bytes) % 2)]
    samples.frombytes(usable)
    boosted = array("h")
    for sample in samples:
        value = int(round(int(sample) * gain))
        if value > 32767:
            value = 32767
        elif value < -32768:
            value = -32768
        boosted.append(value)

    boosted_bytes = boosted.tobytes()
    after = _pcm16_audio_stats(boosted_bytes, sample_rate=sample_rate)
    return boosted_bytes, before, after, float(round(gain, 3))


def _openai_realtime_ws_url(base_url: str, model: str) -> str:
    normalized_base = _normalized_realtime_base_url(base_url)
    parsed = urlsplit(normalized_base)
    scheme = "wss" if parsed.scheme.lower() == "https" else "ws"
    path = (parsed.path or "").rstrip("/")
    if path.endswith("/v1"):
        path = path[:-3]
    ws_path = f"{path}/v1/realtime"
    query = urlencode({"model": model})
    return urlunsplit((scheme, parsed.netloc, ws_path, query, ""))


def _decode_ws_json_message(raw_message):
    raw_text = raw_message
    if isinstance(raw_message, bytes):
        try:
            raw_text = raw_message.decode("utf-8", errors="ignore")
        except Exception:
            return None
    if not isinstance(raw_text, str):
        return None
    text = raw_text.strip()
    if not text:
        return None
    try:
        payload = json.loads(text)
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    return payload


def _call_realtime_bot_via_openai_websocket(
    *,
    base_url: str,
    model: str,
    api_key: str,
    voice: str,
    prompt: str,
    request_audio: bool,
    ws_url_override: str | None = None,
    extra_headers: list[str] | None = None,
) -> tuple[str, str, str]:
    try:
        import websocket  # type: ignore
    except Exception as exc:
        raise RuntimeError("websocket client library is not available") from exc

    ws_url = ws_url_override or _openai_realtime_ws_url(base_url, model)
    headers = [
        f"Authorization: Bearer {api_key}",
        "Content-Type: application/json",
        "OpenAI-Beta: realtime=v1",
    ]
    if extra_headers:
        headers.extend(extra_headers)
    ws = websocket.create_connection(
        ws_url,
        header=headers,
        timeout=_REALTIME_BOT_WS_CONNECT_TIMEOUT_SECONDS,
    )
    try:
        if hasattr(ws, "settimeout"):
            ws.settimeout(1)

        output_modalities = ["audio", "text"] if request_audio else ["text"]
        session_payload = {
            "type": "session.update",
            "session": {
                "type": "realtime",
                "model": model,
                "instructions": (
                    "You are a concise realtime meeting assistant. "
                    "Always answer in Chinese and keep replies brief and clear."
                ),
                "output_modalities": output_modalities,
                "audio": {
                    "output": {
                        "voice": voice,
                        "format": {
                            "type": "audio/pcm",
                            "rate": 24000,
                        },
                    },
                },
            },
        }
        ws.send(json.dumps(session_payload, ensure_ascii=False, separators=(",", ":")))
        ws.send(
            json.dumps(
                {
                    "type": "conversation.item.create",
                    "item": {
                        "type": "message",
                        "role": "user",
                        "content": [
                            {
                                "type": "input_text",
                                "text": prompt,
                            }
                        ],
                    },
                },
                ensure_ascii=False,
                separators=(",", ":"),
            )
        )
        ws.send(
            json.dumps(
                {
                    "type": "response.create",
                    "response": {
                        "output_modalities": output_modalities,
                    },
                },
                ensure_ascii=False,
                separators=(",", ":"),
            )
        )

        text_chunks: list[str] = []
        audio_pcm_bytes = bytearray()
        audio_base64_chunks: list[str] = []
        audio_mime = "audio/wav" if request_audio else ""
        deadline = time.time() + max(_REALTIME_BOT_RESPONSE_TIMEOUT_SECONDS, 35)
        timeout_error = getattr(websocket, "WebSocketTimeoutException", Exception)
        while time.time() < deadline:
            try:
                raw = ws.recv()
            except timeout_error:
                continue
            if not raw:
                continue
            event = _decode_ws_json_message(raw)
            if event is None:
                continue
            event_type = str(event.get("type") or "").strip().lower()
            if event_type == "error":
                error_detail = event.get("error") or event.get("message") or event
                raise RuntimeError(f"realtime ws error: {error_detail}")

            delta = event.get("delta")
            if isinstance(delta, str) and delta:
                if "audio" in event_type and "transcript" not in event_type:
                    try:
                        audio_pcm_bytes.extend(_decode_base64_audio_delta(delta))
                    except Exception:
                        audio_base64_chunks.append(delta)
                elif "text" in event_type or "transcript" in event_type:
                    text_chunks.append(delta)

            if event_type == "response.output_item.done":
                item_text = _extract_text_from_model_payload(event)
                if item_text:
                    text_chunks.append(item_text)
                item_audio, item_audio_mime = _extract_audio_from_model_payload(event)
                if item_audio:
                    audio_base64_chunks.append(item_audio)
                    if item_audio_mime:
                        audio_mime = item_audio_mime

            if event_type in {"response.done", "response.completed"}:
                response_obj = event.get("response")
                if isinstance(response_obj, dict):
                    status_value = str(response_obj.get("status") or "").strip().lower()
                    if status_value and status_value != "completed":
                        detail = response_obj.get("status_details") or response_obj.get("error") or response_obj
                        raise RuntimeError(f"realtime response status={status_value}: {detail}")
                done_text = _extract_text_from_model_payload(
                    response_obj if isinstance(response_obj, dict) else event
                )
                if done_text:
                    text_chunks.append(done_text)
                done_audio, done_audio_mime = _extract_audio_from_model_payload(
                    response_obj if isinstance(response_obj, dict) else event
                )
                if done_audio:
                    audio_base64_chunks.append(done_audio)
                    if done_audio_mime:
                        audio_mime = done_audio_mime
                break

        text = "".join(text_chunks).strip()
        audio_base64 = ""
        if request_audio:
            if audio_pcm_bytes:
                wav_base64 = _pcm16le_to_wav_base64(bytes(audio_pcm_bytes), sample_rate=24000, channels=1)
                if wav_base64:
                    audio_base64 = wav_base64
                    audio_mime = "audio/wav"
                else:
                    audio_base64 = base64.b64encode(bytes(audio_pcm_bytes)).decode("ascii")
                    audio_mime = "audio/pcm"
            elif audio_base64_chunks:
                audio_base64 = "".join(chunk.strip() for chunk in audio_base64_chunks if chunk.strip())
        if not text:
            text = _extract_text_from_model_payload({"output": [{"text": text}]})
        if not text:
            raise RuntimeError("realtime ws did not return text output")
        if request_audio and not audio_base64:
            # Keep text reply even if audio chunk is unavailable.
            audio_mime = ""
        return text, audio_base64, audio_mime
    finally:
        try:
            ws.close()
        except Exception:
            pass


def _call_realtime_bot_via_openai_audio_websocket(
    *,
    base_url: str,
    model: str,
    api_key: str,
    voice: str,
    audio_pcm16: bytes,
    input_sample_rate: int = 16000,
    request_audio: bool,
    ws_url_override: str | None = None,
    extra_headers: list[str] | None = None,
) -> tuple[str, str, str]:
    try:
        import websocket  # type: ignore
    except Exception as exc:
        raise RuntimeError("websocket client library is not available") from exc

    if not audio_pcm16:
        raise RuntimeError("input audio is empty")

    ws_url = ws_url_override or _openai_realtime_ws_url(base_url, model)
    headers = [
        f"Authorization: Bearer {api_key}",
        "Content-Type: application/json",
        "OpenAI-Beta: realtime=v1",
    ]
    if extra_headers:
        headers.extend(extra_headers)
    ws = websocket.create_connection(
        ws_url,
        header=headers,
        timeout=_REALTIME_BOT_WS_CONNECT_TIMEOUT_SECONDS,
    )
    try:
        if hasattr(ws, "settimeout"):
            ws.settimeout(1)

        output_modalities = ["audio", "text"] if request_audio else ["text"]
        ws.send(
            json.dumps(
                {
                    "type": "session.update",
                    "session": {
                        "type": "realtime",
                        "model": model,
                        "instructions": (
                            "You are a concise realtime meeting assistant. "
                            "Always answer in Chinese and keep replies brief and clear."
                        ),
                        "output_modalities": output_modalities,
                        "audio": {
                            "input": {
                                "format": {
                                    "type": "audio/pcm",
                                    "rate": _coerce_sample_rate(input_sample_rate, 16000),
                                },
                            },
                            "output": {
                                "voice": voice,
                                "format": {
                                    "type": "audio/pcm",
                                    "rate": 24000,
                                },
                            },
                        },
                    },
                },
                ensure_ascii=False,
                separators=(",", ":"),
            )
        )

        chunk_size = 6400
        for idx in range(0, len(audio_pcm16), chunk_size):
            chunk = audio_pcm16[idx : idx + chunk_size]
            if not chunk:
                continue
            ws.send(
                json.dumps(
                    {
                        "type": "input_audio_buffer.append",
                        "audio": base64.b64encode(chunk).decode("ascii"),
                    },
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
            )
        ws.send(json.dumps({"type": "input_audio_buffer.commit"}, separators=(",", ":")))
        ws.send(
            json.dumps(
                {
                    "type": "response.create",
                    "response": {
                        "output_modalities": output_modalities,
                    },
                },
                ensure_ascii=False,
                separators=(",", ":"),
            )
        )

        text_chunks: list[str] = []
        audio_pcm_bytes = bytearray()
        audio_base64_chunks: list[str] = []
        audio_mime = "audio/wav" if request_audio else ""
        deadline = time.time() + max(_REALTIME_BOT_RESPONSE_TIMEOUT_SECONDS, 35)
        timeout_error = getattr(websocket, "WebSocketTimeoutException", Exception)
        while time.time() < deadline:
            try:
                raw = ws.recv()
            except timeout_error:
                continue
            if not raw:
                continue
            event = _decode_ws_json_message(raw)
            if event is None:
                continue
            event_type = str(event.get("type") or "").strip().lower()
            if event_type == "error":
                error_detail = event.get("error") or event.get("message") or event
                raise RuntimeError(f"realtime ws error: {error_detail}")

            delta = event.get("delta")
            if isinstance(delta, str) and delta:
                if "audio" in event_type and "transcript" not in event_type:
                    try:
                        audio_pcm_bytes.extend(_decode_base64_audio_delta(delta))
                    except Exception:
                        audio_base64_chunks.append(delta)
                elif "text" in event_type or "transcript" in event_type:
                    text_chunks.append(delta)

            transcript = event.get("transcript")
            if isinstance(transcript, str) and transcript.strip():
                text_chunks.append(transcript.strip())

            if event_type == "response.output_item.done":
                item_text = _extract_text_from_model_payload(event)
                if item_text:
                    text_chunks.append(item_text)
                item_audio, item_audio_mime = _extract_audio_from_model_payload(event)
                if item_audio:
                    audio_base64_chunks.append(item_audio)
                    if item_audio_mime:
                        audio_mime = item_audio_mime

            if event_type in {"response.done", "response.completed"}:
                response_obj = event.get("response")
                if isinstance(response_obj, dict):
                    status_value = str(response_obj.get("status") or "").strip().lower()
                    if status_value and status_value != "completed":
                        detail = response_obj.get("status_details") or response_obj.get("error") or response_obj
                        raise RuntimeError(f"realtime response status={status_value}: {detail}")
                done_text = _extract_text_from_model_payload(
                    response_obj if isinstance(response_obj, dict) else event
                )
                if done_text:
                    text_chunks.append(done_text)
                done_audio, done_audio_mime = _extract_audio_from_model_payload(
                    response_obj if isinstance(response_obj, dict) else event
                )
                if done_audio:
                    audio_base64_chunks.append(done_audio)
                    if done_audio_mime:
                        audio_mime = done_audio_mime
                break

        text = "".join(text_chunks).strip()
        audio_base64 = ""
        if request_audio:
            if audio_pcm_bytes:
                wav_base64 = _pcm16le_to_wav_base64(bytes(audio_pcm_bytes), sample_rate=24000, channels=1)
                if wav_base64:
                    audio_base64 = wav_base64
                    audio_mime = "audio/wav"
                else:
                    audio_base64 = base64.b64encode(bytes(audio_pcm_bytes)).decode("ascii")
                    audio_mime = "audio/pcm"
            elif audio_base64_chunks:
                audio_base64 = "".join(chunk.strip() for chunk in audio_base64_chunks if chunk.strip())
        if not text:
            raise RuntimeError("realtime ws did not return text output")
        if request_audio and not audio_base64:
            audio_mime = ""
        return text, audio_base64, audio_mime
    finally:
        try:
            ws.close()
        except Exception:
            pass


def _extract_text_from_volcengine_ws_event(payload) -> str:
    text = _extract_text_from_model_payload(payload)
    if text:
        return text
    candidates: list[str] = []
    for node in _iter_json_nodes(payload):
        if not isinstance(node, dict):
            continue
        for key in (
            "text",
            "answer",
            "reply",
            "message",
            "sentence",
            "transcript",
            "final_text",
            "utterance",
        ):
            value = node.get(key)
            if isinstance(value, str) and value.strip():
                lowered_key = key.lower()
                # Avoid echoing user input/query payloads as assistant output.
                if lowered_key in {"text", "message"}:
                    role = str(node.get("role") or node.get("speaker") or "").strip().lower()
                    if role in {"user", "human", "client"}:
                        continue
                if lowered_key == "text" and node.get("query") and not node.get("answer"):
                    continue
                candidates.append(value.strip())
            elif isinstance(value, (list, tuple)):
                for item in value:
                    if isinstance(item, str) and item.strip():
                        candidates.append(item.strip())
    return " ".join(candidates).strip()


def _extract_asr_text_from_volcengine_payload(payload_msg) -> tuple[str, bool]:
    if not isinstance(payload_msg, dict):
        return "", False

    results = payload_msg.get("results")
    if isinstance(results, list):
        final_parts: list[str] = []
        interim_parts: list[str] = []
        for item in results:
            if not isinstance(item, dict):
                continue
            text = str(item.get("text") or "").strip()
            if not text:
                continue
            if bool(item.get("is_interim")):
                interim_parts.append(text)
            else:
                final_parts.append(text)
        if final_parts:
            return "".join(final_parts).strip(), False
        if interim_parts:
            return "".join(interim_parts).strip(), True

    direct_text = str(payload_msg.get("text") or payload_msg.get("content") or "").strip()
    if direct_text:
        return direct_text, False
    return "", False


def _normalized_realtime_reply_text(text: str, *, audio_base64: str = "") -> str:
    normalized = (text or "").strip()
    if normalized:
        return normalized
    if (audio_base64 or "").strip():
        # Some volcengine realtime turns may only return TTS audio chunks.
        return "（语音回复）"
    return ""


def _volcengine_ws_headers(
    *,
    app_id: str,
    app_key: str,
    access_key: str,
    resource_id: str,
    connect_id: str,
) -> list[str]:
    return [
        "Content-Type: application/json",
        f"X-Api-App-ID: {app_id}",
        f"X-Api-App-Key: {app_key}",
        f"X-Api-Access-Key: {access_key}",
        f"X-Api-Resource-Id: {resource_id}",
        f"X-Api-Connect-Id: {connect_id}",
    ]


def _volcengine_protocol_header(
    *,
    message_type: int = _VOLCENGINE_CLIENT_FULL_REQUEST,
    message_type_flags: int = _VOLCENGINE_MSG_WITH_EVENT,
    serialization: int = _VOLCENGINE_SERIALIZATION_JSON,
    compression: int = _VOLCENGINE_COMPRESSION_GZIP,
) -> bytearray:
    header_size = 1
    header = bytearray()
    header.append((_VOLCENGINE_PROTOCOL_VERSION << 4) | header_size)
    header.append((message_type << 4) | message_type_flags)
    header.append((serialization << 4) | compression)
    header.append(0x00)
    return header


def _volcengine_encode_json_payload(payload: dict) -> bytes:
    raw = json.dumps(payload or {}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return gzip.compress(raw)


def _volcengine_build_request(
    *,
    event: int,
    payload: dict,
    session_id: str | None = None,
) -> bytes:
    request = _volcengine_protocol_header()
    request.extend(int(event).to_bytes(4, "big", signed=False))
    if session_id is not None:
        session_bytes = session_id.encode("utf-8")
        request.extend(len(session_bytes).to_bytes(4, "big", signed=False))
        request.extend(session_bytes)
    payload_bytes = _volcengine_encode_json_payload(payload)
    request.extend(len(payload_bytes).to_bytes(4, "big", signed=False))
    request.extend(payload_bytes)
    return bytes(request)


def _volcengine_build_audio_request(
    *,
    event: int,
    session_id: str,
    audio_payload: bytes,
) -> bytes:
    request = _volcengine_protocol_header(
        message_type=_VOLCENGINE_CLIENT_AUDIO_ONLY_REQUEST,
        message_type_flags=_VOLCENGINE_MSG_WITH_EVENT,
        serialization=_VOLCENGINE_SERIALIZATION_NONE,
        compression=_VOLCENGINE_COMPRESSION_GZIP,
    )
    request.extend(int(event).to_bytes(4, "big", signed=False))
    session_bytes = session_id.encode("utf-8")
    request.extend(len(session_bytes).to_bytes(4, "big", signed=False))
    request.extend(session_bytes)
    payload_bytes = gzip.compress(audio_payload or b"")
    request.extend(len(payload_bytes).to_bytes(4, "big", signed=False))
    request.extend(payload_bytes)
    return bytes(request)


def _volcengine_parse_ws_response(raw_message):
    if isinstance(raw_message, str):
        payload = _decode_ws_json_message(raw_message)
        if payload is None:
            return None
        event_name = str(payload.get("event") or payload.get("type") or "").strip().lower()
        return {"event_name": event_name, "payload_msg": payload}
    if not isinstance(raw_message, (bytes, bytearray)) or len(raw_message) < 4:
        return None

    res = bytes(raw_message)
    header_size = res[0] & 0x0F
    message_type = res[1] >> 4
    message_type_flags = res[1] & 0x0F
    serialization = res[2] >> 4
    compression = res[2] & 0x0F
    payload = res[header_size * 4 :]
    result: dict[str, object] = {}
    payload_msg: bytes | None = None

    if message_type in {_VOLCENGINE_SERVER_FULL_RESPONSE, _VOLCENGINE_SERVER_ACK}:
        result["message_type"] = (
            "SERVER_ACK" if message_type == _VOLCENGINE_SERVER_ACK else "SERVER_FULL_RESPONSE"
        )
        start = 0
        if message_type_flags & _VOLCENGINE_SEQUENCE_FLAGS:
            if len(payload) < start + 4:
                return result
            result["seq"] = int.from_bytes(payload[start : start + 4], "big", signed=False)
            start += 4
        if message_type_flags & _VOLCENGINE_MSG_WITH_EVENT:
            if len(payload) < start + 4:
                return result
            result["event"] = int.from_bytes(payload[start : start + 4], "big", signed=False)
            start += 4
        payload = payload[start:]
        if len(payload) < 4:
            return result
        session_size = int.from_bytes(payload[:4], "big", signed=True)
        has_session_id = (
            0 <= session_size <= _VOLCENGINE_MAX_SESSION_ID_BYTES
            and len(payload) >= 4 + session_size + 4
        )
        if has_session_id:
            session_id = payload[4 : 4 + session_size]
            result["session_id"] = session_id.decode("utf-8", errors="ignore")
            payload = payload[4 + session_size :]
            payload_size = int.from_bytes(payload[:4], "big", signed=False) if len(payload) >= 4 else 0
            payload_msg = payload[4:]
        else:
            payload_size = int.from_bytes(payload[:4], "big", signed=False)
            payload_msg = payload[4:]
        result["payload_size"] = payload_size
    elif message_type == _VOLCENGINE_SERVER_ERROR_RESPONSE:
        if len(payload) >= 4:
            result["code"] = int.from_bytes(payload[:4], "big", signed=False)
        payload_msg = payload[8:] if len(payload) >= 8 else b""
    else:
        return result

    if payload_msg is None:
        return result
    if compression == _VOLCENGINE_COMPRESSION_GZIP and payload_msg:
        try:
            payload_msg = gzip.decompress(payload_msg)
        except Exception:
            return result
    if serialization == _VOLCENGINE_SERIALIZATION_JSON:
        try:
            result["payload_msg"] = json.loads(payload_msg.decode("utf-8"))
        except Exception:
            result["payload_msg"] = {}
    elif serialization == _VOLCENGINE_SERIALIZATION_NONE:
        result["payload_msg"] = payload_msg
    else:
        result["payload_msg"] = payload_msg.decode("utf-8", errors="replace")
    return result


def _volcengine_debug_truncate_text(value: str) -> str:
    text = str(value or "")
    max_chars = int(_REALTIME_BOT_VOLC_DEBUG_EVENTS_MAX_PAYLOAD_CHARS or 2000)
    if len(text) <= max_chars:
        return text
    return f"{text[:max_chars]}...(truncated,len={len(text)})"


def _volcengine_sanitize_debug_payload(value, *, _depth: int = 0):
    if _depth > 6:
        return "<max_depth>"
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, (bytes, bytearray)):
        return {"_type": "bytes", "len": len(value)}
    if isinstance(value, str):
        return _volcengine_debug_truncate_text(value)
    if isinstance(value, (list, tuple)):
        limit = 40
        items = [_volcengine_sanitize_debug_payload(item, _depth=_depth + 1) for item in value[:limit]]
        if len(value) > limit:
            items.append(f"...({len(value) - limit} more)")
        return items
    if isinstance(value, dict):
        sanitized: dict[str, object] = {}
        for raw_key, raw_value in value.items():
            key = str(raw_key)
            lowered = key.lower()
            if any(marker in lowered for marker in ("token", "secret", "password", "authorization", "api_key", "app_key", "access_key")):
                sanitized[key] = "<redacted>"
                continue
            sanitized[key] = _volcengine_sanitize_debug_payload(raw_value, _depth=_depth + 1)
        return sanitized
    return _volcengine_debug_truncate_text(value)


def _volcengine_debug_emit(
    *,
    direction: str,
    phase: str,
    event: int | None = None,
    event_name: str = "",
    session_id: str = "",
    payload=None,
    extra: dict | None = None,
) -> None:
    if not _REALTIME_BOT_VOLC_DEBUG_EVENTS:
        return
    record: dict[str, object] = {
        "ts_ms": int(time.time() * 1000),
        "direction": str(direction or "").strip().lower(),
        "phase": str(phase or "").strip().lower(),
    }
    if event is not None:
        record["event"] = int(event)
    if event_name:
        record["event_name"] = str(event_name)
    if session_id:
        record["session_id"] = str(session_id)
    if payload is not None:
        record["payload"] = _volcengine_sanitize_debug_payload(payload)
    if extra:
        record["extra"] = _volcengine_sanitize_debug_payload(extra)
    try:
        _VOLCENGINE_EVENT_LOGGER.warning(
            "VOLCENGINE_WS_EVENT %s",
            json.dumps(record, ensure_ascii=False, separators=(",", ":")),
        )
    except Exception:
        _VOLCENGINE_EVENT_LOGGER.warning("VOLCENGINE_WS_EVENT %r", record)


def _volcengine_error_detail(event: dict, *, payload_msg=None) -> str:
    payload = payload_msg if payload_msg is not None else event.get("payload_msg")
    parts: list[str] = []
    if isinstance(payload, dict):
        for key in ("message", "error", "status_code", "detail", "code"):
            value = payload.get(key)
            if value is None:
                continue
            text = str(value).strip()
            if text:
                parts.append(f"{key}={text}")
    elif isinstance(payload, (bytes, bytearray)):
        if payload:
            parts.append(f"binary_payload={len(payload)}")
    else:
        text = str(payload or "").strip()
        if text:
            parts.append(text)
    code = event.get("code")
    if code not in {None, ""}:
        parts.append(f"code={code}")
    event_code = int(event.get("event") or 0)
    if event_code > 0:
        parts.append(f"event={event_code}")
    if not parts:
        return "unknown error"
    return ", ".join(dict.fromkeys(parts))


def _volcengine_raise_if_error_event(event: dict) -> None:
    event_code = int(event.get("event") or 0)
    event_name = str(event.get("event_name") or "").strip().lower()
    if "code" in event or event_code in {
        _VOLCENGINE_EVENT_CONNECTION_FAILED,
        _VOLCENGINE_EVENT_SESSION_FAILED,
        _VOLCENGINE_EVENT_DIALOG_COMMON_ERROR,
    } or event_name in {
        "connectionfailed",
        "connection_failed",
        "sessionfailed",
        "session_failed",
        "dialogcommonerror",
        "dialog_common_error",
    }:
        raise RuntimeError(f"volcengine realtime ws error: {_volcengine_error_detail(event)}")


def _volcengine_wait_for_event(
    *,
    ws,
    websocket_module,
    expected_event: int,
    operation: str,
    timeout_seconds: int = 10,
    session_id: str = "",
):
    timeout_error = getattr(websocket_module, "WebSocketTimeoutException", Exception)
    deadline = time.time() + max(1, int(timeout_seconds or 1))
    while time.time() < deadline:
        try:
            raw = ws.recv()
        except timeout_error:
            continue
        if not raw:
            continue
        event = _volcengine_parse_ws_response(raw)
        if event is None:
            continue
        event_code = int(event.get("event") or 0)
        event_name = str(event.get("event_name") or "").strip().lower()
        _volcengine_debug_emit(
            direction="in",
            phase=f"wait_{operation}",
            event=event_code if event_code > 0 else None,
            event_name=event_name,
            session_id=str(event.get("session_id") or session_id or ""),
            payload=event.get("payload_msg"),
            extra={
                "message_type": str(event.get("message_type") or ""),
                "payload_size": int(event.get("payload_size") or 0),
                "code": event.get("code"),
            },
        )
        _volcengine_raise_if_error_event(event)
        if event_code == expected_event:
            return event
        expected_names = {
            _VOLCENGINE_EVENT_CONNECTION_STARTED: {"connectionstarted", "connection_started"},
            _VOLCENGINE_EVENT_SESSION_STARTED: {"sessionstarted", "session_started"},
        }.get(expected_event, set())
        if event_name and event_name in expected_names:
            return event
    raise RuntimeError(f"volcengine {operation} timeout waiting event={expected_event}")


def _volcengine_float32_audio_to_pcm16_bytes(raw_audio) -> bytes:
    if not isinstance(raw_audio, (bytes, bytearray)):
        return b""
    if len(raw_audio) < 4:
        return b""
    raw_bytes = bytes(raw_audio)
    sample_bytes = raw_bytes[: len(raw_bytes) - (len(raw_bytes) % 4)]
    if not sample_bytes:
        return b""

    samples = array("f")
    try:
        samples.frombytes(sample_bytes)
    except Exception:
        return b""

    pcm = bytearray()
    for sample in samples:
        value = max(-1.0, min(1.0, float(sample)))
        pcm_value = int(value * 32767.0)
        pcm.extend(int(pcm_value).to_bytes(2, "little", signed=True))
    return bytes(pcm)


def _volcengine_looks_like_float32_audio(raw_audio: bytes) -> bool:
    if not isinstance(raw_audio, (bytes, bytearray)):
        return False
    raw = bytes(raw_audio)
    if len(raw) < 32 or len(raw) % 4 != 0:
        return False
    sample_bytes = raw[: min(len(raw), 4 * 256)]
    samples = array("f")
    try:
        samples.frombytes(sample_bytes)
    except Exception:
        return False
    if not samples:
        return False
    finite_count = 0
    in_range_count = 0
    for sample in samples:
        value = float(sample)
        if math.isfinite(value):
            finite_count += 1
            if -1.5 <= value <= 1.5:
                in_range_count += 1
    if finite_count <= 0:
        return False
    ratio = in_range_count / finite_count
    return ratio >= 0.9


def _volcengine_extract_tts_pcm16_bytes(payload_msg) -> bytes:
    if isinstance(payload_msg, (bytes, bytearray)):
        raw = bytes(payload_msg)
        if not raw:
            return b""
        if _volcengine_looks_like_float32_audio(raw):
            converted = _volcengine_float32_audio_to_pcm16_bytes(raw)
            if converted:
                return converted
        if len(raw) % 2 == 0:
            return raw
        converted = _volcengine_float32_audio_to_pcm16_bytes(raw)
        return converted if converted else b""

    if isinstance(payload_msg, dict):
        for key in (
            "audio",
            "data",
            "tts_audio",
            "pcm",
            "pcm_data",
            "audio_data",
            "payload",
        ):
            value = payload_msg.get(key)
            if isinstance(value, (bytes, bytearray)):
                return _volcengine_extract_tts_pcm16_bytes(value)
            if isinstance(value, str):
                try:
                    decoded = _decode_base64_audio_delta(value)
                except Exception:
                    decoded = b""
                if decoded:
                    return _volcengine_extract_tts_pcm16_bytes(decoded)
            if isinstance(value, list):
                try:
                    packed = bytes(int(v) & 0xFF for v in value)
                except Exception:
                    packed = b""
                if packed:
                    return _volcengine_extract_tts_pcm16_bytes(packed)
    return b""


def _call_realtime_bot_via_volcengine_dialog_websocket(
    *,
    ws_url: str,
    app_id: str,
    app_key: str,
    access_key: str,
    resource_id: str,
    uid: str,
    prompt: str,
    bot_name: str,
    speaker: str,
    dialog_model: str,
    request_audio: bool,
) -> tuple[str, str, str]:
    try:
        import websocket  # type: ignore
    except Exception as exc:
        raise RuntimeError("websocket client library is not available") from exc

    connect_id = str(uuid4())
    session_id = str(uuid4())
    headers = _volcengine_ws_headers(
        app_id=app_id,
        app_key=app_key,
        access_key=access_key,
        resource_id=resource_id,
        connect_id=connect_id,
    )
    ws = websocket.create_connection(
        ws_url,
        header=headers,
        timeout=_REALTIME_BOT_WS_CONNECT_TIMEOUT_SECONDS,
    )
    try:
        if hasattr(ws, "settimeout"):
            ws.settimeout(1)

        ws.send_binary(
            _volcengine_build_request(
                event=_VOLCENGINE_EVENT_START_CONNECTION,
                payload={},
            )
        )
        _ = ws.recv()

        ws.send_binary(
            _volcengine_build_request(
                event=_VOLCENGINE_EVENT_START_SESSION,
                session_id=session_id,
                payload={
                    "asr": {"extra": {"end_smooth_window_ms": 500}},
                    "tts": {
                        "audio_config": {
                            "channel": 1,
                            "format": "pcm",
                            "sample_rate": 24000,
                        },
                        "speaker": speaker,
                    },
                    "dialog": {
                        "bot_name": bot_name,
                        "dialog_id": session_id,
                        "extra": {
                            "strict_audit": True,
                            "recv_timeout": _REALTIME_BOT_RESPONSE_TIMEOUT_SECONDS,
                            "input_mod": "text",
                            "model": dialog_model,
                        },
                    },
                    "user": {"uid": uid},
                },
            )
        )
        _ = ws.recv()

        ws.send_binary(
            _volcengine_build_request(
                event=_VOLCENGINE_EVENT_CHAT_TEXT_QUERY,
                session_id=session_id,
                payload={"content": prompt},
            )
        )
        sent_legacy_text_query = False
        text_query_sent_at = time.time()

        text_chunks: list[str] = []
        audio_pcm_bytes = bytearray()
        audio_mime = "audio/wav" if request_audio else ""
        text_done = False
        audio_done = not request_audio
        ack_audio_chunks = 0
        event_audio_chunks = 0
        deadline = time.time() + max(_REALTIME_BOT_RESPONSE_TIMEOUT_SECONDS, 12)
        timeout_error = getattr(websocket, "WebSocketTimeoutException", Exception)
        while time.time() < deadline:
            try:
                raw = ws.recv()
            except timeout_error:
                continue
            if not raw:
                continue
            event = _volcengine_parse_ws_response(raw)
            if event is None:
                continue
            if "code" in event:
                detail = event.get("payload_msg") or event.get("code") or event
                raise RuntimeError(f"volcengine realtime ws error: {detail}")

            event_code = int(event.get("event") or 0)
            payload_msg = event.get("payload_msg")
            message_type = str(event.get("message_type") or "").strip().upper()

            if request_audio and message_type == "SERVER_ACK":
                audio_chunk = _volcengine_extract_tts_pcm16_bytes(payload_msg)
                if audio_chunk:
                    audio_pcm_bytes.extend(audio_chunk)
                    ack_audio_chunks += 1

            if event_code in {_VOLCENGINE_EVENT_TEXT_DONE, _VOLCENGINE_EVENT_DIALOG_DONE}:
                text_done = True
            elif event_code == _VOLCENGINE_EVENT_TTS_DONE:
                audio_done = True
            elif event_code == _VOLCENGINE_EVENT_TTS_AUDIO and request_audio:
                audio_chunk = _volcengine_extract_tts_pcm16_bytes(payload_msg)
                # Prefer ACK binary audio stream. Fall back to event chunks only when ACK stream is absent.
                if audio_chunk and ack_audio_chunks == 0:
                    audio_pcm_bytes.extend(audio_chunk)
                    event_audio_chunks += 1

            chunk_text = _extract_text_from_volcengine_ws_event(payload_msg if payload_msg is not None else event)
            if chunk_text and (not text_chunks or chunk_text != text_chunks[-1]):
                text_chunks.append(chunk_text)

            event_name = str(event.get("event_name") or "").strip().lower()
            if event_name in {"chatended", "chat_ended", "response.done", "response.completed", "session.stop"}:
                text_done = True
            if (
                not sent_legacy_text_query
                and not text_chunks
                and not audio_pcm_bytes
                and time.time() - text_query_sent_at >= 3.0
            ):
                ws.send_binary(
                    _volcengine_build_request(
                        event=_VOLCENGINE_EVENT_CHAT_TEXT_QUERY_LEGACY,
                        session_id=session_id,
                        payload={"content": prompt},
                    )
                )
                sent_legacy_text_query = True
            if audio_done and (text_done or bool(audio_pcm_bytes)):
                break
            if text_done and audio_done:
                break

        text = "".join(part for part in text_chunks if part.strip()).strip()
        audio_base64 = ""
        if request_audio and audio_pcm_bytes:
            audio_base64 = _pcm16le_to_wav_base64(bytes(audio_pcm_bytes), sample_rate=24000, channels=1)
            audio_mime = "audio/wav" if audio_base64 else ""
        text = _normalized_realtime_reply_text(text, audio_base64=audio_base64)
        if not text:
            raise RuntimeError(
                "volcengine realtime ws did not return text output "
                f"(audio_bytes={len(audio_pcm_bytes)}, text_chunks={len(text_chunks)}, "
                f"text_done={int(text_done)}, audio_done={int(audio_done)}, "
                f"ack_chunks={ack_audio_chunks}, event_chunks={event_audio_chunks})"
            )
        if request_audio and not audio_base64:
            audio_mime = ""
        return text, audio_base64, audio_mime
    finally:
        try:
            ws.send_binary(
                _volcengine_build_request(
                    event=_VOLCENGINE_EVENT_FINISH_SESSION,
                    session_id=session_id,
                    payload={},
                )
            )
        except Exception:
            pass
        try:
            ws.send_binary(
                _volcengine_build_request(
                    event=_VOLCENGINE_EVENT_FINISH_CONNECTION,
                    payload={},
                )
            )
        except Exception:
            pass
        try:
            ws.close()
        except Exception:
            pass


def _iter_audio_chunks(audio_bytes: bytes, *, chunk_size: int = 3200):
    size = max(320, int(chunk_size or 3200))
    for offset in range(0, len(audio_bytes), size):
        chunk = audio_bytes[offset : offset + size]
        if chunk:
            yield chunk


def _call_realtime_bot_via_volcengine_audio_dialog_websocket(
    *,
    ws_url: str,
    app_id: str,
    app_key: str,
    access_key: str,
    resource_id: str,
    uid: str,
    audio_pcm16: bytes,
    audio_sample_rate: int,
    bot_name: str,
    speaker: str,
    dialog_model: str,
    input_mode: str,
    audio_chunk_bytes: int,
    audio_chunk_sleep_seconds: float,
    request_audio: bool,
) -> tuple[str, str, str]:
    try:
        import websocket  # type: ignore
    except Exception as exc:
        raise RuntimeError("websocket client library is not available") from exc

    if not audio_pcm16:
        raise RuntimeError("volcengine input audio is empty")

    normalized_input_mode = (input_mode or "").strip().lower()
    if normalized_input_mode not in {"audio_file", "push_to_talk", "keep_alive", "mic_silence"}:
        normalized_input_mode = "audio_file"
    chunk_bytes = max(320, int(audio_chunk_bytes or 6400))
    chunk_sleep_seconds = max(0.0, float(audio_chunk_sleep_seconds or 0.0))
    if normalized_input_mode == "push_to_talk":
        chunk_bytes = 640
        if chunk_sleep_seconds > 0:
            chunk_sleep_seconds = min(chunk_sleep_seconds, 0.02)

    connect_id = str(uuid4())
    session_id = str(uuid4())
    headers = _volcengine_ws_headers(
        app_id=app_id,
        app_key=app_key,
        access_key=access_key,
        resource_id=resource_id,
        connect_id=connect_id,
    )
    ws = websocket.create_connection(
        ws_url,
        header=headers,
        timeout=_REALTIME_BOT_WS_CONNECT_TIMEOUT_SECONDS,
    )
    try:
        if hasattr(ws, "settimeout"):
            ws.settimeout(1)

        ws.send_binary(
            _volcengine_build_request(
                event=_VOLCENGINE_EVENT_START_CONNECTION,
                payload={},
            )
        )
        _ = ws.recv()

        ws.send_binary(
            _volcengine_build_request(
                event=_VOLCENGINE_EVENT_START_SESSION,
                session_id=session_id,
                payload={
                    "asr": {
                        "audio_config": {
                            "channel": 1,
                            "format": "pcm",
                            "sample_rate": _coerce_sample_rate(audio_sample_rate, 16000),
                        },
                        "extra": {"end_smooth_window_ms": 1200},
                    },
                    "tts": {
                        "audio_config": {
                            "channel": 1,
                            "format": "pcm",
                            "sample_rate": 24000,
                        },
                        "speaker": speaker,
                    },
                    "dialog": {
                        "bot_name": bot_name,
                        "dialog_id": session_id,
                        "extra": {
                            "strict_audit": True,
                            "recv_timeout": _REALTIME_BOT_RESPONSE_TIMEOUT_SECONDS,
                            "input_mod": normalized_input_mode,
                            "model": dialog_model,
                        },
                    },
                    "user": {"uid": uid},
                },
            )
        )
        _ = ws.recv()

        for audio_chunk in _iter_audio_chunks(audio_pcm16, chunk_size=chunk_bytes):
            ws.send_binary(
                _volcengine_build_audio_request(
                    event=_VOLCENGINE_EVENT_AUDIO_REQUEST,
                    session_id=session_id,
                    audio_payload=audio_chunk,
                )
            )
            if chunk_sleep_seconds > 0:
                time.sleep(chunk_sleep_seconds)

        if normalized_input_mode == "push_to_talk":
            ws.send_binary(
                _volcengine_build_request(
                    event=_VOLCENGINE_EVENT_END_ASR,
                    session_id=session_id,
                    payload={},
                )
            )
        elif normalized_input_mode in {"keep_alive", "mic_silence"}:
            for _ in range(6):
                ws.send_binary(
                    _volcengine_build_audio_request(
                        event=_VOLCENGINE_EVENT_AUDIO_REQUEST,
                        session_id=session_id,
                        audio_payload=b"\x00" * chunk_bytes,
                    )
                )
                if chunk_sleep_seconds > 0:
                    time.sleep(chunk_sleep_seconds)

        if normalized_input_mode == "audio_file":
            ws.send_binary(
                _volcengine_build_request(
                    event=_VOLCENGINE_EVENT_END_ASR,
                    session_id=session_id,
                    payload={},
                )
            )

        text_chunks: list[str] = []
        audio_pcm_bytes = bytearray()
        audio_mime = "audio/wav" if request_audio else ""
        text_done = False
        audio_done = not request_audio
        ack_audio_chunks = 0
        event_audio_chunks = 0
        deadline = time.time() + max(_REALTIME_BOT_RESPONSE_TIMEOUT_SECONDS, 12)
        timeout_error = getattr(websocket, "WebSocketTimeoutException", Exception)
        while time.time() < deadline:
            try:
                raw = ws.recv()
            except timeout_error:
                continue
            if not raw:
                continue
            event = _volcengine_parse_ws_response(raw)
            if event is None:
                continue
            if "code" in event:
                detail = event.get("payload_msg") or event.get("code") or event
                raise RuntimeError(f"volcengine realtime ws error: {detail}")

            event_code = int(event.get("event") or 0)
            payload_msg = event.get("payload_msg")
            message_type = str(event.get("message_type") or "").strip().upper()

            if request_audio and message_type == "SERVER_ACK":
                audio_chunk = _volcengine_extract_tts_pcm16_bytes(payload_msg)
                if audio_chunk:
                    audio_pcm_bytes.extend(audio_chunk)
                    ack_audio_chunks += 1

            if event_code in {_VOLCENGINE_EVENT_TEXT_DONE, _VOLCENGINE_EVENT_DIALOG_DONE}:
                text_done = True
            elif event_code == _VOLCENGINE_EVENT_TTS_DONE:
                audio_done = True
            elif event_code == _VOLCENGINE_EVENT_TTS_AUDIO and request_audio:
                audio_chunk = _volcengine_extract_tts_pcm16_bytes(payload_msg)
                # Prefer ACK binary audio stream. Fall back to event chunks only when ACK stream is absent.
                if audio_chunk and ack_audio_chunks == 0:
                    audio_pcm_bytes.extend(audio_chunk)
                    event_audio_chunks += 1

            chunk_text = _extract_text_from_volcengine_ws_event(payload_msg if payload_msg is not None else event)
            if chunk_text and (not text_chunks or chunk_text != text_chunks[-1]):
                text_chunks.append(chunk_text)

            event_name = str(event.get("event_name") or "").strip().lower()
            if event_name in {"chatended", "chat_ended", "response.done", "response.completed", "session.stop"}:
                text_done = True
            if audio_done and (text_done or bool(audio_pcm_bytes)):
                break
            if text_done and audio_done:
                break

        text = "".join(part for part in text_chunks if part.strip()).strip()
        audio_base64 = ""
        if request_audio and audio_pcm_bytes:
            audio_base64 = _pcm16le_to_wav_base64(bytes(audio_pcm_bytes), sample_rate=24000, channels=1)
            if not audio_base64:
                audio_mime = ""
        text = _normalized_realtime_reply_text(text, audio_base64=audio_base64)
        if not text:
            raise RuntimeError(
                "volcengine realtime ws did not return text output "
                f"(audio_bytes={len(audio_pcm_bytes)}, text_chunks={len(text_chunks)}, "
                f"text_done={int(text_done)}, audio_done={int(audio_done)}, "
                f"ack_chunks={ack_audio_chunks}, event_chunks={event_audio_chunks})"
            )
        if request_audio and not audio_base64:
            audio_mime = ""
        return text, audio_base64, audio_mime
    finally:
        try:
            ws.send_binary(
                _volcengine_build_request(
                    event=_VOLCENGINE_EVENT_FINISH_SESSION,
                    session_id=session_id,
                    payload={},
                )
            )
        except Exception:
            pass
        try:
            ws.send_binary(
                _volcengine_build_request(
                    event=_VOLCENGINE_EVENT_FINISH_CONNECTION,
                    payload={},
                )
            )
        except Exception:
            pass
        try:
            ws.close()
        except Exception:
            pass


def _call_realtime_bot_via_volcengine_websocket(
    *,
    meeting,
    prompt: str,
    request_audio: bool,
) -> tuple[str, str, str]:
    ws_url = _normalized_realtime_volc_ws_url(getattr(meeting, "realtime_bot_volc_ws_url", ""))
    app_id = (getattr(meeting, "realtime_bot_volc_app_id", "") or "").strip()
    app_id = _meeting_realtime_bot_volc_app_id(meeting)
    app_key = _meeting_realtime_bot_volc_app_key(meeting)
    access_key = _meeting_realtime_bot_volc_access_key(meeting)
    resource_id = _normalized_realtime_volc_resource_id(getattr(meeting, "realtime_bot_volc_resource_id", ""))
    uid = _meeting_realtime_bot_volc_uid(meeting)
    dialog_model = _meeting_realtime_bot_volc_model(meeting)
    speaker = _meeting_realtime_bot_volc_speaker(meeting, dialog_model=dialog_model)
    if not app_id:
        raise RuntimeError("Volcengine App ID is empty")
    if not access_key:
        raise RuntimeError("Volcengine Access Key is empty")
    if not resource_id:
        raise RuntimeError("Volcengine Resource ID is empty")

    try:
        return _call_realtime_bot_via_volcengine_dialog_websocket(
            ws_url=ws_url,
            app_id=app_id,
            app_key=app_key,
            access_key=access_key,
            resource_id=resource_id,
            uid=uid,
            prompt=prompt,
            bot_name=_meeting_realtime_bot_display_name(meeting),
            speaker=speaker,
            dialog_model=dialog_model,
            request_audio=request_audio,
        )
    except Exception as exc:
        raise RuntimeError(f"volcengine websocket={exc}") from exc


def _call_realtime_bot_via_volcengine_audio_websocket(
    *,
    meeting,
    audio_pcm16: bytes,
    audio_sample_rate: int,
    request_audio: bool,
) -> tuple[str, str, str]:
    ws_url = _normalized_realtime_volc_ws_url(getattr(meeting, "realtime_bot_volc_ws_url", ""))
    app_id = _meeting_realtime_bot_volc_app_id(meeting)
    app_key = _meeting_realtime_bot_volc_app_key(meeting)
    access_key = _meeting_realtime_bot_volc_access_key(meeting)
    resource_id = _normalized_realtime_volc_resource_id(getattr(meeting, "realtime_bot_volc_resource_id", ""))
    uid = _meeting_realtime_bot_volc_uid(meeting)
    dialog_model = _meeting_realtime_bot_volc_model(meeting)
    speaker = _meeting_realtime_bot_volc_speaker(meeting, dialog_model=dialog_model)
    if not app_id:
        raise RuntimeError("Volcengine App ID is empty")
    if not access_key:
        raise RuntimeError("Volcengine Access Key is empty")
    if not resource_id:
        raise RuntimeError("Volcengine Resource ID is empty")

    try:
        return _call_realtime_bot_via_volcengine_audio_dialog_websocket(
            ws_url=ws_url,
            app_id=app_id,
            app_key=app_key,
            access_key=access_key,
            resource_id=resource_id,
            uid=uid,
            audio_pcm16=audio_pcm16,
            audio_sample_rate=audio_sample_rate,
            bot_name=_meeting_realtime_bot_display_name(meeting),
            speaker=speaker,
            dialog_model=dialog_model,
            input_mode=_REALTIME_BOT_DEFAULT_VOLC_AUDIO_INPUT_MODE,
            audio_chunk_bytes=_REALTIME_BOT_VOLC_AUDIO_CHUNK_BYTES,
            audio_chunk_sleep_seconds=_REALTIME_BOT_VOLC_AUDIO_CHUNK_SLEEP_SECONDS,
            request_audio=request_audio,
        )
    except Exception as exc:
        raise RuntimeError(f"volcengine websocket={exc}") from exc


def _call_realtime_bot(
    *,
    meeting,
    prompt: str,
) -> tuple[str, str, str]:
    provider = _meeting_realtime_bot_provider(meeting)
    request_audio = not bool(meeting.realtime_bot_muted)

    if provider == RealtimeBotProvider.VOLCENGINE:
        return _call_realtime_bot_via_volcengine_websocket(
            meeting=meeting,
            prompt=prompt,
            request_audio=request_audio,
        )

    base_url = _normalized_realtime_base_url(meeting.realtime_bot_base_url)
    model = _meeting_realtime_bot_openai_model(meeting)
    api_key = _meeting_realtime_bot_api_key(meeting)
    voice = _meeting_realtime_bot_openai_voice(meeting)
    if not api_key:
        raise RuntimeError("Realtime bot API key is empty")

    try:
        return _call_realtime_bot_via_openai_websocket(
            base_url=base_url,
            model=model,
            api_key=api_key,
            voice=voice,
            prompt=prompt,
            request_audio=request_audio,
        )
    except Exception as exc:
        raise RuntimeError(f"openai websocket={exc}") from exc


def _call_realtime_bot_with_audio(
    *,
    meeting,
    audio_pcm16: bytes,
    audio_sample_rate: int = 16000,
) -> tuple[str, str, str]:
    provider = _meeting_realtime_bot_provider(meeting)
    request_audio = not bool(meeting.realtime_bot_muted)
    if provider == RealtimeBotProvider.VOLCENGINE:
        return _call_realtime_bot_via_volcengine_audio_websocket(
            meeting=meeting,
            audio_pcm16=audio_pcm16,
            audio_sample_rate=audio_sample_rate,
            request_audio=request_audio,
        )

    base_url = _normalized_realtime_base_url(meeting.realtime_bot_base_url)
    model = _meeting_realtime_bot_openai_model(meeting)
    api_key = (meeting.realtime_bot_api_key or "").strip()
    voice = _meeting_realtime_bot_openai_voice(meeting)
    if not api_key:
        raise RuntimeError("Realtime bot API key is empty")
    try:
        return _call_realtime_bot_via_openai_audio_websocket(
            base_url=base_url,
            model=model,
            api_key=api_key,
            voice=voice,
            audio_pcm16=audio_pcm16,
            input_sample_rate=audio_sample_rate,
            request_audio=request_audio,
        )
    except Exception as exc:
        raise RuntimeError(f"openai websocket={exc}") from exc


def _message_mentions_realtime_bot(meeting, content: str) -> bool:
    text = (content or "").replace("＠", "@")
    if "@" not in text:
        return False
    display_name = _meeting_realtime_bot_display_name(meeting)
    lower_text = text.lower()
    lower_display_name = display_name.lower()
    tokens = {
        "@ai",
        "@assistant",
        "@realtime",
        "@实时语音",
        "@实时语音助手",
        "@它",
        f"@{lower_display_name}",
    }
    return any(token in lower_text for token in tokens if token.strip())


def _build_realtime_bot_prompt(meeting, message: MeetingMessage) -> str:
    bot_display_name = _meeting_realtime_bot_display_name(meeting)
    sender_name = _fallback_display_name(message.sender_user)
    normalized_content = (message.content or "").replace("＠", "@")
    mention_pattern = rf"@{re.escape(bot_display_name)}|@ai|@assistant|@realtime|@实时语音|@实时语音助手"
    clean_content = re.sub(mention_pattern, "", normalized_content, flags=re.IGNORECASE).strip()
    if not clean_content:
        clean_content = normalized_content.strip()
    return (
        f"你是在线会议中的实时语音成员“{bot_display_name}”。"
        "请用中文简洁回复，控制在120字以内。"
        f"发言人：{sender_name}。"
        f"发言内容：{clean_content}"
    )


def _realtime_bot_reply_worker(
    *,
    meeting_id: int,
    trigger_message_id: int,
):
    close_old_connections()
    try:
        meeting = Meeting.objects.filter(id=meeting_id).first()
        if not meeting or not _meeting_realtime_bot_ready(meeting):
            return
        trigger_message = (
            MeetingMessage.objects.filter(id=trigger_message_id, meeting=meeting)
            .select_related("sender_user")
            .first()
        )
        if not trigger_message:
            return

        bot_user = _realtime_bot_system_user()
        if trigger_message.sender_user_id == bot_user.id:
            return

        prompt = _build_realtime_bot_prompt(meeting, trigger_message)
        reply_text, reply_audio_base64, reply_audio_mime = _call_realtime_bot(
            meeting=meeting,
            prompt=prompt,
        )
        content = (reply_text or "").strip()
        if not content:
            return
        content = content[:2000]
        MeetingMessage.objects.create(
            meeting=meeting,
            sender_user=bot_user,
            sender_display_name_override=_meeting_realtime_bot_display_name(meeting),
            is_realtime_bot=True,
            audio_mime_type=(reply_audio_mime or "").strip()[:120],
            audio_base64=(reply_audio_base64 or "").strip(),
            content=content,
        )
        log_audit(
            user=bot_user,
            action="meeting.realtime_bot_reply",
            resource_type="meeting",
            resource_id=meeting.id,
            detail=f"trigger_message_id={trigger_message_id}",
        )
    except Exception as exc:
        try:
            fallback_meeting = Meeting.objects.filter(id=meeting_id).first()
            if fallback_meeting:
                MeetingMessage.objects.create(
                    meeting=fallback_meeting,
                    sender_user=_realtime_bot_system_user(),
                    sender_display_name_override=_meeting_realtime_bot_display_name(fallback_meeting),
                    is_realtime_bot=True,
                    content="实时语音助手暂时不可用，请稍后再试。",
                )
        except Exception:
            pass
        log_audit(
            action="meeting.realtime_bot_reply_failed",
            resource_type="meeting",
            resource_id=meeting_id,
            detail=f"trigger_message_id={trigger_message_id}, error={exc}",
        )
    finally:
        close_old_connections()


def _maybe_trigger_realtime_bot_reply(meeting, message: MeetingMessage):
    if not _meeting_realtime_bot_ready(meeting):
        return
    if not _message_mentions_realtime_bot(meeting, message.content):
        return
    worker = threading.Thread(
        target=_realtime_bot_reply_worker,
        kwargs={
            "meeting_id": meeting.id,
            "trigger_message_id": message.id,
        },
        daemon=True,
    )
    worker.start()


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
_PUBLIC_GUEST_IDENTITY_SESSION_KEY_PREFIX = "public_guest_identity:"


def _public_guest_identity_session_key(meeting) -> str:
    return f"{_PUBLIC_GUEST_IDENTITY_SESSION_KEY_PREFIX}{meeting.id}"


def _store_public_guest_identity_in_session(request, meeting, participant_identity: str) -> None:
    identity = (participant_identity or "").strip()
    if not identity:
        return
    try:
        request.session[_public_guest_identity_session_key(meeting)] = identity
        request.session.modified = True
    except Exception:
        # Session persistence is best effort for anonymous guest clients.
        return


def _public_guest_identity_from_session(request, meeting) -> str:
    try:
        return (
            request.session.get(_public_guest_identity_session_key(meeting), "")
            or ""
        ).strip()
    except Exception:
        return ""


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
_DISPLAY_NAME_METADATA_KEY = "meeting_display_name"
_DISPLAY_NAME_VERSION_METADATA_KEY = "meeting_display_name_version"


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


def _sync_participant_display_name_metadata(
    meeting,
    participant_identity: str,
    *,
    display_name: str,
    display_name_version: int,
) -> None:
    identity = (participant_identity or "").strip()
    normalized_name = (display_name or "").strip()[:80]
    if not identity or not normalized_name:
        return
    version = max(1, int(display_name_version or 1))
    payload = _participant_metadata_map(meeting, identity)
    payload[_DISPLAY_NAME_METADATA_KEY] = normalized_name
    payload[_DISPLAY_NAME_VERSION_METADATA_KEY] = version
    try:
        livekit_service.update_participant_metadata(
            meeting.room_name,
            identity,
            metadata=json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        )
    except Exception:
        pass


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
            "meeting_id": meeting.id,
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
    _maybe_trigger_realtime_bot_reply(meeting, msg)
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
    _store_public_guest_identity_in_session(request, meeting, participant_identity)
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
@permission_classes([AllowAny])
def public_meeting_my_display_name(request, share_code: str):
    meeting = _meeting_by_share_code(share_code)
    if not meeting:
        return Response({"detail": "Meeting not found"}, status=status.HTTP_404_NOT_FOUND)
    if request.user.is_authenticated:
        return _my_meeting_display_name_impl(request, meeting)

    participant_identity = _public_guest_identity_from_session(request, meeting)
    if not participant_identity:
        return Response(
            {"detail": "Join meeting first before updating display name"},
            status=status.HTTP_403_FORBIDDEN,
        )
    if _user_id_from_participant_identity(participant_identity) is not None:
        return Response(
            {"detail": "Registered members should use private display-name API"},
            status=status.HTTP_400_BAD_REQUEST,
        )

    serializer = MeetingDisplayNameUpdateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    next_display_name = serializer.validated_data["display_name"].strip()
    expected_display_name_version = serializer.validated_data.get(
        "expected_display_name_version"
    )
    guest, conflict = _update_guest_display_name_consistently(
        meeting,
        participant_identity,
        next_display_name=next_display_name,
        expected_display_name_version=expected_display_name_version,
    )
    if conflict is not None:
        return _display_name_conflict_response(
            current_display_name=conflict.display_name,
            current_display_name_version=conflict.display_name_version,
        )
    try:
        livekit_service.update_participant_name(
            meeting.room_name,
            participant_identity,
            name=guest.display_name,
        )
    except Exception:
        pass
    _sync_participant_display_name_metadata(
        meeting,
        participant_identity,
        display_name=guest.display_name,
        display_name_version=guest.display_name_version,
    )
    log_audit(
        action="meeting.public_guest_display_name_update",
        resource_type="meeting",
        resource_id=meeting.id,
        detail=(
            f"participant_identity={participant_identity}, "
            f"display_name={guest.display_name}, "
            f"display_name_version={guest.display_name_version}, "
            f"share={share_code}"
        ),
        ip_address=client_ip(request),
    )
    return Response(
        {
            "display_name": guest.display_name,
            "display_name_version": guest.display_name_version,
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
    identity = _stable_participant_identity(request.user)
    try:
        livekit_service.update_participant_name(
            meeting.room_name,
            identity,
            name=membership.display_name,
        )
    except Exception:
        pass
    _sync_participant_display_name_metadata(
        meeting,
        identity,
        display_name=membership.display_name,
        display_name_version=membership.display_name_version,
    )
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


def _meeting_member_control_impl(request, meeting, target_user_id: int, action: str, resource_id_for_log: int):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    target = MeetingMember.objects.filter(meeting=meeting, user_id=target_user_id).select_related("user").first()
    if not target:
        return Response({"detail": "Member not found"}, status=status.HTTP_404_NOT_FOUND)

    if action == "role":
        if not can_change_roles(request.user, actor_membership):
            return Response({"detail": "Only host/cohost can change role"}, status=status.HTTP_403_FORBIDDEN)
        serializer = MeetingRoleUpdateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        next_role = serializer.validated_data["role"]
        if next_role == MeetingRole.HOST and not request.user.is_superuser:
            return Response({"detail": "Only admin can assign host role"}, status=status.HTTP_403_FORBIDDEN)
        if target.role == MeetingRole.HOST and next_role != MeetingRole.HOST and not request.user.is_superuser:
            return Response({"detail": "Host role cannot be changed by non-admin"}, status=status.HTTP_403_FORBIDDEN)
        if target.user_id == request.user.id and not request.user.is_superuser:
            return Response({"detail": "Cannot change your own role"}, status=status.HTTP_400_BAD_REQUEST)
        if target.role != next_role:
            target.role = next_role
            target.save(update_fields=["role"])
            try:
                _sync_livekit_permissions_for_member(meeting, target)
            except Exception:
                pass
        log_audit(
            user=request.user,
            action="meeting.member_role_update",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"target_user_id={target_user_id}, role={target.role}",
            ip_address=client_ip(request),
        )
        return Response(MeetingMemberSerializer(target, context={"meeting": meeting}).data)

    if action == "mute":
        if not can_moderate(request.user, actor_membership):
            return Response({"detail": "Only host/cohost can mute members"}, status=status.HTTP_403_FORBIDDEN)
        if target.role == MeetingRole.HOST and not request.user.is_superuser:
            return Response({"detail": "Host cannot be muted by non-admin"}, status=status.HTTP_403_FORBIDDEN)
        serializer = MeetingMuteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        next_muted = serializer.validated_data["muted"]
        if not next_muted and not _member_can_self_unmute(meeting, target):
            return Response(
                {"detail": "Member has no microphone permission. Allow mic first."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        target.muted_by_host = next_muted
        update_fields = ["muted_by_host"]
        if not next_muted and target.mic_request_pending:
            target.mic_request_pending = False
            update_fields.append("mic_request_pending")
        target.save(update_fields=update_fields)
        try:
            _sync_livekit_permissions_for_member(
                meeting,
                target,
                force_unmute_microphone=not target.muted_by_host,
            )
            if not next_muted:
                _request_participant_device_open(
                    meeting,
                    _stable_participant_identity(target.user),
                    open_microphone=True,
                )
        except Exception:
            pass
        log_audit(
            user=request.user,
            action="meeting.member_mute",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"target_user_id={target_user_id}, muted={target.muted_by_host}",
            ip_address=client_ip(request),
        )
        return Response(MeetingMemberSerializer(target, context={"meeting": meeting}).data)

    if action == "video":
        if not can_moderate(request.user, actor_membership):
            return Response({"detail": "Only host/cohost can control member video"}, status=status.HTTP_403_FORBIDDEN)
        if target.role == MeetingRole.HOST and not request.user.is_superuser:
            return Response({"detail": "Host video cannot be controlled by non-admin"}, status=status.HTTP_403_FORBIDDEN)
        serializer = MeetingVideoControlSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        disabled = serializer.validated_data["disabled"]
        if not disabled and not _member_can_video(meeting, target):
            return Response(
                {"detail": "Member has no camera permission. Allow video first."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        target.video_blocked_by_host = disabled
        update_fields = ["video_blocked_by_host"]
        if not disabled and target.video_request_pending:
            target.video_request_pending = False
            update_fields.append("video_request_pending")
        target.save(update_fields=update_fields)
        try:
            _sync_livekit_permissions_for_member(
                meeting,
                target,
                force_unmute_camera=not disabled,
            )
            if not disabled:
                _request_participant_device_open(
                    meeting,
                    _stable_participant_identity(target.user),
                    open_camera=True,
                )
        except Exception:
            pass
        log_audit(
            user=request.user,
            action="meeting.member_video_control",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"target_user_id={target_user_id}, disabled={disabled}",
            ip_address=client_ip(request),
        )
        return Response(MeetingMemberSerializer(target, context={"meeting": meeting}).data)

    if action in {"mic_permission", "video_permission", "chat_permission", "screen_share_permission"}:
        if not can_moderate(request.user, actor_membership):
            return Response(
                {"detail": "Only host/cohost can update member permissions"},
                status=status.HTTP_403_FORBIDDEN,
            )
        if target.role == MeetingRole.HOST and not request.user.is_superuser:
            return Response(
                {"detail": "Host member permission cannot be changed by non-admin"},
                status=status.HTTP_403_FORBIDDEN,
            )
        serializer = MeetingPermissionControlSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        allowed = serializer.validated_data["allowed"]

        update_fields: list[str] = []
        action_name = ""
        if action == "mic_permission":
            target.allow_self_unmute_override = allowed
            update_fields.append("allow_self_unmute_override")
            if not allowed and not target.muted_by_host:
                target.muted_by_host = True
                update_fields.append("muted_by_host")
            if allowed and target.mic_request_pending:
                target.mic_request_pending = False
                update_fields.append("mic_request_pending")
            action_name = "meeting.member_mic_permission"
        elif action == "video_permission":
            target.allow_member_video_override = allowed
            update_fields.append("allow_member_video_override")
            if not allowed and not target.video_blocked_by_host:
                target.video_blocked_by_host = True
                update_fields.append("video_blocked_by_host")
            if allowed and target.video_request_pending:
                target.video_request_pending = False
                update_fields.append("video_request_pending")
            action_name = "meeting.member_video_permission"
        elif action == "chat_permission":
            target.allow_chat_override = allowed
            update_fields.append("allow_chat_override")
            action_name = "meeting.member_chat_permission"
        else:
            target.allow_screen_share_override = allowed
            update_fields.append("allow_screen_share_override")
            action_name = "meeting.member_screen_share_permission"

        if update_fields:
            target.save(update_fields=update_fields)

        try:
            _sync_livekit_permissions_for_member(meeting, target)
            if action == "screen_share_permission" and not allowed:
                identity = _stable_participant_identity(target.user)
                livekit_service.mute_participant_track_sources(
                    meeting.room_name,
                    identity,
                    track_sources=["screen_share", "screen_share_audio"],
                    muted=True,
                )
        except Exception:
            pass

        log_audit(
            user=request.user,
            action=action_name,
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"target_user_id={target_user_id}, allowed={allowed}",
            ip_address=client_ip(request),
        )
        return Response(MeetingMemberSerializer(target, context={"meeting": meeting}).data)

    if action == "display_name":
        if not can_moderate(request.user, actor_membership):
            return Response({"detail": "Only host/cohost can rename members"}, status=status.HTTP_403_FORBIDDEN)
        serializer = MeetingMemberDisplayNameControlSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        next_display_name = serializer.validated_data["display_name"].strip()
        expected_display_name_version = serializer.validated_data.get(
            "expected_display_name_version"
        )
        target, conflict = _update_member_display_name_consistently(
            meeting,
            target.id,
            next_display_name=next_display_name,
            expected_display_name_version=expected_display_name_version,
        )
        if conflict is not None:
            return _display_name_conflict_response(
                current_display_name=conflict.display_name,
                current_display_name_version=conflict.display_name_version,
            )
        if target is None:
            return Response({"detail": "Member not found"}, status=status.HTTP_404_NOT_FOUND)
        identity = _stable_participant_identity(target.user)
        try:
            livekit_service.update_participant_name(
                meeting.room_name,
                identity,
                name=target.display_name,
            )
        except Exception:
            pass
        _sync_participant_display_name_metadata(
            meeting,
            identity,
            display_name=target.display_name,
            display_name_version=target.display_name_version,
        )
        log_audit(
            user=request.user,
            action="meeting.member_display_name_control",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=(
                f"target_user_id={target_user_id}, "
                f"display_name={target.display_name}, "
                f"display_name_version={target.display_name_version}"
            ),
            ip_address=client_ip(request),
        )
        return Response(MeetingMemberSerializer(target, context={"meeting": meeting}).data)

    if action == "stop_share":
        if not can_moderate(request.user, actor_membership):
            return Response({"detail": "Only host/cohost can stop screen share"}, status=status.HTTP_403_FORBIDDEN)
        identity = _stable_participant_identity(target.user)
        try:
            livekit_service.mute_participant_track_sources(
                meeting.room_name,
                identity,
                track_sources=["screen_share", "screen_share_audio"],
                muted=True,
            )
        except Exception:
            pass
        log_audit(
            user=request.user,
            action="meeting.member_stop_share",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"target_user_id={target_user_id}",
            ip_address=client_ip(request),
        )
        return Response(MeetingMemberSerializer(target, context={"meeting": meeting}).data)

    if action == "remove":
        if not can_moderate(request.user, actor_membership):
            return Response({"detail": "Only host/cohost can remove members"}, status=status.HTTP_403_FORBIDDEN)
        if target.role == MeetingRole.HOST and not request.user.is_superuser:
            return Response({"detail": "Host cannot be removed by non-admin"}, status=status.HTTP_403_FORBIDDEN)
        ban_after_remove = _bool_value(request.query_params.get("ban", "1"), default=True)
        reason = (request.query_params.get("reason") or "").strip()[:200]
        target_user = target.user
        target_identity = _stable_participant_identity(target_user)
        target.delete()
        if ban_after_remove:
            MeetingBlockedMember.objects.update_or_create(
                meeting=meeting,
                user=target_user,
                defaults={
                    "blocked_by": request.user,
                    "reason": reason or "removed_by_moderator",
                },
            )
            _mark_waiting_room_status(
                meeting,
                target_user,
                WaitingRoomStatus.REJECTED,
                reviewed_by=request.user,
            )
        try:
            livekit_service.remove_participant(meeting.room_name, target_identity)
        except Exception:
            pass
        log_audit(
            user=request.user,
            action="meeting.member_remove",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"target_user_id={target_user_id}, banned={ban_after_remove}",
            ip_address=client_ip(request),
        )
        return Response({"ok": True, "banned": ban_after_remove})

    return Response({"detail": "Unsupported action"}, status=status.HTTP_400_BAD_REQUEST)


def _meeting_participant_control(request, meeting_id: int, participant_identity: str, action: str):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_participant_control_impl(
        request,
        meeting,
        participant_identity,
        action,
        meeting_id,
    )


def _meeting_realtime_bot_participant_control_impl(
    request,
    meeting,
    *,
    action: str,
    resource_id_for_log: int,
):
    if action == "detail":
        return Response(
            {
                "ok": True,
                "identity": _meeting_realtime_bot_identity(meeting),
                "display_name": _meeting_realtime_bot_display_name(meeting),
                "display_name_version": 1,
                "muted": bool(meeting.realtime_bot_muted),
                "is_realtime_bot": True,
            }
        )

    if action == "mute":
        serializer = MeetingMuteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        muted = serializer.validated_data["muted"]
        if meeting.realtime_bot_muted != muted:
            meeting.realtime_bot_muted = muted
            meeting.save(update_fields=["realtime_bot_muted"])
        log_audit(
            user=request.user,
            action="meeting.realtime_bot_mute",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"muted={muted}",
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": True,
                "identity": _meeting_realtime_bot_identity(meeting),
                "muted": muted,
                "is_realtime_bot": True,
            }
        )

    if action == "display_name":
        serializer = MeetingMemberDisplayNameControlSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        display_name = serializer.validated_data["display_name"].strip()
        if not display_name:
            return Response({"detail": "display_name is required"}, status=status.HTTP_400_BAD_REQUEST)
        if meeting.realtime_bot_display_name != display_name:
            meeting.realtime_bot_display_name = display_name
            meeting.save(update_fields=["realtime_bot_display_name"])
            _sync_realtime_bot_presence(meeting)
        return Response(
            {
                "ok": True,
                "identity": _meeting_realtime_bot_identity(meeting),
                "display_name": _meeting_realtime_bot_display_name(meeting),
                "display_name_version": 1,
                "is_realtime_bot": True,
            }
        )

    if action in {"remove"}:
        if meeting.realtime_bot_enabled:
            meeting.realtime_bot_enabled = False
            meeting.save(update_fields=["realtime_bot_enabled"])
            _sync_realtime_bot_presence(meeting)
        log_audit(
            user=request.user,
            action="meeting.realtime_bot_disable",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": True,
                "identity": _meeting_realtime_bot_identity(meeting),
                "banned": False,
                "is_realtime_bot": True,
            }
        )

    return Response({"detail": "Unsupported action for realtime bot participant"}, status=status.HTTP_400_BAD_REQUEST)


def _meeting_participant_control_impl(
    request,
    meeting,
    participant_identity: str,
    action: str,
    resource_id_for_log: int,
):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response(
            {"detail": "Only host/cohost can manage participants"},
            status=status.HTTP_403_FORBIDDEN,
        )

    identity = (participant_identity or "").strip()
    if not identity:
        return Response({"detail": "Participant identity is required"}, status=status.HTTP_400_BAD_REQUEST)
    if identity == _meeting_realtime_bot_identity(meeting):
        return _meeting_realtime_bot_participant_control_impl(
            request,
            meeting,
            action=action,
            resource_id_for_log=resource_id_for_log,
        )
    if _user_id_from_participant_identity(identity) is not None:
        return Response(
            {"detail": "Registered members should be managed by member id"},
            status=status.HTTP_400_BAD_REQUEST,
        )

    def _guest_permission_payload(publish_sources: Iterable[str], can_publish_data: bool):
        source_set = set(publish_sources)
        return {
            "allow_self_unmute": "microphone" in source_set,
            "allow_member_video": "camera" in source_set,
            "allow_screen_share": "screen_share" in source_set or "screen_share_audio" in source_set,
            "allow_chat": bool(can_publish_data),
        }

    if action == "detail":
        livekit_name = _livekit_participant_name(meeting, identity).strip()
        guest = _ensure_guest_participant_record(
            meeting,
            identity,
            fallback_display_name=livekit_name,
        )
        return Response(
            {
                "ok": True,
                "identity": identity,
                "display_name": guest.display_name,
                "display_name_version": guest.display_name_version,
                "livekit_display_name": livekit_name,
            }
        )

    if action == "mute":
        serializer = MeetingMuteSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        muted = serializer.validated_data["muted"]
        sources = _resolved_guest_publish_sources(meeting, identity)
        effective_sources = _effective_guest_publish_sources(meeting, sources)
        effective_source_set = set(effective_sources)
        if not muted and "microphone" not in effective_source_set:
            return Response(
                {"detail": "Participant has no microphone permission. Allow mic first."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        can_publish_data = _resolved_guest_publish_data_allowed(meeting, identity)
        try:
            _sync_livekit_permissions_for_guest_participant(
                meeting,
                identity,
                publish_sources=effective_sources,
                can_publish_data=can_publish_data,
                force_unmute_microphone=not muted,
            )
            if not muted:
                _request_participant_device_open(
                    meeting,
                    identity,
                    open_microphone=True,
                )
            if muted:
                livekit_service.mute_participant_track_sources(
                    meeting.room_name,
                    identity,
                    track_sources=["microphone"],
                    muted=True,
                )
        except Exception:
            pass
        log_audit(
            user=request.user,
            action="meeting.participant_mute",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"participant_identity={identity}, muted={muted}",
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": True,
                "identity": identity,
                "muted": muted,
                **_guest_permission_payload(effective_sources, can_publish_data),
            }
        )

    if action == "video":
        serializer = MeetingVideoControlSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        disabled = serializer.validated_data["disabled"]
        sources = _resolved_guest_publish_sources(meeting, identity)
        effective_sources = _effective_guest_publish_sources(meeting, sources)
        effective_source_set = set(effective_sources)
        if not disabled and "camera" not in effective_source_set:
            return Response(
                {"detail": "Participant has no camera permission. Allow video first."},
                status=status.HTTP_400_BAD_REQUEST,
            )
        can_publish_data = _resolved_guest_publish_data_allowed(meeting, identity)
        try:
            _sync_livekit_permissions_for_guest_participant(
                meeting,
                identity,
                publish_sources=effective_sources,
                can_publish_data=can_publish_data,
                force_unmute_camera=not disabled,
            )
            if not disabled:
                _request_participant_device_open(
                    meeting,
                    identity,
                    open_camera=True,
                )
            if disabled:
                livekit_service.mute_participant_track_sources(
                    meeting.room_name,
                    identity,
                    track_sources=["camera"],
                    muted=True,
                )
        except Exception:
            pass
        log_audit(
            user=request.user,
            action="meeting.participant_video_control",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"participant_identity={identity}, disabled={disabled}",
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": True,
                "identity": identity,
                "disabled": disabled,
                **_guest_permission_payload(effective_sources, can_publish_data),
            }
        )

    if action in {"mic_permission", "video_permission", "chat_permission", "screen_share_permission"}:
        if action == "chat_permission":
            return Response(
                {"detail": "Guest chat permission follows meeting-level controls and cannot be overridden per participant"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        serializer = MeetingPermissionControlSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        allowed = serializer.validated_data["allowed"]
        sources = _resolved_guest_publish_sources(meeting, identity)
        can_publish_data = _resolved_guest_publish_data_allowed(meeting, identity)

        if action == "mic_permission":
            if allowed:
                sources.add("microphone")
            else:
                sources.discard("microphone")
            audit_action = "meeting.participant_mic_permission"
        elif action == "video_permission":
            if allowed:
                sources.add("camera")
            else:
                sources.discard("camera")
            audit_action = "meeting.participant_video_permission"
        elif action == "chat_permission":
            can_publish_data = allowed
            audit_action = "meeting.participant_chat_permission"
        else:
            if allowed:
                sources.update({"screen_share", "screen_share_audio"})
            else:
                sources.discard("screen_share")
                sources.discard("screen_share_audio")
            audit_action = "meeting.participant_screen_share_permission"

        effective_sources = _effective_guest_publish_sources(meeting, sources)
        effective_can_publish_data = bool(can_publish_data and meeting.allow_chat)
        try:
            _sync_livekit_permissions_for_guest_participant(
                meeting,
                identity,
                publish_sources=effective_sources,
                can_publish_data=effective_can_publish_data,
            )
            if action == "screen_share_permission" and not allowed:
                livekit_service.mute_participant_track_sources(
                    meeting.room_name,
                    identity,
                    track_sources=["screen_share", "screen_share_audio"],
                    muted=True,
                )
        except Exception:
            pass
        log_audit(
            user=request.user,
            action=audit_action,
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"participant_identity={identity}, allowed={allowed}",
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": True,
                "identity": identity,
                **_guest_permission_payload(effective_sources, effective_can_publish_data),
            }
        )

    if action == "display_name":
        serializer = MeetingMemberDisplayNameControlSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        next_display_name = serializer.validated_data["display_name"].strip()
        expected_display_name_version = serializer.validated_data.get(
            "expected_display_name_version"
        )
        guest, conflict = _update_guest_display_name_consistently(
            meeting,
            identity,
            next_display_name=next_display_name,
            expected_display_name_version=expected_display_name_version,
        )
        if conflict is not None:
            return _display_name_conflict_response(
                current_display_name=conflict.display_name,
                current_display_name_version=conflict.display_name_version,
            )
        try:
            livekit_service.update_participant_name(
                meeting.room_name,
                identity,
                name=guest.display_name,
            )
        except Exception:
            pass
        _sync_participant_display_name_metadata(
            meeting,
            identity,
            display_name=guest.display_name,
            display_name_version=guest.display_name_version,
        )
        log_audit(
            user=request.user,
            action="meeting.participant_display_name_control",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=(
                f"participant_identity={identity}, "
                f"display_name={guest.display_name}, "
                f"display_name_version={guest.display_name_version}"
            ),
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": True,
                "identity": identity,
                "display_name": guest.display_name,
                "display_name_version": guest.display_name_version,
            }
        )

    if action == "stop_share":
        try:
            livekit_service.mute_participant_track_sources(
                meeting.room_name,
                identity,
                track_sources=["screen_share", "screen_share_audio"],
                muted=True,
            )
        except Exception:
            pass
        log_audit(
            user=request.user,
            action="meeting.participant_stop_share",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"participant_identity={identity}",
            ip_address=client_ip(request),
        )
        return Response({"ok": True, "identity": identity})

    if action == "remove":
        MeetingGuestParticipant.objects.filter(
            meeting=meeting,
            participant_identity=identity,
        ).delete()
        try:
            livekit_service.remove_participant(meeting.room_name, identity)
        except Exception:
            pass
        log_audit(
            user=request.user,
            action="meeting.participant_remove",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"participant_identity={identity}",
            ip_address=client_ip(request),
        )
        return Response({"ok": True, "identity": identity, "banned": False})

    return Response({"detail": "Unsupported action"}, status=status.HTTP_400_BAD_REQUEST)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_role(request, meeting_id: int, target_user_id: int):
    return _meeting_member_control(request, meeting_id, target_user_id, "role")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_mute(request, meeting_id: int, target_user_id: int):
    return _meeting_member_control(request, meeting_id, target_user_id, "mute")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_video(request, meeting_id: int, target_user_id: int):
    return _meeting_member_control(request, meeting_id, target_user_id, "video")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_mic_permission(request, meeting_id: int, target_user_id: int):
    return _meeting_member_control(request, meeting_id, target_user_id, "mic_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_video_permission(request, meeting_id: int, target_user_id: int):
    return _meeting_member_control(request, meeting_id, target_user_id, "video_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_chat_permission(request, meeting_id: int, target_user_id: int):
    return _meeting_member_control(request, meeting_id, target_user_id, "chat_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_screen_share_permission(request, meeting_id: int, target_user_id: int):
    return _meeting_member_control(request, meeting_id, target_user_id, "screen_share_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_display_name_control(request, meeting_id: int, target_user_id: int):
    return _meeting_member_control(request, meeting_id, target_user_id, "display_name")


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_member_stop_share(request, meeting_id: int, target_user_id: int):
    return _meeting_member_control(request, meeting_id, target_user_id, "stop_share")


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def meeting_member_remove(request, meeting_id: int, target_user_id: int):
    return _meeting_member_control(request, meeting_id, target_user_id, "remove")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_mute(request, meeting_id: int, participant_identity: str):
    return _meeting_participant_control(request, meeting_id, participant_identity, "mute")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_video(request, meeting_id: int, participant_identity: str):
    return _meeting_participant_control(request, meeting_id, participant_identity, "video")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_mic_permission(request, meeting_id: int, participant_identity: str):
    return _meeting_participant_control(request, meeting_id, participant_identity, "mic_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_video_permission(request, meeting_id: int, participant_identity: str):
    return _meeting_participant_control(request, meeting_id, participant_identity, "video_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_chat_permission(request, meeting_id: int, participant_identity: str):
    return _meeting_participant_control(request, meeting_id, participant_identity, "chat_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_screen_share_permission(request, meeting_id: int, participant_identity: str):
    return _meeting_participant_control(request, meeting_id, participant_identity, "screen_share_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_display_name_control(request, meeting_id: int, participant_identity: str):
    return _meeting_participant_control(request, meeting_id, participant_identity, "display_name")


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_participant_stop_share(request, meeting_id: int, participant_identity: str):
    return _meeting_participant_control(request, meeting_id, participant_identity, "stop_share")


@api_view(["GET", "DELETE"])
@permission_classes([IsAuthenticated])
def meeting_participant_remove(request, meeting_id: int, participant_identity: str):
    action = "detail" if request.method == "GET" else "remove"
    return _meeting_participant_control(request, meeting_id, participant_identity, action)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_role_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_member_control_impl(request, meeting, target_user_id, "role", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_mute_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_member_control_impl(request, meeting, target_user_id, "mute", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_video_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_member_control_impl(request, meeting, target_user_id, "video", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_mic_permission_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_member_control_impl(request, meeting, target_user_id, "mic_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_video_permission_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_member_control_impl(request, meeting, target_user_id, "video_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_chat_permission_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_member_control_impl(request, meeting, target_user_id, "chat_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_screen_share_permission_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_member_control_impl(request, meeting, target_user_id, "screen_share_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_display_name_control_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_member_control_impl(request, meeting, target_user_id, "display_name", meeting.id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_member_stop_share_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_member_control_impl(request, meeting, target_user_id, "stop_share", meeting.id)


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def meeting_member_remove_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_member_control_impl(request, meeting, target_user_id, "remove", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_mute_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_participant_control_impl(request, meeting, participant_identity, "mute", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_video_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_participant_control_impl(request, meeting, participant_identity, "video", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_mic_permission_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_participant_control_impl(request, meeting, participant_identity, "mic_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_video_permission_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_participant_control_impl(request, meeting, participant_identity, "video_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_chat_permission_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_participant_control_impl(request, meeting, participant_identity, "chat_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_screen_share_permission_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_participant_control_impl(
        request,
        meeting,
        participant_identity,
        "screen_share_permission",
        meeting.id,
    )


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_display_name_control_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_participant_control_impl(request, meeting, participant_identity, "display_name", meeting.id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_participant_stop_share_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_participant_control_impl(request, meeting, participant_identity, "stop_share", meeting.id)


@api_view(["GET", "DELETE"])
@permission_classes([IsAuthenticated])
def meeting_participant_remove_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    action = "detail" if request.method == "GET" else "remove"
    return _meeting_participant_control_impl(request, meeting, participant_identity, action, meeting.id)


def _meeting_host_leave_impl(request, meeting, resource_id_for_log: int):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not actor_membership or actor_membership.role != MeetingRole.HOST:
        return Response({"detail": "Only host can end or transfer meeting"}, status=status.HTTP_403_FORBIDDEN)

    serializer = MeetingHostLeaveSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    transfer_user_id = serializer.validated_data.get("transfer_user_id")
    online_user_ids = _list_registered_participant_user_ids(meeting)

    if transfer_user_id is not None:
        if online_user_ids is None:
            return Response(
                {"detail": "Unable to verify participant presence. Please try again."},
                status=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        if transfer_user_id not in online_user_ids:
            return Response(
                {"detail": "Target user is not currently in meeting"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        target = MeetingMember.objects.filter(meeting=meeting, user_id=transfer_user_id).select_related("user").first()
        if not target:
            return Response({"detail": "Target user not found"}, status=status.HTTP_404_NOT_FOUND)
        if target.user_id == request.user.id:
            return Response({"detail": "Cannot transfer host to yourself"}, status=status.HTTP_400_BAD_REQUEST)
        with transaction.atomic():
            target.role = MeetingRole.HOST
            target.save(update_fields=["role"])
            actor_membership.delete()
            if meeting.owner_id != target.user_id:
                _transfer_meeting_owner_with_session_usage(meeting, new_owner=target.user)
        try:
            _sync_livekit_permissions_for_member(meeting, target)
        except Exception:
            pass
        log_audit(
            user=request.user,
            action="meeting.host_leave_transfer",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"handover_to_user_id={target.user_id}",
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": True,
                "meeting_ended": False,
                "handover_to_user_id": target.user_id,
            }
        )

    next_host = (
        MeetingMember.objects.filter(meeting=meeting, role=MeetingRole.COHOST)
        .exclude(user=request.user)
        .select_related("user")
        .order_by("created_at")
        .first()
    )
    if next_host:
        with transaction.atomic():
            next_host.role = MeetingRole.HOST
            next_host.save(update_fields=["role"])
            actor_membership.delete()
            if meeting.owner_id != next_host.user_id:
                _transfer_meeting_owner_with_session_usage(meeting, new_owner=next_host.user)
        try:
            _sync_livekit_permissions_for_member(meeting, next_host)
        except Exception:
            pass
        log_audit(
            user=request.user,
            action="meeting.host_leave_auto_handover",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"handover_to_user_id={next_host.user_id}",
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": True,
                "meeting_ended": False,
                "handover_to_user_id": next_host.user_id,
                "auto_handover": True,
            }
        )

    room_name = meeting.room_name
    deleted_meeting_id = meeting.id
    _finalize_room_session_if_needed(meeting)
    meeting.delete()
    try:
        livekit_service.delete_room(room_name)
    except Exception:
        pass
    log_audit(
        user=request.user,
        action="meeting.host_leave_end_no_cohost",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"deleted_meeting_id={deleted_meeting_id}, room={room_name}",
        ip_address=client_ip(request),
    )
    return Response(
        {
            "ok": True,
            "meeting_ended": True,
            "deleted_meeting_id": deleted_meeting_id,
        }
    )


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_host_leave(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_host_leave_impl(request, meeting, meeting_id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_host_leave_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_host_leave_impl(request, meeting, meeting.id)


def _meeting_controls_impl(request, meeting, resource_id_for_log: int):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can update meeting controls"}, status=status.HTTP_403_FORBIDDEN)

    serializer = MeetingControlUpdateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    payload = serializer.validated_data
    if not payload:
        return Response(MeetingSerializer(meeting, context={"request": request}).data)

    _apply_meeting_payload(meeting, payload)
    meeting.save(update_fields=list(payload.keys()))
    members = MeetingMember.objects.filter(meeting=meeting).select_related("user")
    _sync_livekit_permissions_for_members(meeting, members)
    _sync_livekit_permissions_for_guest_participants(meeting)
    log_audit(
        user=request.user,
        action="meeting.controls_update",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"fields={','.join(payload.keys())}",
        ip_address=client_ip(request),
    )
    return Response(MeetingSerializer(meeting, context={"request": request}).data)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_controls(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_controls_impl(request, meeting, meeting_id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_controls_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_controls_impl(request, meeting, meeting.id)


def _meeting_ai_controls_impl(request, meeting, resource_id_for_log: int):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can update AI controls"}, status=status.HTTP_403_FORBIDDEN)

    if request.method == "GET":
        _sync_realtime_bot_presence(meeting)
        return Response(MeetingSerializer(meeting, context={"request": request}).data)

    serializer = MeetingRealtimeBotControlSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    payload = serializer.validated_data
    if not payload:
        return Response(MeetingSerializer(meeting, context={"request": request}).data)

    next_provider = _normalized_realtime_provider(
        payload.get("realtime_bot_provider", getattr(meeting, "realtime_bot_provider", ""))
    )
    legacy_model = payload.pop("realtime_bot_model", None)
    legacy_voice = payload.pop("realtime_bot_voice", None)
    if legacy_model is not None:
        if next_provider == RealtimeBotProvider.VOLCENGINE:
            payload.setdefault("realtime_bot_volc_model", legacy_model)
        else:
            payload.setdefault("realtime_bot_openai_model", legacy_model)
    if legacy_voice is not None:
        if next_provider == RealtimeBotProvider.VOLCENGINE:
            payload.setdefault("realtime_bot_volc_voice", legacy_voice)
        else:
            payload.setdefault("realtime_bot_openai_voice", legacy_voice)

    next_enabled = payload.get("realtime_bot_enabled", meeting.realtime_bot_enabled)
    next_key = (payload.get("realtime_bot_api_key", meeting.realtime_bot_api_key) or "").strip()
    next_base_url = _normalized_realtime_base_url(payload.get("realtime_bot_base_url", meeting.realtime_bot_base_url))
    next_openai_model = (
        payload.get("realtime_bot_openai_model", _meeting_realtime_bot_openai_model(meeting)) or ""
    ).strip() or _REALTIME_BOT_DEFAULT_MODEL
    next_openai_voice = (
        payload.get("realtime_bot_openai_voice", _meeting_realtime_bot_openai_voice(meeting)) or ""
    ).strip() or _REALTIME_BOT_DEFAULT_VOICE
    next_volc_model = (
        payload.get("realtime_bot_volc_model", _meeting_realtime_bot_volc_model(meeting)) or ""
    ).strip()
    if next_volc_model not in _VOLCENGINE_ALLOWED_MODELS:
        fallback_volc_model = (_REALTIME_BOT_DEFAULT_VOLC_MODEL or "").strip()
        next_volc_model = (
            fallback_volc_model
            if fallback_volc_model in _VOLCENGINE_ALLOWED_MODELS
            else _VOLCENGINE_MODEL_SC2
        )
    next_volc_voice = (
        payload.get(
            "realtime_bot_volc_voice",
            (getattr(meeting, "realtime_bot_volc_voice", "") or "").strip(),
        )
        or ""
    ).strip()
    next_volc_ws_url = _normalized_realtime_volc_ws_url(
        payload.get("realtime_bot_volc_ws_url", getattr(meeting, "realtime_bot_volc_ws_url", ""))
    )
    next_volc_app_id = (
        payload.get("realtime_bot_volc_app_id", getattr(meeting, "realtime_bot_volc_app_id", "")) or ""
    ).strip()
    next_volc_access_key = (
        payload.get("realtime_bot_volc_access_key", getattr(meeting, "realtime_bot_volc_access_key", "")) or ""
    ).strip()
    next_volc_resource_id = _normalized_realtime_volc_resource_id(
        payload.get(
            "realtime_bot_volc_resource_id",
            getattr(meeting, "realtime_bot_volc_resource_id", ""),
        )
    )
    next_display_name = (
        payload.get("realtime_bot_display_name", meeting.realtime_bot_display_name) or ""
    ).strip() or _REALTIME_BOT_DEFAULT_DISPLAY_NAME
    effective_openai_key = next_key or _REALTIME_BOT_DEFAULT_API_KEY
    effective_volc_app_id = next_volc_app_id or _REALTIME_BOT_DEFAULT_VOLC_APP_ID
    effective_volc_access_key = next_volc_access_key or _REALTIME_BOT_DEFAULT_VOLC_ACCESS_KEY

    payload["realtime_bot_model"] = (
        next_volc_model if next_provider == RealtimeBotProvider.VOLCENGINE else next_openai_model
    )
    payload["realtime_bot_voice"] = (
        next_volc_voice if next_provider == RealtimeBotProvider.VOLCENGINE else next_openai_voice
    )
    if "realtime_bot_openai_model" in payload:
        payload["realtime_bot_openai_model"] = next_openai_model
    if "realtime_bot_openai_voice" in payload:
        payload["realtime_bot_openai_voice"] = next_openai_voice
    if "realtime_bot_volc_model" in payload:
        payload["realtime_bot_volc_model"] = next_volc_model
    if "realtime_bot_volc_voice" in payload:
        payload["realtime_bot_volc_voice"] = next_volc_voice

    if next_provider == RealtimeBotProvider.VOLCENGINE:
        if next_volc_model not in _VOLCENGINE_ALLOWED_MODELS:
            return Response(
                {"detail": "Volcengine model must be one of: 1.2.1.1, 2.2.0.0"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if not next_volc_ws_url:
            return Response({"detail": "Volcengine WebSocket URL cannot be empty"}, status=status.HTTP_400_BAD_REQUEST)
        if not effective_volc_app_id:
            return Response({"detail": "Volcengine App ID cannot be empty"}, status=status.HTTP_400_BAD_REQUEST)
        if not next_volc_resource_id:
            return Response({"detail": "Volcengine Resource ID cannot be empty"}, status=status.HTTP_400_BAD_REQUEST)
        if next_enabled and not effective_volc_access_key:
            return Response(
                {"detail": "Realtime voice is enabled but Volcengine Access Key is empty"},
                status=status.HTTP_400_BAD_REQUEST,
            )
    else:
        if next_enabled and not effective_openai_key:
            return Response(
                {"detail": "Realtime voice is enabled but API key is empty"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if not next_base_url:
            return Response({"detail": "Realtime base URL cannot be empty"}, status=status.HTTP_400_BAD_REQUEST)
        if not next_openai_model:
            return Response({"detail": "Realtime model cannot be empty"}, status=status.HTTP_400_BAD_REQUEST)
        if not next_openai_voice:
            return Response({"detail": "Realtime voice cannot be empty"}, status=status.HTTP_400_BAD_REQUEST)
    if not next_display_name:
        return Response({"detail": "Realtime display name cannot be empty"}, status=status.HTTP_400_BAD_REQUEST)

    _apply_meeting_payload(meeting, payload)
    meeting.save(update_fields=list(payload.keys()))
    _sync_realtime_bot_presence(meeting)
    log_audit(
        user=request.user,
        action="meeting.ai_controls_update",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"fields={','.join(payload.keys())}",
        ip_address=client_ip(request),
    )
    return Response(MeetingSerializer(meeting, context={"request": request}).data)


@api_view(["GET", "PATCH"])
@permission_classes([IsAuthenticated])
def meeting_ai_controls(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_ai_controls_impl(request, meeting, meeting_id)


@api_view(["GET", "PATCH"])
@permission_classes([IsAuthenticated])
def meeting_ai_controls_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_ai_controls_impl(request, meeting, meeting.id)


def _meeting_ai_controls_test_impl(request, meeting, resource_id_for_log: int):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can test AI connectivity"}, status=status.HTTP_403_FORBIDDEN)

    serializer = MeetingRealtimeBotConnectivityTestSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    payload = serializer.validated_data

    provider = _normalized_realtime_provider(payload.get("provider") or meeting.realtime_bot_provider)
    base_url = _normalized_realtime_base_url(payload.get("base_url") or meeting.realtime_bot_base_url)
    raw_model = (payload.get("model") or "").strip()
    raw_voice = (payload.get("voice") or "").strip()
    openai_model = raw_model or _meeting_realtime_bot_openai_model(meeting)
    openai_voice = raw_voice or _meeting_realtime_bot_openai_voice(meeting)
    volc_model = raw_model or _meeting_realtime_bot_volc_model(meeting)
    volc_voice = raw_voice or _meeting_realtime_bot_volc_raw_voice(meeting)
    model = volc_model if provider == RealtimeBotProvider.VOLCENGINE else openai_model
    api_key = (payload.get("api_key") or meeting.realtime_bot_api_key or _REALTIME_BOT_DEFAULT_API_KEY).strip()
    voice = volc_voice if provider == RealtimeBotProvider.VOLCENGINE else openai_voice
    volc_ws_url = _normalized_realtime_volc_ws_url(
        payload.get("volc_ws_url") or getattr(meeting, "realtime_bot_volc_ws_url", "")
    )
    volc_app_id = (
        payload.get("volc_app_id")
        or getattr(meeting, "realtime_bot_volc_app_id", "")
        or _REALTIME_BOT_DEFAULT_VOLC_APP_ID
    ).strip()
    volc_app_key = (
        payload.get("volc_app_key")
        or getattr(meeting, "realtime_bot_volc_app_key", "")
        or _REALTIME_BOT_DEFAULT_VOLC_APP_KEY
    ).strip()
    volc_access_key = (
        payload.get("volc_access_key")
        or getattr(meeting, "realtime_bot_volc_access_key", "")
        or _REALTIME_BOT_DEFAULT_VOLC_ACCESS_KEY
    ).strip()
    volc_resource_id = _normalized_realtime_volc_resource_id(
        payload.get("volc_resource_id") or getattr(meeting, "realtime_bot_volc_resource_id", "")
    )
    volc_uid = (
        payload.get("volc_uid")
        or getattr(meeting, "realtime_bot_volc_uid", "")
        or _REALTIME_BOT_DEFAULT_VOLC_UID
    ).strip()
    if not volc_uid:
        volc_uid = f"meeting-{meeting.id}"
    prompt = (payload.get("prompt") or "请简要回复：连接成功。").strip()
    if provider == RealtimeBotProvider.VOLCENGINE:
        if not volc_app_id:
            return Response({"detail": "Volcengine App ID is required for connectivity test"}, status=status.HTTP_400_BAD_REQUEST)
        if not volc_access_key:
            return Response(
                {"detail": "Volcengine Access Key is required for connectivity test"},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if not volc_resource_id:
            return Response(
                {"detail": "Volcengine Resource ID is required for connectivity test"},
                status=status.HTTP_400_BAD_REQUEST,
            )
    else:
        if not api_key:
            return Response({"detail": "API key is required for connectivity test"}, status=status.HTTP_400_BAD_REQUEST)

    class _RealtimeMeetingConfig:
        pass

    test_meeting = _RealtimeMeetingConfig()
    test_meeting.realtime_bot_provider = provider
    test_meeting.realtime_bot_base_url = base_url
    test_meeting.realtime_bot_openai_model = openai_model
    test_meeting.realtime_bot_openai_voice = openai_voice
    test_meeting.realtime_bot_volc_model = volc_model
    test_meeting.realtime_bot_volc_voice = volc_voice
    test_meeting.realtime_bot_model = model
    test_meeting.realtime_bot_api_key = api_key
    test_meeting.realtime_bot_voice = voice
    test_meeting.realtime_bot_display_name = _meeting_realtime_bot_display_name(meeting)
    test_meeting.realtime_bot_volc_ws_url = volc_ws_url
    test_meeting.realtime_bot_volc_app_id = volc_app_id
    test_meeting.realtime_bot_volc_app_key = volc_app_key
    test_meeting.realtime_bot_volc_access_key = volc_access_key
    test_meeting.realtime_bot_volc_resource_id = volc_resource_id
    test_meeting.realtime_bot_volc_uid = volc_uid
    test_meeting.id = meeting.id
    test_meeting.realtime_bot_muted = True

    started_at = time.time()
    try:
        text, _, _ = _call_realtime_bot(meeting=test_meeting, prompt=prompt)
        latency_ms = int((time.time() - started_at) * 1000)
        log_audit(
            user=request.user,
            action="meeting.ai_controls_test",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"ok=1,latency_ms={latency_ms}",
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": True,
                "latency_ms": latency_ms,
                "preview_text": (text or "").strip()[:200],
            }
        )
    except Exception as exc:
        latency_ms = int((time.time() - started_at) * 1000)
        log_audit(
            user=request.user,
            action="meeting.ai_controls_test",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"ok=0,latency_ms={latency_ms},error={exc}",
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": False,
                "latency_ms": latency_ms,
                "detail": str(exc),
            },
            status=status.HTTP_400_BAD_REQUEST,
        )


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_ai_controls_test(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_ai_controls_test_impl(request, meeting, meeting_id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_ai_controls_test_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_ai_controls_test_impl(request, meeting, meeting.id)


def _meeting_ai_audio_ingress_impl(request, meeting, resource_id_for_log: int):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can send AI realtime audio"}, status=status.HTTP_403_FORBIDDEN)
    if not _meeting_realtime_bot_ready(meeting):
        return Response({"detail": "Realtime bot is not enabled or not configured"}, status=status.HTTP_400_BAD_REQUEST)

    serializer = MeetingRealtimeBotAudioIngressSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    payload = serializer.validated_data
    audio_base64 = (payload.get("audio_base64") or "").strip()
    sample_rate = _coerce_sample_rate(payload.get("sample_rate"), default=16000)
    channels = _coerce_channels(payload.get("channels"), default=1)

    try:
        audio_pcm16 = _decode_and_normalize_pcm16_audio(
            audio_base64=audio_base64,
            sample_rate=sample_rate,
            channels=channels,
            target_sample_rate=16000,
        )
    except Exception as exc:
        return Response({"detail": f"Invalid audio payload: {exc}"}, status=status.HTTP_400_BAD_REQUEST)
    if len(audio_pcm16) < 1600:
        return Response({"detail": "Audio is too short"}, status=status.HTTP_400_BAD_REQUEST)

    started_at = time.time()
    try:
        reply_text, reply_audio_base64, reply_audio_mime = _call_realtime_bot_with_audio(
            meeting=meeting,
            audio_pcm16=audio_pcm16,
            audio_sample_rate=16000,
        )
        content = (reply_text or "").strip()
        if not content:
            return Response({"detail": "Realtime bot returned empty reply"}, status=status.HTTP_400_BAD_REQUEST)
        bot_user = _realtime_bot_system_user()
        msg = MeetingMessage.objects.create(
            meeting=meeting,
            sender_user=bot_user,
            sender_display_name_override=_meeting_realtime_bot_display_name(meeting),
            is_realtime_bot=True,
            audio_mime_type=(reply_audio_mime or "").strip()[:120],
            audio_base64=(reply_audio_base64 or "").strip(),
            content=content[:2000],
        )
        latency_ms = int((time.time() - started_at) * 1000)
        log_audit(
            user=request.user,
            action="meeting.ai_audio_ingress",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"ok=1,latency_ms={latency_ms},provider={_meeting_realtime_bot_provider(meeting)}",
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": True,
                "latency_ms": latency_ms,
                "preview_text": content[:200],
                "message": MeetingMessageSerializer(msg).data,
            }
        )
    except Exception as exc:
        latency_ms = int((time.time() - started_at) * 1000)
        log_audit(
            user=request.user,
            action="meeting.ai_audio_ingress",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"ok=0,latency_ms={latency_ms},error={exc}",
            ip_address=client_ip(request),
        )
        return Response(
            {
                "ok": False,
                "latency_ms": latency_ms,
                "detail": str(exc),
            },
            status=status.HTTP_400_BAD_REQUEST,
        )


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_ai_realtime_audio(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_ai_audio_ingress_impl(request, meeting, meeting_id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_ai_realtime_audio_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_ai_audio_ingress_impl(request, meeting, meeting.id)


def _meeting_mute_all_impl(request, meeting, resource_id_for_log: int):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can mute all members"}, status=status.HTTP_403_FORBIDDEN)

    targets = list(
        MeetingMember.objects.filter(meeting=meeting)
        .exclude(role=MeetingRole.HOST)
        .exclude(user=request.user)
        .select_related("user")
    )
    if targets:
        target_ids = [row.id for row in targets]
        MeetingMember.objects.filter(id__in=target_ids).update(muted_by_host=True)
        for row in targets:
            row.muted_by_host = True
        _sync_livekit_permissions_for_members(meeting, targets)
    guest_identities = _list_guest_participant_identities(meeting)
    muted_guest_count = 0
    for identity in guest_identities:
        try:
            sources = _resolved_guest_publish_sources(meeting, identity)
            if meeting.allow_self_unmute:
                sources.add("microphone")
            else:
                sources.discard("microphone")
            effective_sources = _effective_guest_publish_sources(meeting, sources)
            _sync_livekit_permissions_for_guest_participant(
                meeting,
                identity,
                publish_sources=effective_sources,
            )
            livekit_service.mute_participant_track_sources(
                meeting.room_name,
                identity,
                track_sources=["microphone"],
                muted=True,
            )
            muted_guest_count += 1
        except Exception:
            continue
    log_audit(
        user=request.user,
        action="meeting.mute_all",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"muted_count={len(targets) + muted_guest_count}",
        ip_address=client_ip(request),
    )
    return Response({"ok": True, "muted_count": len(targets) + muted_guest_count})


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_mute_all(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_mute_all_impl(request, meeting, meeting_id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_mute_all_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_mute_all_impl(request, meeting, meeting.id)


def _meeting_waiting_room_entries_impl(request, meeting):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can manage waiting room"}, status=status.HTTP_403_FORBIDDEN)

    status_filter = (request.GET.get("status") or "").strip().lower()
    include_reviewed = _bool_value(request.GET.get("all"), default=False)
    entries = MeetingWaitingRoomEntry.objects.filter(meeting=meeting)
    if status_filter in {
        WaitingRoomStatus.PENDING,
        WaitingRoomStatus.APPROVED,
        WaitingRoomStatus.REJECTED,
    }:
        entries = entries.filter(status=status_filter)
    elif not include_reviewed:
        entries = entries.filter(status=WaitingRoomStatus.PENDING)
    entries = entries.select_related("user", "reviewed_by").order_by("created_at")
    return Response(MeetingWaitingRoomEntrySerializer(entries, many=True).data)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_waiting_room_entries(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_waiting_room_entries_impl(request, meeting)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_waiting_room_entries_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_waiting_room_entries_impl(request, meeting)


def _meeting_waiting_room_review_impl(request, meeting, target_user_id: int, resource_id_for_log: int):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can manage waiting room"}, status=status.HTTP_403_FORBIDDEN)

    target_user = User.objects.filter(id=target_user_id).first()
    if not target_user:
        return Response({"detail": "Target user not found"}, status=status.HTTP_404_NOT_FOUND)

    serializer = WaitingRoomReviewSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    next_status = serializer.validated_data["status"]

    if next_status == WaitingRoomStatus.APPROVED:
        with transaction.atomic():
            MeetingBlockedMember.objects.filter(meeting=meeting, user=target_user).delete()
            member = MeetingMember.objects.filter(meeting=meeting, user=target_user).first()
            if not member:
                member_count = MeetingMember.objects.filter(meeting=meeting).count()
                if member_count >= meeting.max_participants:
                    return Response(
                        {"detail": "Meeting has reached max participants"},
                        status=status.HTTP_400_BAD_REQUEST,
                    )
                member = MeetingMember.objects.create(
                    meeting=meeting,
                    user=target_user,
                    role=MeetingRole.PARTICIPANT,
                    display_name=_fallback_display_name(target_user),
                    muted_by_host=meeting.mute_on_entry,
                )
            entry = _mark_waiting_room_status(
                meeting,
                target_user,
                WaitingRoomStatus.APPROVED,
                reviewed_by=request.user,
            )
        try:
            _sync_livekit_permissions_for_member(meeting, member)
        except Exception:
            pass
    elif next_status == WaitingRoomStatus.REJECTED:
        entry = _mark_waiting_room_status(
            meeting,
            target_user,
            WaitingRoomStatus.REJECTED,
            reviewed_by=request.user,
        )
    else:
        entry = _mark_waiting_room_status(
            meeting,
            target_user,
            WaitingRoomStatus.PENDING,
            reviewed_by=request.user,
        )

    log_audit(
        user=request.user,
        action="meeting.waiting_room_review",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"target_user_id={target_user_id}, status={next_status}",
        ip_address=client_ip(request),
    )
    return Response(MeetingWaitingRoomEntrySerializer(entry).data)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_waiting_room_review(request, meeting_id: int, target_user_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_waiting_room_review_impl(request, meeting, target_user_id, meeting_id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_waiting_room_review_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_waiting_room_review_impl(request, meeting, target_user_id, meeting.id)


def _meeting_blocked_members_impl(request, meeting):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can view blocked members"}, status=status.HTTP_403_FORBIDDEN)
    rows = MeetingBlockedMember.objects.filter(meeting=meeting).select_related("user", "blocked_by").order_by("-created_at")
    return Response(MeetingBlockedMemberSerializer(rows, many=True).data)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_blocked_members(request, meeting_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_blocked_members_impl(request, meeting)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_blocked_members_ref(request, meeting_ref: str):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_blocked_members_impl(request, meeting)


def _meeting_unblock_member_impl(request, meeting, target_user_id: int, resource_id_for_log: int):
    actor_membership = meeting_membership(meeting.id, request.user.id)
    if not can_moderate(request.user, actor_membership):
        return Response({"detail": "Only host/cohost can unblock members"}, status=status.HTTP_403_FORBIDDEN)

    blocked = MeetingBlockedMember.objects.filter(meeting=meeting, user_id=target_user_id).first()
    if not blocked:
        return Response({"detail": "Blocked member not found"}, status=status.HTTP_404_NOT_FOUND)
    blocked.delete()
    log_audit(
        user=request.user,
        action="meeting.member_unblock",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"target_user_id={target_user_id}",
        ip_address=client_ip(request),
    )
    return Response({"ok": True})


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def meeting_unblock_member(request, meeting_id: int, target_user_id: int):
    meeting, error = _meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_unblock_member_impl(request, meeting, target_user_id, meeting_id)


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def meeting_unblock_member_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = _meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return _meeting_unblock_member_impl(request, meeting, target_user_id, meeting.id)


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
    _maybe_trigger_realtime_bot_reply(meeting, msg)
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
