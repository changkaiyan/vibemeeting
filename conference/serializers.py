from pathlib import Path, PurePosixPath, PureWindowsPath
from zoneinfo import ZoneInfo

from django.contrib.auth.models import User
from rest_framework import serializers

from conference.meeting_refs import ensure_meeting_ref
from conference.models import (
    AuditLog,
    BillingPlan,
    MeetingBlockedMember,
    Meeting,
    MeetingMember,
    MeetingRecurrence,
    MeetingMessage,
    MeetingRecording,
    MeetingRole,
    RealtimeBotProvider,
    MeetingWaitingRoomEntry,
    Organization,
    OrganizationMember,
    RecordingStorageConfig,
    SystemAuthConfig,
    UserBillingProfile,
    UserProfile,
    WaitingRoomStatus,
)
from conference.share import build_meeting_share_code


class UserOutSerializer(serializers.ModelSerializer):
    is_admin = serializers.BooleanField(source="is_superuser")
    avatar_url = serializers.SerializerMethodField()
    default_display_name = serializers.SerializerMethodField()

    class Meta:
        model = User
        fields = (
            "id",
            "username",
            "email",
            "is_admin",
            "date_joined",
            "avatar_url",
            "default_display_name",
        )

    def get_avatar_url(self, obj):
        profile = UserProfile.objects.filter(user=obj).first()
        return profile.avatar_url if profile else ""

    def get_default_display_name(self, obj):
        profile = UserProfile.objects.filter(user=obj).first()
        if profile and profile.default_display_name:
            return profile.default_display_name
        return obj.username


class UserProfileSerializer(serializers.ModelSerializer):
    username = serializers.CharField(source="user.username")
    email = serializers.EmailField(source="user.email")
    is_admin = serializers.BooleanField(source="user.is_superuser", read_only=True)

    class Meta:
        model = UserProfile
        fields = ("username", "email", "avatar_url", "default_display_name", "is_admin")


class UserProfileUpdateSerializer(serializers.Serializer):
    avatar_url = serializers.CharField(required=False, allow_blank=True, max_length=500)
    default_display_name = serializers.CharField(required=False, allow_blank=True, max_length=80)


class BillingPlanSerializer(serializers.ModelSerializer):
    class Meta:
        model = BillingPlan
        fields = (
            "id",
            "name",
            "description",
            "max_active_rooms",
            "max_room_participants",
            "max_room_used_seconds",
            "max_current_room_used_seconds",
            "max_recording_storage_bytes",
            "max_meeting_count",
            "created_at",
            "updated_at",
        )


class BillingPlanUpsertSerializer(serializers.Serializer):
    name = serializers.CharField(required=False, max_length=100)
    description = serializers.CharField(required=False, allow_blank=True, max_length=300)
    max_active_rooms = serializers.IntegerField(required=False, min_value=0, max_value=100000)
    max_room_participants = serializers.IntegerField(required=False, min_value=0, max_value=1000000)
    max_room_used_seconds = serializers.IntegerField(required=False, min_value=0, max_value=315360000)
    max_current_room_used_seconds = serializers.IntegerField(required=False, min_value=0, max_value=315360000)
    max_recording_storage_bytes = serializers.IntegerField(required=False, min_value=0, max_value=10**15)
    max_meeting_count = serializers.IntegerField(required=False, min_value=0, max_value=1000000)


class UserBillingPlanAssignSerializer(serializers.Serializer):
    plan_id = serializers.IntegerField(required=False, allow_null=True)


class UserBillingProfileSerializer(serializers.ModelSerializer):
    user_id = serializers.IntegerField(source="user.id")
    username = serializers.CharField(source="user.username")
    email = serializers.EmailField(source="user.email")
    plan_id = serializers.IntegerField(source="plan.id", allow_null=True)
    plan_name = serializers.CharField(source="plan.name", allow_null=True)

    class Meta:
        model = UserBillingProfile
        fields = (
            "user_id",
            "username",
            "email",
            "plan_id",
            "plan_name",
            "room_peak_count",
            "accumulated_room_used_seconds",
            "updated_at",
        )


class RegisterSerializer(serializers.Serializer):
    username = serializers.CharField(min_length=3, max_length=50)
    email = serializers.EmailField()
    password = serializers.CharField(min_length=6, max_length=128)


class MeetingCreateSerializer(serializers.Serializer):
    title = serializers.CharField(required=False, allow_blank=True, max_length=120)
    description = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    scheduled_start = serializers.DateTimeField(required=False, allow_null=True)
    meeting_recurrence = serializers.ChoiceField(
        required=False,
        choices=MeetingRecurrence.choices,
        default=MeetingRecurrence.ONCE,
    )
    meeting_timezone = serializers.CharField(required=False, default="Asia/Shanghai", max_length=64)
    duration_minutes = serializers.IntegerField(required=False, min_value=1, max_value=1440, default=30)
    meeting_password = serializers.CharField(required=False, allow_blank=True, allow_null=True, max_length=64)
    waiting_room_enabled = serializers.BooleanField(required=False, default=False)
    max_participants = serializers.IntegerField(required=False, min_value=2, max_value=10000, default=100)
    allow_guest_link_join = serializers.BooleanField(required=False, default=True)
    allow_recording = serializers.BooleanField(required=False, default=True)
    allow_screen_share = serializers.BooleanField(required=False, default=True)
    allow_chat = serializers.BooleanField(required=False, default=True)
    allow_self_unmute = serializers.BooleanField(required=False, default=True)
    allow_member_video = serializers.BooleanField(required=False, default=True)
    mute_on_entry = serializers.BooleanField(required=False, default=False)

    def validate_meeting_timezone(self, value: str):
        timezone_name = (value or "").strip()
        if not timezone_name:
            raise serializers.ValidationError("meeting_timezone is required")
        try:
            ZoneInfo(timezone_name)
        except Exception as exc:
            raise serializers.ValidationError("Invalid timezone") from exc
        return timezone_name


class MeetingUpdateSerializer(serializers.Serializer):
    title = serializers.CharField(required=False, min_length=1, max_length=120)
    description = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    scheduled_start = serializers.DateTimeField(required=False, allow_null=True)
    meeting_recurrence = serializers.ChoiceField(required=False, choices=MeetingRecurrence.choices)
    meeting_timezone = serializers.CharField(required=False, max_length=64)
    duration_minutes = serializers.IntegerField(required=False, min_value=1, max_value=1440)
    meeting_password = serializers.CharField(required=False, allow_blank=True, allow_null=True, max_length=64)
    waiting_room_enabled = serializers.BooleanField(required=False)
    max_participants = serializers.IntegerField(required=False, min_value=2, max_value=10000)
    allow_guest_link_join = serializers.BooleanField(required=False)
    allow_recording = serializers.BooleanField(required=False)
    allow_screen_share = serializers.BooleanField(required=False)
    allow_chat = serializers.BooleanField(required=False)
    allow_self_unmute = serializers.BooleanField(required=False)
    allow_member_video = serializers.BooleanField(required=False)
    mute_on_entry = serializers.BooleanField(required=False)

    def validate_meeting_timezone(self, value: str):
        timezone_name = (value or "").strip()
        if not timezone_name:
            raise serializers.ValidationError("meeting_timezone cannot be empty")
        try:
            ZoneInfo(timezone_name)
        except Exception as exc:
            raise serializers.ValidationError("Invalid timezone") from exc
        return timezone_name


class MeetingControlUpdateSerializer(serializers.Serializer):
    waiting_room_enabled = serializers.BooleanField(required=False)
    allow_guest_link_join = serializers.BooleanField(required=False)
    allow_screen_share = serializers.BooleanField(required=False)
    allow_chat = serializers.BooleanField(required=False)
    allow_self_unmute = serializers.BooleanField(required=False)
    allow_member_video = serializers.BooleanField(required=False)


class MeetingRealtimeBotControlSerializer(serializers.Serializer):
    realtime_bot_provider = serializers.ChoiceField(
        required=False,
        choices=RealtimeBotProvider.choices,
    )
    realtime_bot_enabled = serializers.BooleanField(required=False)
    realtime_bot_muted = serializers.BooleanField(required=False)
    realtime_bot_base_url = serializers.CharField(required=False, allow_blank=False, max_length=255)
    realtime_bot_model = serializers.CharField(required=False, allow_blank=False, max_length=120)
    realtime_bot_api_key = serializers.CharField(required=False, allow_blank=True, max_length=255)
    realtime_bot_voice = serializers.CharField(required=False, allow_blank=False, max_length=40)
    realtime_bot_volc_ws_url = serializers.CharField(required=False, allow_blank=False, max_length=255)
    realtime_bot_volc_app_id = serializers.CharField(required=False, allow_blank=False, max_length=64)
    realtime_bot_volc_app_key = serializers.CharField(required=False, allow_blank=True, max_length=255)
    realtime_bot_volc_access_key = serializers.CharField(required=False, allow_blank=True, max_length=255)
    realtime_bot_volc_resource_id = serializers.CharField(required=False, allow_blank=False, max_length=120)
    realtime_bot_volc_uid = serializers.CharField(required=False, allow_blank=True, max_length=120)
    realtime_bot_display_name = serializers.CharField(required=False, allow_blank=False, max_length=80)


class MeetingRealtimeBotConnectivityTestSerializer(serializers.Serializer):
    provider = serializers.ChoiceField(required=False, choices=RealtimeBotProvider.choices)
    base_url = serializers.CharField(required=False, allow_blank=False, max_length=255)
    model = serializers.CharField(required=False, allow_blank=False, max_length=120)
    api_key = serializers.CharField(required=False, allow_blank=False, max_length=255)
    voice = serializers.CharField(required=False, allow_blank=False, max_length=40)
    volc_ws_url = serializers.CharField(required=False, allow_blank=False, max_length=255)
    volc_app_id = serializers.CharField(required=False, allow_blank=False, max_length=64)
    volc_app_key = serializers.CharField(required=False, allow_blank=True, max_length=255)
    volc_access_key = serializers.CharField(required=False, allow_blank=False, max_length=255)
    volc_resource_id = serializers.CharField(required=False, allow_blank=False, max_length=120)
    volc_uid = serializers.CharField(required=False, allow_blank=True, max_length=120)
    prompt = serializers.CharField(required=False, allow_blank=False, max_length=500)


class MeetingRealtimeBotAudioIngressSerializer(serializers.Serializer):
    audio_base64 = serializers.CharField(required=True, allow_blank=False, max_length=8_000_000)
    sample_rate = serializers.IntegerField(required=False, min_value=8000, max_value=96000, default=16000)
    channels = serializers.IntegerField(required=False, min_value=1, max_value=2, default=1)


class MeetingSerializer(serializers.ModelSerializer):
    meeting_ref = serializers.SerializerMethodField()
    has_password = serializers.SerializerMethodField()
    meeting_password_for_share = serializers.SerializerMethodField()
    current_user_role = serializers.SerializerMethodField()
    can_edit = serializers.SerializerMethodField()
    can_delete = serializers.SerializerMethodField()
    can_debug_token = serializers.SerializerMethodField()
    share_code = serializers.SerializerMethodField()
    share_url = serializers.SerializerMethodField()
    realtime_bot_api_key_set = serializers.SerializerMethodField()
    realtime_bot_api_key = serializers.SerializerMethodField()
    realtime_bot_volc_app_key_set = serializers.SerializerMethodField()
    realtime_bot_volc_access_key_set = serializers.SerializerMethodField()
    realtime_bot_volc_app_key = serializers.SerializerMethodField()
    realtime_bot_volc_access_key = serializers.SerializerMethodField()
    realtime_bot_user_id = serializers.SerializerMethodField()
    realtime_bot_identity = serializers.SerializerMethodField()

    class Meta:
        model = Meeting
        fields = (
            "id",
            "meeting_ref",
            "title",
            "room_name",
            "description",
            "scheduled_start",
            "meeting_recurrence",
            "meeting_timezone",
            "duration_minutes",
            "actual_started_at",
            "has_password",
            "meeting_password_for_share",
            "waiting_room_enabled",
            "max_participants",
            "allow_guest_link_join",
            "allow_recording",
            "allow_screen_share",
            "allow_chat",
            "allow_self_unmute",
            "allow_member_video",
            "mute_on_entry",
            "realtime_bot_provider",
            "realtime_bot_enabled",
            "realtime_bot_muted",
            "realtime_bot_base_url",
            "realtime_bot_model",
            "realtime_bot_voice",
            "realtime_bot_volc_ws_url",
            "realtime_bot_volc_app_id",
            "realtime_bot_volc_app_key_set",
            "realtime_bot_volc_app_key",
            "realtime_bot_volc_access_key_set",
            "realtime_bot_volc_access_key",
            "realtime_bot_volc_resource_id",
            "realtime_bot_volc_uid",
            "realtime_bot_display_name",
            "realtime_bot_api_key_set",
            "realtime_bot_api_key",
            "realtime_bot_user_id",
            "realtime_bot_identity",
            "owner_id",
            "created_at",
            "current_user_role",
            "can_edit",
            "can_delete",
            "can_debug_token",
            "share_code",
            "share_url",
        )

    def get_has_password(self, obj):
        return bool(obj.meeting_password)

    def get_meeting_password_for_share(self, obj):
        return (obj.meeting_password or "").strip()

    def _request_user(self):
        request = self.context.get("request")
        if not request:
            return None
        user = getattr(request, "user", None)
        if not user or not user.is_authenticated:
            return None
        return user

    def _is_host(self, obj, user) -> bool:
        if not user:
            return False
        if user.is_superuser or obj.owner_id == user.id:
            return True
        membership = MeetingMember.objects.filter(meeting=obj, user=user).first()
        return bool(membership and membership.role == MeetingRole.HOST)

    def _can_manage_realtime_bot(self, obj, user) -> bool:
        if not user or not user.is_authenticated:
            return False
        if user.is_superuser or obj.owner_id == user.id:
            return True
        membership = MeetingMember.objects.filter(meeting=obj, user=user).first()
        if not membership:
            return False
        return membership.role in {MeetingRole.HOST, MeetingRole.COHOST}

    def get_current_user_role(self, obj):
        user = self._request_user()
        if not user:
            return None
        if user.is_superuser or obj.owner_id == user.id:
            return MeetingRole.HOST
        membership = MeetingMember.objects.filter(meeting=obj, user=user).first()
        return membership.role if membership else None

    def get_can_edit(self, obj):
        user = self._request_user()
        return self._is_host(obj, user)

    def get_can_delete(self, obj):
        user = self._request_user()
        return self._is_host(obj, user)

    def get_can_debug_token(self, obj):
        user = self._request_user()
        return bool(user and user.is_superuser)

    def get_meeting_ref(self, obj):
        user = self._request_user()
        if not user:
            return None
        return ensure_meeting_ref(obj, user)

    def get_share_code(self, obj):
        return build_meeting_share_code(obj.room_name)

    def get_share_url(self, obj):
        request = self.context.get("request")
        path = f"/m/{self.get_share_code(obj)}"
        if request:
            return request.build_absolute_uri(path)
        return path

    def get_realtime_bot_api_key_set(self, obj):
        user = self._request_user()
        if not self._can_manage_realtime_bot(obj, user):
            return False
        return bool((obj.realtime_bot_api_key or "").strip())

    def get_realtime_bot_api_key(self, obj):
        user = self._request_user()
        if not self._can_manage_realtime_bot(obj, user):
            return ""
        return (obj.realtime_bot_api_key or "").strip()

    def get_realtime_bot_volc_app_key_set(self, obj):
        user = self._request_user()
        if not self._can_manage_realtime_bot(obj, user):
            return False
        return bool((obj.realtime_bot_volc_app_key or "").strip())

    def get_realtime_bot_volc_access_key_set(self, obj):
        user = self._request_user()
        if not self._can_manage_realtime_bot(obj, user):
            return False
        return bool((obj.realtime_bot_volc_access_key or "").strip())

    def get_realtime_bot_volc_app_key(self, obj):
        user = self._request_user()
        if not self._can_manage_realtime_bot(obj, user):
            return ""
        return (obj.realtime_bot_volc_app_key or "").strip()

    def get_realtime_bot_volc_access_key(self, obj):
        user = self._request_user()
        if not self._can_manage_realtime_bot(obj, user):
            return ""
        return (obj.realtime_bot_volc_access_key or "").strip()

    def get_realtime_bot_user_id(self, obj):
        if not obj.realtime_bot_enabled:
            return None
        user = User.objects.filter(username="__meeting_realtime_bot__").first()
        if not user:
            return None
        return user.id

    def get_realtime_bot_identity(self, obj):
        return f"ai_realtime_bot_{obj.id}"[:64]


class MeetingJoinSerializer(serializers.Serializer):
    room_name = serializers.CharField(required=False, allow_blank=False)
    meeting_password = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    display_name = serializers.CharField(required=False, allow_blank=True, max_length=80)

    def validate(self, attrs):
        if not attrs.get("room_name"):
            raise serializers.ValidationError("room_name is required")
        return attrs


class MeetingMemberSerializer(serializers.ModelSerializer):
    user_id = serializers.IntegerField(source="user.id")
    username = serializers.CharField(source="user.username")
    email = serializers.EmailField(source="user.email")
    avatar_url = serializers.SerializerMethodField()
    display_name = serializers.SerializerMethodField()
    allow_self_unmute = serializers.SerializerMethodField()
    allow_member_video = serializers.SerializerMethodField()
    allow_chat = serializers.SerializerMethodField()
    allow_screen_share = serializers.SerializerMethodField()

    class Meta:
        model = MeetingMember
        fields = (
            "user_id",
            "username",
            "email",
            "avatar_url",
            "display_name",
            "display_name_version",
            "role",
            "allow_self_unmute",
            "allow_member_video",
            "allow_chat",
            "allow_screen_share",
            "allow_self_unmute_override",
            "allow_member_video_override",
            "allow_chat_override",
            "allow_screen_share_override",
            "muted_by_host",
            "video_blocked_by_host",
            "mic_request_pending",
            "video_request_pending",
            "created_at",
        )

    def get_avatar_url(self, obj):
        profile = UserProfile.objects.filter(user=obj.user).first()
        return profile.avatar_url if profile else ""

    def get_display_name(self, obj):
        if obj.display_name:
            return obj.display_name
        profile = UserProfile.objects.filter(user=obj.user).first()
        if profile and profile.default_display_name:
            return profile.default_display_name
        return obj.user.username

    def _meeting(self, obj):
        meeting = self.context.get("meeting")
        if meeting is not None:
            return meeting
        return getattr(obj, "meeting", None)

    def _resolve_override(self, default_value: bool, override_value):
        if override_value is None:
            return default_value
        return bool(override_value)

    def get_allow_self_unmute(self, obj):
        if obj.role in {MeetingRole.HOST, MeetingRole.COHOST}:
            return True
        meeting = self._meeting(obj)
        base = meeting.allow_self_unmute if meeting is not None else True
        return self._resolve_override(base, obj.allow_self_unmute_override)

    def get_allow_member_video(self, obj):
        if obj.role in {MeetingRole.HOST, MeetingRole.COHOST}:
            return True
        meeting = self._meeting(obj)
        base = meeting.allow_member_video if meeting is not None else True
        return self._resolve_override(base, obj.allow_member_video_override)

    def get_allow_chat(self, obj):
        if obj.role in {MeetingRole.HOST, MeetingRole.COHOST}:
            return True
        meeting = self._meeting(obj)
        base = meeting.allow_chat if meeting is not None else True
        return self._resolve_override(base, obj.allow_chat_override)

    def get_allow_screen_share(self, obj):
        if obj.role in {MeetingRole.HOST, MeetingRole.COHOST}:
            return True
        meeting = self._meeting(obj)
        base = meeting.allow_screen_share if meeting is not None else True
        return self._resolve_override(base, obj.allow_screen_share_override)


class MeetingDisplayNameUpdateSerializer(serializers.Serializer):
    display_name = serializers.CharField(min_length=1, max_length=80)
    expected_display_name_version = serializers.IntegerField(min_value=1, required=False)


class MeetingMemberAddSerializer(serializers.Serializer):
    username = serializers.CharField()
    role = serializers.ChoiceField(choices=MeetingMember._meta.get_field("role").choices, default="participant")


class MeetingRoleUpdateSerializer(serializers.Serializer):
    role = serializers.ChoiceField(choices=MeetingMember._meta.get_field("role").choices)


class MeetingMuteSerializer(serializers.Serializer):
    muted = serializers.BooleanField(default=True)


class MeetingVideoControlSerializer(serializers.Serializer):
    disabled = serializers.BooleanField(default=True)


class MeetingMemberDisplayNameControlSerializer(serializers.Serializer):
    display_name = serializers.CharField(min_length=1, max_length=80)
    expected_display_name_version = serializers.IntegerField(min_value=1, required=False)


class MeetingPermissionControlSerializer(serializers.Serializer):
    allowed = serializers.BooleanField()


class MeetingRaiseHandSerializer(serializers.Serializer):
    request = serializers.ChoiceField(choices=("mic", "video"))


class MeetingHostLeaveSerializer(serializers.Serializer):
    transfer_user_id = serializers.IntegerField(required=False, allow_null=True)


class WaitingRoomReviewSerializer(serializers.Serializer):
    status = serializers.ChoiceField(choices=WaitingRoomStatus.choices)


class MeetingWaitingRoomEntrySerializer(serializers.ModelSerializer):
    user_id = serializers.IntegerField(source="user.id")
    username = serializers.CharField(source="user.username")
    email = serializers.EmailField(source="user.email")
    reviewed_by_user_id = serializers.IntegerField(source="reviewed_by.id", allow_null=True)
    reviewed_by_username = serializers.CharField(source="reviewed_by.username", allow_null=True)
    avatar_url = serializers.SerializerMethodField()
    display_name = serializers.SerializerMethodField()

    class Meta:
        model = MeetingWaitingRoomEntry
        fields = (
            "user_id",
            "username",
            "email",
            "avatar_url",
            "display_name",
            "status",
            "reviewed_by_user_id",
            "reviewed_by_username",
            "created_at",
            "updated_at",
        )

    def get_avatar_url(self, obj):
        profile = UserProfile.objects.filter(user=obj.user).first()
        return profile.avatar_url if profile else ""

    def get_display_name(self, obj):
        membership = MeetingMember.objects.filter(meeting=obj.meeting, user=obj.user).first()
        if membership and membership.display_name:
            return membership.display_name
        profile = UserProfile.objects.filter(user=obj.user).first()
        if profile and profile.default_display_name:
            return profile.default_display_name
        return obj.user.username


class MeetingBlockedMemberSerializer(serializers.ModelSerializer):
    user_id = serializers.IntegerField(source="user.id")
    username = serializers.CharField(source="user.username")
    blocked_by_user_id = serializers.IntegerField(source="blocked_by.id", allow_null=True)
    blocked_by_username = serializers.CharField(source="blocked_by.username", allow_null=True)

    class Meta:
        model = MeetingBlockedMember
        fields = (
            "user_id",
            "username",
            "blocked_by_user_id",
            "blocked_by_username",
            "reason",
            "created_at",
        )


class MeetingMessageCreateSerializer(serializers.Serializer):
    content = serializers.CharField(min_length=1, max_length=2000)


class MeetingMessageSerializer(serializers.ModelSerializer):
    sender_user_id = serializers.IntegerField(source="sender_user.id")
    sender_username = serializers.CharField(source="sender_user.username")
    sender_display_name = serializers.SerializerMethodField()

    class Meta:
        model = MeetingMessage
        fields = (
            "id",
            "sender_user_id",
            "sender_username",
            "sender_display_name",
            "is_realtime_bot",
            "audio_mime_type",
            "audio_base64",
            "content",
            "created_at",
        )

    def get_sender_display_name(self, obj):
        if (obj.sender_display_name_override or "").strip():
            return obj.sender_display_name_override.strip()
        membership = MeetingMember.objects.filter(meeting=obj.meeting, user=obj.sender_user).first()
        if membership and membership.display_name:
            return membership.display_name
        profile = UserProfile.objects.filter(user=obj.sender_user).first()
        if profile and profile.default_display_name:
            return profile.default_display_name
        return obj.sender_user.username


class RecordingStorageConfigSerializer(serializers.ModelSerializer):
    updated_by_username = serializers.CharField(source="updated_by.username", allow_null=True)

    class Meta:
        model = RecordingStorageConfig
        fields = (
            "storage_root",
            "updated_by_username",
            "updated_at",
        )


class RecordingStorageConfigUpdateSerializer(serializers.Serializer):
    storage_root = serializers.CharField(min_length=1, max_length=500)


class SystemAuthConfigSerializer(serializers.ModelSerializer):
    updated_by_username = serializers.CharField(source="updated_by.username", allow_null=True)

    class Meta:
        model = SystemAuthConfig
        fields = (
            "allow_techcloud_oauth_login",
            "allow_local_register",
            "allow_local_login",
            "updated_by_username",
            "updated_at",
        )


class SystemAuthConfigUpdateSerializer(serializers.Serializer):
    allow_techcloud_oauth_login = serializers.BooleanField(required=False)
    allow_local_register = serializers.BooleanField(required=False)
    allow_local_login = serializers.BooleanField(required=False)

    def validate(self, attrs):
        if not attrs:
            raise serializers.ValidationError("At least one option is required")
        return attrs


class MeetingRecordingSerializer(serializers.ModelSerializer):
    meeting_title = serializers.SerializerMethodField()
    meeting_room_name = serializers.SerializerMethodField()
    meeting_display_id = serializers.SerializerMethodField()
    meeting_deleted = serializers.SerializerMethodField()
    owner_user_id = serializers.IntegerField(source="owner.id")
    owner_username = serializers.CharField(source="owner.username")
    owner_display_name = serializers.SerializerMethodField()
    meeting_ref = serializers.SerializerMethodField()
    download_path = serializers.SerializerMethodField()
    stored_file_path = serializers.SerializerMethodField()

    class Meta:
        model = MeetingRecording
        fields = (
            "id",
            "meeting_id",
            "meeting_display_id",
            "meeting_ref",
            "meeting_deleted",
            "meeting_title",
            "meeting_room_name",
            "owner_user_id",
            "owner_username",
            "owner_display_name",
            "recorded_by_display_name",
            "file_name",
            "storage_root",
            "relative_path",
            "stored_file_path",
            "mime_type",
            "size_bytes",
            "duration_seconds",
            "created_at",
            "download_path",
        )

    def get_meeting_title(self, obj):
        meeting = getattr(obj, "meeting", None)
        if meeting is not None:
            return (meeting.title or "").strip()
        snapshot = (obj.meeting_title_snapshot or "").strip()
        return snapshot or "Deleted meeting"

    def get_meeting_room_name(self, obj):
        meeting = getattr(obj, "meeting", None)
        if meeting is not None:
            return (meeting.room_name or "").strip()
        snapshot = (obj.meeting_room_name_snapshot or "").strip()
        return snapshot or "-"

    def get_meeting_display_id(self, obj):
        if obj.meeting_id is not None:
            return obj.meeting_id
        return obj.meeting_id_snapshot

    def get_meeting_deleted(self, obj):
        return obj.meeting_id is None

    def get_owner_display_name(self, obj):
        profile = UserProfile.objects.filter(user=obj.owner).first()
        if profile and profile.default_display_name:
            return profile.default_display_name
        return obj.owner.username

    def get_meeting_ref(self, obj):
        request = self.context.get("request")
        if not request:
            return None
        user = getattr(request, "user", None)
        if not user or not user.is_authenticated:
            return None
        if obj.meeting is None:
            return None
        return ensure_meeting_ref(obj.meeting, user)

    def get_download_path(self, obj):
        return f"/api/recordings/{obj.id}/download"

    def get_stored_file_path(self, obj):
        root = (obj.storage_root or "").strip()
        relative = (obj.relative_path or "").strip()
        if not root:
            return relative
        if not relative:
            return root

        relative_parts = [
            part
            for part in relative.replace("\\", "/").split("/")
            if part and part not in {".", ".."}
        ]
        if not relative_parts:
            return root

        is_windows_root = "\\" in root or (len(root) > 1 and root[1] == ":")
        if is_windows_root:
            return str(PureWindowsPath(root, *relative_parts))
        if root.startswith("/"):
            return str(PurePosixPath(root) / PurePosixPath(*relative_parts))
        return str(Path(root).joinpath(*relative_parts))


class OrganizationSerializer(serializers.ModelSerializer):
    owner_user_id = serializers.IntegerField(source="owner_user.id")

    class Meta:
        model = Organization
        fields = ("id", "name", "owner_user_id", "created_at")


class OrganizationMemberAddSerializer(serializers.Serializer):
    username = serializers.CharField()
    is_org_admin = serializers.BooleanField(default=False)


class OrganizationMemberSerializer(serializers.ModelSerializer):
    user_id = serializers.IntegerField(source="user.id")
    username = serializers.CharField(source="user.username")
    email = serializers.EmailField(source="user.email")

    class Meta:
        model = OrganizationMember
        fields = ("user_id", "username", "email", "is_org_admin", "created_at")


class AuditLogSerializer(serializers.ModelSerializer):
    class Meta:
        model = AuditLog
        fields = (
            "id",
            "user_id",
            "action",
            "resource_type",
            "resource_id",
            "detail",
            "ip_address",
            "created_at",
        )
