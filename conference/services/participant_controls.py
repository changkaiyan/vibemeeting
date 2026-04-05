from conference import views


def validate_guest_participant_identity(identity: str):
    normalized_identity = (identity or "").strip()
    if not normalized_identity:
        return None, views.Response({"detail": "Participant identity is required"}, status=views.status.HTTP_400_BAD_REQUEST)
    if views._user_id_from_participant_identity(normalized_identity) is not None:
        return None, views.Response(
            {"detail": "Registered members should be managed by member id"},
            status=views.status.HTTP_400_BAD_REQUEST,
        )
    return normalized_identity, None


def handle_detail_action(request, meeting, identity: str, resource_id_for_log: int):
    livekit_name = views._livekit_participant_name(meeting, identity).strip()
    guest = views._ensure_guest_participant_record(
        meeting,
        identity,
        fallback_display_name=livekit_name,
    )
    return views.Response(
        {
            "ok": True,
            "identity": identity,
            "display_name": guest.display_name,
            "display_name_version": guest.display_name_version,
            "livekit_display_name": livekit_name,
        }
    )


def guest_permission_payload(publish_sources, can_publish_data: bool):
    source_set = set(publish_sources)
    return {
        "allow_self_unmute": "microphone" in source_set,
        "allow_member_video": "camera" in source_set,
        "allow_screen_share": "screen_share" in source_set or "screen_share_audio" in source_set,
        "allow_chat": bool(can_publish_data),
    }


def handle_mute_action(request, meeting, identity: str, resource_id_for_log: int):
    serializer = views.MeetingMuteSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    muted = serializer.validated_data["muted"]
    sources = views._resolved_guest_publish_sources(meeting, identity)
    effective_sources = views._effective_guest_publish_sources(meeting, sources)
    effective_source_set = set(effective_sources)
    if not muted and "microphone" not in effective_source_set:
        return views.Response(
            {"detail": "Participant has no microphone permission. Allow mic first."},
            status=views.status.HTTP_400_BAD_REQUEST,
        )
    can_publish_data = views._resolved_guest_publish_data_allowed(meeting, identity)
    try:
        views._sync_livekit_permissions_for_guest_participant(
            meeting,
            identity,
            publish_sources=effective_sources,
            can_publish_data=can_publish_data,
            force_unmute_microphone=not muted,
        )
        if not muted:
            views._request_participant_device_open(meeting, identity, open_microphone=True)
        if muted:
            views.livekit_service.mute_participant_track_sources(
                meeting.room_name,
                identity,
                track_sources=["microphone"],
                muted=True,
            )
    except Exception:
        pass
    views.log_audit(
        user=request.user,
        action="meeting.participant_mute",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"participant_identity={identity}, muted={muted}",
        ip_address=views.client_ip(request),
    )
    return views.Response(
        {
            "ok": True,
            "identity": identity,
            "muted": muted,
            **guest_permission_payload(effective_sources, can_publish_data),
        }
    )


def handle_video_action(request, meeting, identity: str, resource_id_for_log: int):
    serializer = views.MeetingVideoControlSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    disabled = serializer.validated_data["disabled"]
    sources = views._resolved_guest_publish_sources(meeting, identity)
    effective_sources = views._effective_guest_publish_sources(meeting, sources)
    effective_source_set = set(effective_sources)
    if not disabled and "camera" not in effective_source_set:
        return views.Response(
            {"detail": "Participant has no camera permission. Allow video first."},
            status=views.status.HTTP_400_BAD_REQUEST,
        )
    can_publish_data = views._resolved_guest_publish_data_allowed(meeting, identity)
    try:
        views._sync_livekit_permissions_for_guest_participant(
            meeting,
            identity,
            publish_sources=effective_sources,
            can_publish_data=can_publish_data,
            force_unmute_camera=not disabled,
        )
        if not disabled:
            views._request_participant_device_open(meeting, identity, open_camera=True)
        if disabled:
            views.livekit_service.mute_participant_track_sources(
                meeting.room_name,
                identity,
                track_sources=["camera"],
                muted=True,
            )
    except Exception:
        pass
    views.log_audit(
        user=request.user,
        action="meeting.participant_video_control",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"participant_identity={identity}, disabled={disabled}",
        ip_address=views.client_ip(request),
    )
    return views.Response(
        {
            "ok": True,
            "identity": identity,
            "disabled": disabled,
            **guest_permission_payload(effective_sources, can_publish_data),
        }
    )


def handle_permission_action(request, meeting, identity: str, resource_id_for_log: int, *, action: str):
    if action == "chat_permission":
        return views.Response(
            {"detail": "Guest chat permission follows meeting-level controls and cannot be overridden per participant"},
            status=views.status.HTTP_400_BAD_REQUEST,
        )

    serializer = views.MeetingPermissionControlSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    allowed = serializer.validated_data["allowed"]
    sources = views._resolved_guest_publish_sources(meeting, identity)
    can_publish_data = views._resolved_guest_publish_data_allowed(meeting, identity)

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
    else:
        if allowed:
            sources.update({"screen_share", "screen_share_audio"})
        else:
            sources.discard("screen_share")
            sources.discard("screen_share_audio")
        audit_action = "meeting.participant_screen_share_permission"

    effective_sources = views._effective_guest_publish_sources(meeting, sources)
    effective_can_publish_data = bool(can_publish_data and meeting.allow_chat)
    try:
        views._sync_livekit_permissions_for_guest_participant(
            meeting,
            identity,
            publish_sources=effective_sources,
            can_publish_data=effective_can_publish_data,
        )
        if action == "screen_share_permission" and not allowed:
            views.livekit_service.mute_participant_track_sources(
                meeting.room_name,
                identity,
                track_sources=["screen_share", "screen_share_audio"],
                muted=True,
            )
    except Exception:
        pass
    views.log_audit(
        user=request.user,
        action=audit_action,
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"participant_identity={identity}, allowed={allowed}",
        ip_address=views.client_ip(request),
    )
    return views.Response(
        {
            "ok": True,
            "identity": identity,
            **guest_permission_payload(effective_sources, effective_can_publish_data),
        }
    )


def handle_display_name_action(request, meeting, identity: str, resource_id_for_log: int):
    serializer = views.MeetingMemberDisplayNameControlSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    next_display_name = serializer.validated_data["display_name"].strip()
    expected_display_name_version = serializer.validated_data.get("expected_display_name_version")
    guest, conflict = views._update_guest_display_name_consistently(
        meeting,
        identity,
        next_display_name=next_display_name,
        expected_display_name_version=expected_display_name_version,
    )
    if conflict is not None:
        return views._display_name_conflict_response(
            current_display_name=conflict.display_name,
            current_display_name_version=conflict.display_name_version,
        )
    try:
        views.livekit_service.update_participant_name(
            meeting.room_name,
            identity,
            name=guest.display_name,
        )
    except Exception:
        pass
    views.log_audit(
        user=request.user,
        action="meeting.participant_display_name_control",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=(
            f"participant_identity={identity}, "
            f"display_name={guest.display_name}, "
            f"display_name_version={guest.display_name_version}"
        ),
        ip_address=views.client_ip(request),
    )
    return views.Response(
        {
            "ok": True,
            "identity": identity,
            "display_name": guest.display_name,
            "display_name_version": guest.display_name_version,
        }
    )


def handle_stop_share_action(request, meeting, identity: str, resource_id_for_log: int):
    try:
        views.livekit_service.mute_participant_track_sources(
            meeting.room_name,
            identity,
            track_sources=["screen_share", "screen_share_audio"],
            muted=True,
        )
    except Exception:
        pass
    views.log_audit(
        user=request.user,
        action="meeting.participant_stop_share",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"participant_identity={identity}",
        ip_address=views.client_ip(request),
    )
    return views.Response({"ok": True, "identity": identity})


def handle_remove_action(request, meeting, identity: str, resource_id_for_log: int):
    views.MeetingGuestParticipant.objects.filter(
        meeting=meeting,
        participant_identity=identity,
    ).delete()
    try:
        views.livekit_service.remove_participant(meeting.room_name, identity)
    except Exception:
        pass
    views.log_audit(
        user=request.user,
        action="meeting.participant_remove",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"participant_identity={identity}",
        ip_address=views.client_ip(request),
    )
    return views.Response({"ok": True, "identity": identity, "banned": False})
