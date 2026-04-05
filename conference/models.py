from django.contrib.auth.models import User
from django.db import models


class MeetingRole(models.TextChoices):
    HOST = "host", "Host"
    COHOST = "cohost", "Co-host"
    PARTICIPANT = "participant", "Participant"


class MeetingRecurrence(models.TextChoices):
    ONCE = "once", "Once"
    DAILY = "daily", "Daily"
    WEEKLY = "weekly", "Weekly"
    MONTHLY = "monthly", "Monthly"


class Organization(models.Model):
    name = models.CharField(max_length=100, unique=True, db_index=True)
    owner_user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="owned_organizations")
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self) -> str:
        return self.name


class OrganizationMember(models.Model):
    organization = models.ForeignKey(Organization, on_delete=models.CASCADE, related_name="members")
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="organization_memberships")
    is_org_admin = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["organization", "user"], name="uq_org_user"),
        ]

    def __str__(self) -> str:
        return f"{self.organization_id}:{self.user_id}"


class UserProfile(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="profile")
    avatar_url = models.URLField(max_length=500, blank=True, default="")
    default_display_name = models.CharField(max_length=80, blank=True, default="")
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"profile:{self.user_id}"


class BillingPlan(models.Model):
    name = models.CharField(max_length=100, unique=True, db_index=True)
    description = models.CharField(max_length=300, blank=True, default="")
    max_active_rooms = models.PositiveIntegerField(default=1)
    max_room_participants = models.PositiveIntegerField(default=100)
    max_room_used_seconds = models.PositiveBigIntegerField(default=0)
    max_current_room_used_seconds = models.PositiveBigIntegerField(default=0)
    max_recording_storage_bytes = models.PositiveBigIntegerField(default=0)
    max_meeting_count = models.PositiveIntegerField(default=10)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"plan:{self.name}"


class UserBillingProfile(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE, related_name="billing_profile")
    plan = models.ForeignKey(
        BillingPlan,
        on_delete=models.SET_NULL,
        related_name="user_profiles",
        null=True,
        blank=True,
    )
    room_peak_count = models.PositiveIntegerField(default=0)
    accumulated_room_used_seconds = models.PositiveBigIntegerField(default=0)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"billing_profile:{self.user_id}"


class Meeting(models.Model):
    title = models.CharField(max_length=120)
    room_name = models.CharField(max_length=120, unique=True, db_index=True)
    description = models.TextField(blank=True, null=True)
    scheduled_start = models.DateTimeField(null=True, blank=True, db_index=True)
    meeting_recurrence = models.CharField(
        max_length=16,
        choices=MeetingRecurrence.choices,
        default=MeetingRecurrence.ONCE,
    )
    meeting_timezone = models.CharField(max_length=64, default="Asia/Shanghai")
    room_session_started_at = models.DateTimeField(null=True, blank=True, db_index=True)
    duration_minutes = models.PositiveIntegerField(default=30)
    actual_started_at = models.DateTimeField(null=True, blank=True, db_index=True)
    meeting_password = models.CharField(max_length=64, null=True, blank=True)
    waiting_room_enabled = models.BooleanField(default=False)
    max_participants = models.PositiveIntegerField(default=100)
    allow_guest_link_join = models.BooleanField(default=True)
    allow_recording = models.BooleanField(default=True)
    allow_screen_share = models.BooleanField(default=True)
    allow_chat = models.BooleanField(default=True)
    allow_self_unmute = models.BooleanField(default=True)
    allow_member_video = models.BooleanField(default=True)
    mute_on_entry = models.BooleanField(default=False)
    realtime_bot_enabled = models.BooleanField(default=False)
    realtime_bot_muted = models.BooleanField(default=False)
    realtime_bot_base_url = models.CharField(max_length=255, blank=True, default="https://api.openai.com")
    realtime_bot_model = models.CharField(max_length=120, blank=True, default="gpt-realtime")
    realtime_bot_api_key = models.CharField(max_length=255, blank=True, default="")
    realtime_bot_voice = models.CharField(max_length=40, blank=True, default="marin")
    realtime_bot_display_name = models.CharField(max_length=80, blank=True, default="实时语音助手")
    active_egress_id = models.CharField(max_length=120, blank=True, default="")
    active_egress_file_name = models.CharField(max_length=255, blank=True, default="")
    active_egress_relative_path = models.CharField(max_length=800, blank=True, default="")
    active_egress_storage_root = models.CharField(max_length=500, blank=True, default="")
    active_egress_started_by = models.ForeignKey(
        User,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="started_meeting_egress_sessions",
    )
    active_egress_started_at = models.DateTimeField(null=True, blank=True)
    owner = models.ForeignKey(User, on_delete=models.CASCADE, related_name="meetings")
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self) -> str:
        return f"{self.title} ({self.room_name})"


class MeetingAlias(models.Model):
    meeting = models.ForeignKey(Meeting, on_delete=models.CASCADE, related_name="aliases")
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="meeting_aliases")
    meeting_ref = models.CharField(max_length=24)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["user", "meeting"], name="uq_meeting_alias_user_meeting"),
            models.UniqueConstraint(fields=["user", "meeting_ref"], name="uq_meeting_alias_user_ref"),
        ]

    def __str__(self) -> str:
        return f"alias:{self.user_id}:{self.meeting_ref}"


class MeetingOrganization(models.Model):
    meeting = models.ForeignKey(Meeting, on_delete=models.CASCADE, related_name="tenant_links")
    organization = models.ForeignKey(Organization, on_delete=models.CASCADE, related_name="meeting_links")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["meeting", "organization"], name="uq_meeting_org"),
        ]


class MeetingMember(models.Model):
    meeting = models.ForeignKey(Meeting, on_delete=models.CASCADE, related_name="members")
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="meeting_memberships")
    role = models.CharField(max_length=16, choices=MeetingRole.choices, default=MeetingRole.PARTICIPANT)
    display_name = models.CharField(max_length=80, blank=True, default="")
    display_name_version = models.PositiveBigIntegerField(default=1)
    allow_self_unmute_override = models.BooleanField(null=True, blank=True)
    allow_member_video_override = models.BooleanField(null=True, blank=True)
    allow_chat_override = models.BooleanField(null=True, blank=True)
    allow_screen_share_override = models.BooleanField(null=True, blank=True)
    muted_by_host = models.BooleanField(default=False)
    video_blocked_by_host = models.BooleanField(default=False)
    mic_request_pending = models.BooleanField(default=False)
    video_request_pending = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["meeting", "user"], name="uq_meeting_user"),
        ]


class MeetingGuestParticipant(models.Model):
    meeting = models.ForeignKey(Meeting, on_delete=models.CASCADE, related_name="guest_participants")
    participant_identity = models.CharField(max_length=120, db_index=True)
    display_name = models.CharField(max_length=80, blank=True, default="")
    display_name_version = models.PositiveBigIntegerField(default=1)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["meeting", "participant_identity"],
                name="uq_meeting_guest_participant_identity",
            ),
        ]


class MeetingMessage(models.Model):
    meeting = models.ForeignKey(Meeting, on_delete=models.CASCADE, related_name="messages")
    sender_user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="sent_meeting_messages")
    sender_display_name_override = models.CharField(max_length=80, blank=True, default="")
    is_realtime_bot = models.BooleanField(default=False)
    audio_mime_type = models.CharField(max_length=120, blank=True, default="")
    audio_base64 = models.TextField(blank=True, default="")
    content = models.TextField()
    created_at = models.DateTimeField(auto_now_add=True)


class RecordingStorageConfig(models.Model):
    storage_root = models.CharField(max_length=500, blank=True, default="")
    updated_by = models.ForeignKey(
        User,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="updated_recording_storage_configs",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        root = self.storage_root or "(unset)"
        return f"recording_storage:{root}"


class SystemAuthConfig(models.Model):
    allow_techcloud_oauth_login = models.BooleanField(default=True)
    allow_local_register = models.BooleanField(default=True)
    allow_local_login = models.BooleanField(default=True)
    updated_by = models.ForeignKey(
        User,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="updated_system_auth_configs",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return (
            f"auth_config:"
            f"techcloud={int(self.allow_techcloud_oauth_login)},"
            f"register={int(self.allow_local_register)},"
            f"login={int(self.allow_local_login)}"
        )


class MeetingRecording(models.Model):
    meeting = models.ForeignKey(
        Meeting,
        on_delete=models.SET_NULL,
        related_name="recordings",
        null=True,
        blank=True,
    )
    meeting_id_snapshot = models.BigIntegerField(null=True, blank=True, db_index=True)
    meeting_title_snapshot = models.CharField(max_length=120, blank=True, default="")
    meeting_room_name_snapshot = models.CharField(max_length=120, blank=True, default="")
    owner = models.ForeignKey(User, on_delete=models.CASCADE, related_name="meeting_recordings")
    recorded_by_display_name = models.CharField(max_length=80, blank=True, default="")
    file_name = models.CharField(max_length=255)
    storage_root = models.CharField(max_length=500)
    relative_path = models.CharField(max_length=800)
    egress_id = models.CharField(max_length=120, blank=True, default="")
    mime_type = models.CharField(max_length=120, blank=True, default="")
    size_bytes = models.BigIntegerField(default=0)
    duration_seconds = models.PositiveIntegerField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)

    def save(self, *args, **kwargs):
        if self.meeting_id and self.meeting is not None:
            if self.meeting_id_snapshot is None:
                self.meeting_id_snapshot = self.meeting_id
            if not self.meeting_title_snapshot:
                self.meeting_title_snapshot = (self.meeting.title or "").strip()
            if not self.meeting_room_name_snapshot:
                self.meeting_room_name_snapshot = (self.meeting.room_name or "").strip()
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        meeting_ref = self.meeting_id if self.meeting_id is not None else self.meeting_id_snapshot
        return f"recording:{meeting_ref}:{self.owner_id}:{self.file_name}"

class WaitingRoomStatus(models.TextChoices):
    PENDING = "pending", "Pending"
    APPROVED = "approved", "Approved"
    REJECTED = "rejected", "Rejected"


class MeetingWaitingRoomEntry(models.Model):
    meeting = models.ForeignKey(Meeting, on_delete=models.CASCADE, related_name="waiting_entries")
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="waiting_meeting_entries")
    status = models.CharField(max_length=16, choices=WaitingRoomStatus.choices, default=WaitingRoomStatus.PENDING)
    reviewed_by = models.ForeignKey(
        User,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="reviewed_waiting_entries",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["meeting", "user"], name="uq_waiting_entry_meeting_user"),
        ]


class MeetingBlockedMember(models.Model):
    meeting = models.ForeignKey(Meeting, on_delete=models.CASCADE, related_name="blocked_members")
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name="blocked_meeting_memberships")
    blocked_by = models.ForeignKey(
        User,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="meeting_member_blocks",
    )
    reason = models.CharField(max_length=200, blank=True, default="")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["meeting", "user"], name="uq_blocked_member_meeting_user"),
        ]


class AuditLog(models.Model):
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True)
    action = models.CharField(max_length=120, db_index=True)
    resource_type = models.CharField(max_length=50, null=True, blank=True)
    resource_id = models.CharField(max_length=120, null=True, blank=True)
    detail = models.TextField(null=True, blank=True)
    ip_address = models.CharField(max_length=64, null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True, db_index=True)


class LoginAttempt(models.Model):
    username = models.CharField(max_length=150, db_index=True)
    ip_address = models.CharField(max_length=64, db_index=True)
    failed_count = models.IntegerField(default=0)
    locked_until = models.DateTimeField(null=True, blank=True)
    last_failed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=["username", "ip_address"], name="uq_login_username_ip"),
        ]
