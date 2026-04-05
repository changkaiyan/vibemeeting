from conference import views
from conference.services import member_controls, participant_controls


def _meeting_member_control(request, meeting_id: int, target_user_id: int, action: str):
    meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_member_control_impl(request, meeting, target_user_id, action, meeting_id)


def _meeting_member_control_impl(request, meeting, target_user_id: int, action: str, resource_id_for_log: int):
    actor_membership = views.meeting_membership(meeting.id, request.user.id)
    target = views.MeetingMember.objects.filter(meeting=meeting, user_id=target_user_id).select_related("user").first()
    if not target:
        return views.Response({"detail": "Member not found"}, status=views.status.HTTP_404_NOT_FOUND)

    member_handlers = {
        "role": member_controls.handle_role_action,
        "mute": member_controls.handle_mute_action,
        "video": member_controls.handle_video_action,
        "mic_permission": lambda req, mtg, actor, member, resource_id: member_controls.handle_permission_action(
            req,
            mtg,
            actor,
            member,
            resource_id,
            action="mic_permission",
        ),
        "video_permission": lambda req, mtg, actor, member, resource_id: member_controls.handle_permission_action(
            req,
            mtg,
            actor,
            member,
            resource_id,
            action="video_permission",
        ),
        "chat_permission": lambda req, mtg, actor, member, resource_id: member_controls.handle_permission_action(
            req,
            mtg,
            actor,
            member,
            resource_id,
            action="chat_permission",
        ),
        "screen_share_permission": lambda req, mtg, actor, member, resource_id: member_controls.handle_permission_action(
            req,
            mtg,
            actor,
            member,
            resource_id,
            action="screen_share_permission",
        ),
        "display_name": member_controls.handle_display_name_action,
        "stop_share": member_controls.handle_stop_share_action,
        "remove": member_controls.handle_remove_action,
    }
    handler = member_handlers.get(action)
    if handler:
        return handler(
            request,
            meeting,
            actor_membership,
            target,
            resource_id_for_log,
        )

    return views.Response({"detail": "Unsupported action"}, status=views.status.HTTP_400_BAD_REQUEST)

def _meeting_participant_control(request, meeting_id: int, participant_identity: str, action: str):
    meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return _meeting_participant_control_impl(
        request,
        meeting,
        participant_identity,
        action,
        meeting_id,
    )


def _meeting_participant_control_impl(
    request,
    meeting,
    participant_identity: str,
    action: str,
    resource_id_for_log: int,
):
    actor_membership = views.meeting_membership(meeting.id, request.user.id)
    if not views.can_moderate(request.user, actor_membership):
        return views.Response(
            {"detail": "Only host/cohost can manage participants"},
            status=views.status.HTTP_403_FORBIDDEN,
        )

    identity, error = participant_controls.validate_guest_participant_identity(participant_identity)
    if error:
        return error

    participant_handlers = {
        "detail": participant_controls.handle_detail_action,
        "mute": participant_controls.handle_mute_action,
        "video": participant_controls.handle_video_action,
        "mic_permission": lambda req, mtg, ident, resource_id: participant_controls.handle_permission_action(
            req,
            mtg,
            ident,
            resource_id,
            action="mic_permission",
        ),
        "video_permission": lambda req, mtg, ident, resource_id: participant_controls.handle_permission_action(
            req,
            mtg,
            ident,
            resource_id,
            action="video_permission",
        ),
        "chat_permission": lambda req, mtg, ident, resource_id: participant_controls.handle_permission_action(
            req,
            mtg,
            ident,
            resource_id,
            action="chat_permission",
        ),
        "screen_share_permission": lambda req, mtg, ident, resource_id: participant_controls.handle_permission_action(
            req,
            mtg,
            ident,
            resource_id,
            action="screen_share_permission",
        ),
        "display_name": participant_controls.handle_display_name_action,
        "stop_share": participant_controls.handle_stop_share_action,
        "remove": participant_controls.handle_remove_action,
    }
    handler = participant_handlers.get(action)
    if handler:
        return handler(
            request,
            meeting,
            identity,
            resource_id_for_log,
        )

    return views.Response({"detail": "Unsupported action"}, status=views.status.HTTP_400_BAD_REQUEST)

def _meeting_host_leave_impl(request, meeting, resource_id_for_log: int):
    actor_membership = views.meeting_membership(meeting.id, request.user.id)
    if not actor_membership or actor_membership.role != views.MeetingRole.HOST:
        return views.Response({"detail": "Only host can end or transfer meeting"}, status=views.status.HTTP_403_FORBIDDEN)

    serializer = views.MeetingHostLeaveSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    transfer_user_id = serializer.validated_data.get("transfer_user_id")
    online_user_ids = views._list_registered_participant_user_ids(meeting)

    if transfer_user_id is not None:
        if online_user_ids is None:
            return views.Response(
                {"detail": "Unable to verify participant presence. Please try again."},
                status=views.status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        if transfer_user_id not in online_user_ids:
            return views.Response(
                {"detail": "Target user is not currently in meeting"},
                status=views.status.HTTP_400_BAD_REQUEST,
            )
        target = views.MeetingMember.objects.filter(meeting=meeting, user_id=transfer_user_id).select_related("user").first()
        if not target:
            return views.Response({"detail": "Target user not found"}, status=views.status.HTTP_404_NOT_FOUND)
        if target.user_id == request.user.id:
            return views.Response({"detail": "Cannot transfer host to yourself"}, status=views.status.HTTP_400_BAD_REQUEST)
        with views.transaction.atomic():
            target.role = views.MeetingRole.HOST
            target.save(update_fields=["role"])
            actor_membership.delete()
            if meeting.owner_id != target.user_id:
                views._transfer_meeting_owner_with_session_usage(meeting, new_owner=target.user)
        try:
            views._sync_livekit_permissions_for_member(meeting, target)
        except Exception:
            pass
        views.log_audit(
            user=request.user,
            action="meeting.host_leave_transfer",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"handover_to_user_id={target.user_id}",
            ip_address=views.client_ip(request),
        )
        return views.Response(
            {
                "ok": True,
                "meeting_ended": False,
                "handover_to_user_id": target.user_id,
            }
        )

    next_host = (
        views.MeetingMember.objects.filter(meeting=meeting, role=views.MeetingRole.COHOST)
        .exclude(user=request.user)
        .select_related("user")
        .order_by("created_at")
        .first()
    )
    if next_host:
        with views.transaction.atomic():
            next_host.role = views.MeetingRole.HOST
            next_host.save(update_fields=["role"])
            actor_membership.delete()
            if meeting.owner_id != next_host.user_id:
                views._transfer_meeting_owner_with_session_usage(meeting, new_owner=next_host.user)
        try:
            views._sync_livekit_permissions_for_member(meeting, next_host)
        except Exception:
            pass
        views.log_audit(
            user=request.user,
            action="meeting.host_leave_auto_handover",
            resource_type="meeting",
            resource_id=resource_id_for_log,
            detail=f"handover_to_user_id={next_host.user_id}",
            ip_address=views.client_ip(request),
        )
        return views.Response(
            {
                "ok": True,
                "meeting_ended": False,
                "handover_to_user_id": next_host.user_id,
                "auto_handover": True,
            }
        )

    room_name = meeting.room_name
    deleted_meeting_id = meeting.id
    views._finalize_room_session_if_needed(meeting)
    meeting.delete()
    try:
        views.livekit_service.delete_room(room_name)
    except Exception:
        pass
    views.log_audit(
        user=request.user,
        action="meeting.host_leave_end_no_cohost",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"deleted_meeting_id={deleted_meeting_id}, room={room_name}",
        ip_address=views.client_ip(request),
    )
    return views.Response(
        {
            "ok": True,
            "meeting_ended": True,
            "deleted_meeting_id": deleted_meeting_id,
        }
    )


def _meeting_controls_impl(request, meeting, resource_id_for_log: int):
    actor_membership = views.meeting_membership(meeting.id, request.user.id)
    if not views.can_moderate(request.user, actor_membership):
        return views.Response({"detail": "Only host/cohost can update meeting controls"}, status=views.status.HTTP_403_FORBIDDEN)

    serializer = views.MeetingControlUpdateSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    payload = serializer.validated_data
    if not payload:
        return views.Response(views.MeetingSerializer(meeting, context={"request": request}).data)

    views._apply_meeting_payload(meeting, payload)
    meeting.save(update_fields=list(payload.keys()))
    members = views.MeetingMember.objects.filter(meeting=meeting).select_related("user")
    views._sync_livekit_permissions_for_members(meeting, members)
    views._sync_livekit_permissions_for_guest_participants(meeting)
    views.log_audit(
        user=request.user,
        action="meeting.controls_update",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"fields={','.join(payload.keys())}",
        ip_address=views.client_ip(request),
    )
    return views.Response(views.MeetingSerializer(meeting, context={"request": request}).data)


def _meeting_mute_all_impl(request, meeting, resource_id_for_log: int):
    actor_membership = views.meeting_membership(meeting.id, request.user.id)
    if not views.can_moderate(request.user, actor_membership):
        return views.Response({"detail": "Only host/cohost can mute all members"}, status=views.status.HTTP_403_FORBIDDEN)

    targets = list(
        views.MeetingMember.objects.filter(meeting=meeting)
        .exclude(role=views.MeetingRole.HOST)
        .exclude(user=request.user)
        .select_related("user")
    )
    if targets:
        target_ids = [row.id for row in targets]
        views.MeetingMember.objects.filter(id__in=target_ids).update(muted_by_host=True)
        for row in targets:
            row.muted_by_host = True
        views._sync_livekit_permissions_for_members(meeting, targets)
    guest_identities = views._list_guest_participant_identities(meeting)
    muted_guest_count = 0
    for identity in guest_identities:
        try:
            sources = views._resolved_guest_publish_sources(meeting, identity)
            if meeting.allow_self_unmute:
                sources.add("microphone")
            else:
                sources.discard("microphone")
            effective_sources = views._effective_guest_publish_sources(meeting, sources)
            views._sync_livekit_permissions_for_guest_participant(
                meeting,
                identity,
                publish_sources=effective_sources,
            )
            views.livekit_service.mute_participant_track_sources(
                meeting.room_name,
                identity,
                track_sources=["microphone"],
                muted=True,
            )
            muted_guest_count += 1
        except Exception:
            continue
    views.log_audit(
        user=request.user,
        action="meeting.mute_all",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"muted_count={len(targets) + muted_guest_count}",
        ip_address=views.client_ip(request),
    )
    return views.Response({"ok": True, "muted_count": len(targets) + muted_guest_count})


def _meeting_waiting_room_entries_impl(request, meeting, resource_id_for_log: int | None = None):
    actor_membership = views.meeting_membership(meeting.id, request.user.id)
    if not views.can_moderate(request.user, actor_membership):
        return views.Response({"detail": "Only host/cohost can manage waiting room"}, status=views.status.HTTP_403_FORBIDDEN)

    status_filter = (request.GET.get("status") or "").strip().lower()
    include_reviewed = views._bool_value(request.GET.get("all"), default=False)
    entries = views.MeetingWaitingRoomEntry.objects.filter(meeting=meeting)
    if status_filter in {
        views.WaitingRoomStatus.PENDING,
        views.WaitingRoomStatus.APPROVED,
        views.WaitingRoomStatus.REJECTED,
    }:
        entries = entries.filter(status=status_filter)
    elif not include_reviewed:
        entries = entries.filter(status=views.WaitingRoomStatus.PENDING)
    entries = entries.select_related("user", "reviewed_by").order_by("created_at")
    return views.Response(views.MeetingWaitingRoomEntrySerializer(entries, many=True).data)


def _meeting_waiting_room_review_impl(request, meeting, target_user_id: int, resource_id_for_log: int):
    actor_membership = views.meeting_membership(meeting.id, request.user.id)
    if not views.can_moderate(request.user, actor_membership):
        return views.Response({"detail": "Only host/cohost can manage waiting room"}, status=views.status.HTTP_403_FORBIDDEN)

    target_user = views.User.objects.filter(id=target_user_id).first()
    if not target_user:
        return views.Response({"detail": "Target user not found"}, status=views.status.HTTP_404_NOT_FOUND)

    serializer = views.WaitingRoomReviewSerializer(data=request.data)
    serializer.is_valid(raise_exception=True)
    next_status = serializer.validated_data["status"]

    if next_status == views.WaitingRoomStatus.APPROVED:
        with views.transaction.atomic():
            views.MeetingBlockedMember.objects.filter(meeting=meeting, user=target_user).delete()
            member = views.MeetingMember.objects.filter(meeting=meeting, user=target_user).first()
            if not member:
                member_count = views.MeetingMember.objects.filter(meeting=meeting).count()
                if member_count >= meeting.max_participants:
                    return views.Response(
                        {"detail": "Meeting has reached max participants"},
                        status=views.status.HTTP_400_BAD_REQUEST,
                    )
                member = views.MeetingMember.objects.create(
                    meeting=meeting,
                    user=target_user,
                    role=views.MeetingRole.PARTICIPANT,
                    display_name=views._fallback_display_name(target_user),
                    muted_by_host=meeting.mute_on_entry,
                )
            entry = views._mark_waiting_room_status(
                meeting,
                target_user,
                views.WaitingRoomStatus.APPROVED,
                reviewed_by=request.user,
            )
        try:
            views._sync_livekit_permissions_for_member(meeting, member)
        except Exception:
            pass
    elif next_status == views.WaitingRoomStatus.REJECTED:
        entry = views._mark_waiting_room_status(
            meeting,
            target_user,
            views.WaitingRoomStatus.REJECTED,
            reviewed_by=request.user,
        )
    else:
        entry = views._mark_waiting_room_status(
            meeting,
            target_user,
            views.WaitingRoomStatus.PENDING,
            reviewed_by=request.user,
        )

    views.log_audit(
        user=request.user,
        action="meeting.waiting_room_review",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"target_user_id={target_user_id}, status={next_status}",
        ip_address=views.client_ip(request),
    )
    return views.Response(views.MeetingWaitingRoomEntrySerializer(entry).data)


def _meeting_blocked_members_impl(request, meeting, resource_id_for_log: int | None = None):
    actor_membership = views.meeting_membership(meeting.id, request.user.id)
    if not views.can_moderate(request.user, actor_membership):
        return views.Response({"detail": "Only host/cohost can view blocked members"}, status=views.status.HTTP_403_FORBIDDEN)
    rows = views.MeetingBlockedMember.objects.filter(meeting=meeting).select_related("user", "blocked_by").order_by("-created_at")
    return views.Response(views.MeetingBlockedMemberSerializer(rows, many=True).data)


def _meeting_unblock_member_impl(request, meeting, target_user_id: int, resource_id_for_log: int):
    actor_membership = views.meeting_membership(meeting.id, request.user.id)
    if not views.can_moderate(request.user, actor_membership):
        return views.Response({"detail": "Only host/cohost can unblock members"}, status=views.status.HTTP_403_FORBIDDEN)

    blocked = views.MeetingBlockedMember.objects.filter(meeting=meeting, user_id=target_user_id).first()
    if not blocked:
        return views.Response({"detail": "Blocked member not found"}, status=views.status.HTTP_404_NOT_FOUND)
    blocked.delete()
    views.log_audit(
        user=request.user,
        action="meeting.member_unblock",
        resource_type="meeting",
        resource_id=resource_id_for_log,
        detail=f"target_user_id={target_user_id}",
        ip_address=views.client_ip(request),
    )
    return views.Response({"ok": True})
