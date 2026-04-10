from conference import views


def member_control_response(meeting, target):
    return views.Response(views.MeetingMemberSerializer(target, context={"meeting": meeting}).data)


def require_member_action_allowed(
    request,
    actor_membership,
    target,
    *,
    moderator_detail: str,
    host_detail: str | None = None,
):
    if not views.can_moderate(request.user, actor_membership):
        return views.Response({"detail": moderator_detail}, status=views.status.HTTP_403_FORBIDDEN)
    if target.role == views.MeetingRole.HOST and host_detail and not request.user.is_superuser:
        return views.Response({"detail": host_detail}, status=views.status.HTTP_403_FORBIDDEN)
    return None


def handle_role_action(request, meeting, actor_membership, target, resource_id_for_log: int):
    if not views.can_change_roles(request.user, actor_membership):
        return views.Response({"detail": "Only host/cohost can change role"}, status=views.status.HTTP_403_FORBIDDEN)
    serializer = views.MeetingRoleUpdateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    next_role = serializer.validated_data["role"]
    if next_role == views.MeetingRole.HOST and not request.user.is_superuser:
        return views.Response({"detail": "Only admin can assign host role"}, status=views.status.HTTP_403_FORBIDDEN)
    if target.role == views.MeetingRole.HOST and next_role != views.MeetingRole.HOST and not request.user.is_superuser:
        return views.Response({"detail": "Host role cannot be changed by non-admin"}, status=views.status.HTTP_403_FORBIDDEN)
    if target.user_id == request.user.id and not request.user.is_superuser:
        return views.Response({"detail": "Cannot change your own role"}, status=views.status.HTTP_400_BAD_REQUEST)
    if target.role != next_role:
        target.role = next_role
        target.save(update_fields=["role"])
        try:
            views._sync_livekit_permissions_for_member(meeting, target)
        except Exception:
            pass
    views.log_audit(
        user=request.user,
        action="meeting.member_role_update",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"target_user_id={target.user_id}, role={target.role}",
        ip_address=views.client_ip(request),
    )
    return member_control_response(meeting, target)


def handle_mute_action(request, meeting, actor_membership, target, resource_id_for_log: int):
    denied = require_member_action_allowed(
        request,
        actor_membership,
        target,
        moderator_detail="Only host/cohost can mute members",
        host_detail="Host cannot be muted by non-admin",
    )
    if denied:
        return denied

    serializer = views.MeetingMuteSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    next_muted = serializer.validated_data["muted"]
    if not next_muted and not views._member_can_self_unmute(meeting, target):
        return views.Response(
            {"detail": "Member has no microphone permission. Allow mic first."},
            status=views.status.HTTP_400_BAD_REQUEST,
        )

    target.muted_by_host = next_muted
    update_fields = ["muted_by_host"]
    if not next_muted and target.mic_request_pending:
        target.mic_request_pending = False
        update_fields.append("mic_request_pending")
    target.save(update_fields=update_fields)
    try:
        views._sync_livekit_permissions_for_member(
            meeting,
            target,
            force_unmute_microphone=not target.muted_by_host,
        )
        if not next_muted:
            views._request_participant_device_open(
                meeting,
                views._stable_participant_identity(target.user),
                open_microphone=True,
            )
    except Exception:
        pass
    views.log_audit(
        user=request.user,
        action="meeting.member_mute",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"target_user_id={target.user_id}, muted={target.muted_by_host}",
        ip_address=views.client_ip(request),
    )
    return member_control_response(meeting, target)


def handle_video_action(request, meeting, actor_membership, target, resource_id_for_log: int):
    denied = require_member_action_allowed(
        request,
        actor_membership,
        target,
        moderator_detail="Only host/cohost can control member video",
        host_detail="Host video cannot be controlled by non-admin",
    )
    if denied:
        return denied

    serializer = views.MeetingVideoControlSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    disabled = serializer.validated_data["disabled"]
    if not disabled and not views._member_can_video(meeting, target):
        return views.Response(
            {"detail": "Member has no camera permission. Allow video first."},
            status=views.status.HTTP_400_BAD_REQUEST,
        )

    target.video_blocked_by_host = disabled
    update_fields = ["video_blocked_by_host"]
    if not disabled and target.video_request_pending:
        target.video_request_pending = False
        update_fields.append("video_request_pending")
    target.save(update_fields=update_fields)
    try:
        views._sync_livekit_permissions_for_member(
            meeting,
            target,
            force_unmute_camera=not disabled,
        )
        if not disabled:
            views._request_participant_device_open(
                meeting,
                views._stable_participant_identity(target.user),
                open_camera=True,
            )
    except Exception:
        pass
    views.log_audit(
        user=request.user,
        action="meeting.member_video_control",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"target_user_id={target.user_id}, disabled={disabled}",
        ip_address=views.client_ip(request),
    )
    return member_control_response(meeting, target)


def handle_permission_action(
    request,
    meeting,
    actor_membership,
    target,
    resource_id_for_log: int,
    *,
    action: str,
):
    denied = require_member_action_allowed(
        request,
        actor_membership,
        target,
        moderator_detail="Only host/cohost can update member permissions",
        host_detail="Host member permission cannot be changed by non-admin",
    )
    if denied:
        return denied

    serializer = views.MeetingPermissionControlSerializer(data=request.data)
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
        views._sync_livekit_permissions_for_member(meeting, target)
        if action == "screen_share_permission" and not allowed:
            views.livekit_service.mute_participant_track_sources(
                meeting.room_name,
                views._stable_participant_identity(target.user),
                track_sources=["screen_share", "screen_share_audio"],
                muted=True,
            )
    except Exception:
        pass

    views.log_audit(
        user=request.user,
        action=action_name,
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"target_user_id={target.user_id}, allowed={allowed}",
        ip_address=views.client_ip(request),
    )
    return member_control_response(meeting, target)


def handle_display_name_action(request, meeting, actor_membership, target, resource_id_for_log: int):
    denied = require_member_action_allowed(
        request,
        actor_membership,
        target,
        moderator_detail="Only host/cohost can rename members",
    )
    if denied:
        return denied

    serializer = views.MeetingMemberDisplayNameControlSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    next_display_name = serializer.validated_data["display_name"].strip()
    expected_display_name_version = serializer.validated_data.get("expected_display_name_version")
    target, conflict = views._update_member_display_name_consistently(
        meeting,
        target.id,
        next_display_name=next_display_name,
        expected_display_name_version=expected_display_name_version,
    )
    if conflict is not None:
        return views._display_name_conflict_response(
            current_display_name=conflict.display_name,
            current_display_name_version=conflict.display_name_version,
        )
    if target is None:
        return views.Response({"detail": "Member not found"}, status=views.status.HTTP_404_NOT_FOUND)
    participant_identity = views._stable_participant_identity(target.user)
    try:
        views.livekit_service.update_participant_name(
            meeting.room_name,
            participant_identity,
            name=target.display_name,
        )
    except Exception:
        pass
    views._sync_participant_display_name_metadata(
        meeting,
        participant_identity,
        display_name=target.display_name,
        display_name_version=target.display_name_version,
    )
    views.log_audit(
        user=request.user,
        action="meeting.member_display_name_control",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=(
            f"target_user_id={target.user_id}, "
            f"display_name={target.display_name}, "
            f"display_name_version={target.display_name_version}"
        ),
        ip_address=views.client_ip(request),
    )
    return member_control_response(meeting, target)


def handle_stop_share_action(request, meeting, actor_membership, target, resource_id_for_log: int):
    denied = require_member_action_allowed(
        request,
        actor_membership,
        target,
        moderator_detail="Only host/cohost can stop screen share",
    )
    if denied:
        return denied

    try:
        views.livekit_service.mute_participant_track_sources(
            meeting.room_name,
            views._stable_participant_identity(target.user),
            track_sources=["screen_share", "screen_share_audio"],
            muted=True,
        )
    except Exception:
        pass
    views.log_audit(
        user=request.user,
        action="meeting.member_stop_share",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"target_user_id={target.user_id}",
        ip_address=views.client_ip(request),
    )
    return member_control_response(meeting, target)


def handle_remove_action(request, meeting, actor_membership, target, resource_id_for_log: int):
    denied = require_member_action_allowed(
        request,
        actor_membership,
        target,
        moderator_detail="Only host/cohost can remove members",
        host_detail="Host cannot be removed by non-admin",
    )
    if denied:
        return denied

    ban_after_remove = views._bool_value(request.query_params.get("ban", "1"), default=True)
    reason = (request.query_params.get("reason") or "").strip()[:200]
    target_user = target.user
    target_identity = views._stable_participant_identity(target_user)
    target.delete()
    if ban_after_remove:
        views.MeetingBlockedMember.objects.update_or_create(
            meeting=meeting,
            user=target_user,
            defaults={
                "blocked_by": request.user,
                "reason": reason or "removed_by_moderator",
            },
        )
        views._mark_waiting_room_status(
            meeting,
            target_user,
            views.WaitingRoomStatus.REJECTED,
            reviewed_by=request.user,
        )
    try:
        views.livekit_service.remove_participant(meeting.room_name, target_identity)
    except Exception:
        pass
    views.log_audit(
        user=request.user,
        action="meeting.member_remove",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"target_user_id={target_user.id}, banned={ban_after_remove}",
        ip_address=views.client_ip(request),
    )
    return views.Response({"ok": True, "banned": ban_after_remove})
