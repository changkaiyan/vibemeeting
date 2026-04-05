from django.contrib import admin

from conference.models import (
    AuditLog,
    BillingPlan,
    LoginAttempt,
    MeetingBlockedMember,
    Meeting,
    MeetingMember,
    MeetingMessage,
    MeetingRecording,
    MeetingOrganization,
    MeetingWaitingRoomEntry,
    Organization,
    OrganizationMember,
    RecordingStorageConfig,
    SystemAuthConfig,
    UserBillingProfile,
    UserProfile,
)


@admin.register(Organization)
class OrganizationAdmin(admin.ModelAdmin):
    list_display = ("id", "name", "owner_user", "created_at")
    search_fields = ("name", "owner_user__username")


@admin.register(OrganizationMember)
class OrganizationMemberAdmin(admin.ModelAdmin):
    list_display = ("id", "organization", "user", "is_org_admin", "created_at")
    search_fields = ("organization__name", "user__username")
    list_filter = ("is_org_admin",)


@admin.register(Meeting)
class MeetingAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "title",
        "room_name",
        "owner",
        "scheduled_start",
        "actual_started_at",
        "duration_minutes",
        "max_participants",
        "waiting_room_enabled",
        "created_at",
    )
    search_fields = ("title", "room_name", "owner__username")
    list_filter = (
        "waiting_room_enabled",
        "allow_guest_link_join",
        "allow_recording",
        "allow_screen_share",
        "allow_chat",
        "allow_self_unmute",
        "allow_member_video",
        "mute_on_entry",
    )
    fieldsets = (
        ("Basic", {"fields": ("title", "room_name", "description", "owner")}),
        ("Schedule", {"fields": ("scheduled_start", "actual_started_at", "duration_minutes")}),
        ("Security", {"fields": ("meeting_password", "waiting_room_enabled", "max_participants", "mute_on_entry")}),
        (
            "Capabilities",
            {
                "fields": (
                    "allow_guest_link_join",
                    "allow_recording",
                    "allow_screen_share",
                    "allow_chat",
                    "allow_self_unmute",
                    "allow_member_video",
                )
            },
        ),
    )


@admin.register(MeetingOrganization)
class MeetingOrganizationAdmin(admin.ModelAdmin):
    list_display = ("id", "meeting", "organization", "created_at")


@admin.register(MeetingMember)
class MeetingMemberAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "meeting",
        "user",
        "role",
        "display_name",
        "muted_by_host",
        "video_blocked_by_host",
        "created_at",
    )
    search_fields = ("meeting__title", "user__username")
    list_filter = ("role", "muted_by_host", "video_blocked_by_host")


@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = ("id", "user", "default_display_name", "avatar_url", "updated_at")
    search_fields = ("user__username", "user__email", "default_display_name")


@admin.register(BillingPlan)
class BillingPlanAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "name",
        "max_active_rooms",
        "max_room_participants",
        "max_room_used_seconds",
        "max_recording_storage_bytes",
        "max_meeting_count",
        "updated_at",
    )
    search_fields = ("name", "description")


@admin.register(UserBillingProfile)
class UserBillingProfileAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "user",
        "plan",
        "room_peak_count",
        "accumulated_room_used_seconds",
        "updated_at",
    )
    search_fields = ("user__username", "plan__name")


@admin.register(MeetingMessage)
class MeetingMessageAdmin(admin.ModelAdmin):
    list_display = ("id", "meeting", "sender_user", "created_at")
    search_fields = ("meeting__title", "sender_user__username", "content")


@admin.register(RecordingStorageConfig)
class RecordingStorageConfigAdmin(admin.ModelAdmin):
    list_display = ("id", "storage_root", "updated_by", "updated_at")
    search_fields = ("storage_root", "updated_by__username")


@admin.register(SystemAuthConfig)
class SystemAuthConfigAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "allow_techcloud_oauth_login",
        "allow_local_register",
        "allow_local_login",
        "updated_by",
        "updated_at",
    )
    list_filter = (
        "allow_techcloud_oauth_login",
        "allow_local_register",
        "allow_local_login",
    )


@admin.register(MeetingRecording)
class MeetingRecordingAdmin(admin.ModelAdmin):
    list_display = (
        "id",
        "meeting",
        "owner",
        "recorded_by_display_name",
        "file_name",
        "size_bytes",
        "created_at",
    )
    search_fields = (
        "meeting__title",
        "meeting__room_name",
        "owner__username",
        "recorded_by_display_name",
        "file_name",
    )


@admin.register(MeetingWaitingRoomEntry)
class MeetingWaitingRoomEntryAdmin(admin.ModelAdmin):
    list_display = ("id", "meeting", "user", "status", "reviewed_by", "created_at", "updated_at")
    search_fields = ("meeting__title", "user__username", "reviewed_by__username")
    list_filter = ("status",)


@admin.register(MeetingBlockedMember)
class MeetingBlockedMemberAdmin(admin.ModelAdmin):
    list_display = ("id", "meeting", "user", "blocked_by", "reason", "created_at")
    search_fields = ("meeting__title", "user__username", "blocked_by__username", "reason")


@admin.register(AuditLog)
class AuditLogAdmin(admin.ModelAdmin):
    list_display = ("id", "action", "resource_type", "resource_id", "user", "ip_address", "created_at")
    search_fields = ("action", "resource_type", "resource_id", "detail", "user__username")
    list_filter = ("action", "resource_type")


@admin.register(LoginAttempt)
class LoginAttemptAdmin(admin.ModelAdmin):
    list_display = ("id", "username", "ip_address", "failed_count", "locked_until", "last_failed_at")
    search_fields = ("username", "ip_address")
