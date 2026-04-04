from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated

from conference.services import meeting_controls as meeting_controls_service
from conference import views


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_role(request, meeting_id: int, target_user_id: int):
    return meeting_controls_service._meeting_member_control(request, meeting_id, target_user_id, "role")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_mute(request, meeting_id: int, target_user_id: int):
    return meeting_controls_service._meeting_member_control(request, meeting_id, target_user_id, "mute")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_video(request, meeting_id: int, target_user_id: int):
    return meeting_controls_service._meeting_member_control(request, meeting_id, target_user_id, "video")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_mic_permission(request, meeting_id: int, target_user_id: int):
    return meeting_controls_service._meeting_member_control(request, meeting_id, target_user_id, "mic_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_video_permission(request, meeting_id: int, target_user_id: int):
    return meeting_controls_service._meeting_member_control(request, meeting_id, target_user_id, "video_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_chat_permission(request, meeting_id: int, target_user_id: int):
    return meeting_controls_service._meeting_member_control(request, meeting_id, target_user_id, "chat_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_screen_share_permission(request, meeting_id: int, target_user_id: int):
    return meeting_controls_service._meeting_member_control(request, meeting_id, target_user_id, "screen_share_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_display_name_control(request, meeting_id: int, target_user_id: int):
    return meeting_controls_service._meeting_member_control(request, meeting_id, target_user_id, "display_name")


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_member_stop_share(request, meeting_id: int, target_user_id: int):
    return meeting_controls_service._meeting_member_control(request, meeting_id, target_user_id, "stop_share")


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def meeting_member_remove(request, meeting_id: int, target_user_id: int):
    return meeting_controls_service._meeting_member_control(request, meeting_id, target_user_id, "remove")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_mute(request, meeting_id: int, participant_identity: str):
    return meeting_controls_service._meeting_participant_control(request, meeting_id, participant_identity, "mute")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_video(request, meeting_id: int, participant_identity: str):
    return meeting_controls_service._meeting_participant_control(request, meeting_id, participant_identity, "video")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_mic_permission(request, meeting_id: int, participant_identity: str):
    return meeting_controls_service._meeting_participant_control(request, meeting_id, participant_identity, "mic_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_video_permission(request, meeting_id: int, participant_identity: str):
    return meeting_controls_service._meeting_participant_control(request, meeting_id, participant_identity, "video_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_chat_permission(request, meeting_id: int, participant_identity: str):
    return meeting_controls_service._meeting_participant_control(request, meeting_id, participant_identity, "chat_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_screen_share_permission(request, meeting_id: int, participant_identity: str):
    return meeting_controls_service._meeting_participant_control(request, meeting_id, participant_identity, "screen_share_permission")


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_display_name_control(request, meeting_id: int, participant_identity: str):
    return meeting_controls_service._meeting_participant_control(request, meeting_id, participant_identity, "display_name")


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_participant_stop_share(request, meeting_id: int, participant_identity: str):
    return meeting_controls_service._meeting_participant_control(request, meeting_id, participant_identity, "stop_share")


@api_view(["GET", "DELETE"])
@permission_classes([IsAuthenticated])
def meeting_participant_remove(request, meeting_id: int, participant_identity: str):
    action = "detail" if request.method == "GET" else "remove"
    return meeting_controls_service._meeting_participant_control(request, meeting_id, participant_identity, action)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_role_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_member_control_impl(request, meeting, target_user_id, "role", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_mute_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_member_control_impl(request, meeting, target_user_id, "mute", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_video_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_member_control_impl(request, meeting, target_user_id, "video", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_mic_permission_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_member_control_impl(request, meeting, target_user_id, "mic_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_video_permission_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_member_control_impl(request, meeting, target_user_id, "video_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_chat_permission_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_member_control_impl(request, meeting, target_user_id, "chat_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_screen_share_permission_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_member_control_impl(request, meeting, target_user_id, "screen_share_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_member_display_name_control_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_member_control_impl(request, meeting, target_user_id, "display_name", meeting.id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_member_stop_share_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_member_control_impl(request, meeting, target_user_id, "stop_share", meeting.id)


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def meeting_member_remove_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_member_control_impl(request, meeting, target_user_id, "remove", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_mute_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_participant_control_impl(request, meeting, participant_identity, "mute", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_video_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_participant_control_impl(request, meeting, participant_identity, "video", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_mic_permission_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_participant_control_impl(request, meeting, participant_identity, "mic_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_video_permission_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_participant_control_impl(request, meeting, participant_identity, "video_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_chat_permission_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_participant_control_impl(request, meeting, participant_identity, "chat_permission", meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_screen_share_permission_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_participant_control_impl(
        request,
        meeting,
        participant_identity,
        "screen_share_permission",
        meeting.id,
    )


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_participant_display_name_control_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_participant_control_impl(request, meeting, participant_identity, "display_name", meeting.id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_participant_stop_share_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_participant_control_impl(request, meeting, participant_identity, "stop_share", meeting.id)


@api_view(["GET", "DELETE"])
@permission_classes([IsAuthenticated])
def meeting_participant_remove_ref(request, meeting_ref: str, participant_identity: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    action = "detail" if request.method == "GET" else "remove"
    return meeting_controls_service._meeting_participant_control_impl(request, meeting, participant_identity, action, meeting.id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_host_leave(request, meeting_id: int):
    meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return meeting_controls_service._meeting_host_leave_impl(request, meeting, meeting_id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_host_leave_ref(request, meeting_ref: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_host_leave_impl(request, meeting, meeting.id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_controls(request, meeting_id: int):
    meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return meeting_controls_service._meeting_controls_impl(request, meeting, meeting_id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_controls_ref(request, meeting_ref: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_controls_impl(request, meeting, meeting.id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_mute_all(request, meeting_id: int):
    meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return meeting_controls_service._meeting_mute_all_impl(request, meeting, meeting_id)


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def meeting_mute_all_ref(request, meeting_ref: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_mute_all_impl(request, meeting, meeting.id)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_waiting_room_entries(request, meeting_id: int):
    meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return meeting_controls_service._meeting_waiting_room_entries_impl(request, meeting)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_waiting_room_entries_ref(request, meeting_ref: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_waiting_room_entries_impl(request, meeting)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_waiting_room_review(request, meeting_id: int, target_user_id: int):
    meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return meeting_controls_service._meeting_waiting_room_review_impl(request, meeting, target_user_id, meeting_id)


@api_view(["PATCH"])
@permission_classes([IsAuthenticated])
def meeting_waiting_room_review_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_waiting_room_review_impl(request, meeting, target_user_id, meeting.id)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_blocked_members(request, meeting_id: int):
    meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return meeting_controls_service._meeting_blocked_members_impl(request, meeting)


@api_view(["GET"])
@permission_classes([IsAuthenticated])
def meeting_blocked_members_ref(request, meeting_ref: str):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_blocked_members_impl(request, meeting)


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def meeting_unblock_member(request, meeting_id: int, target_user_id: int):
    meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
    if error:
        return error
    return meeting_controls_service._meeting_unblock_member_impl(request, meeting, target_user_id, meeting_id)


@api_view(["DELETE"])
@permission_classes([IsAuthenticated])
def meeting_unblock_member_ref(request, meeting_ref: str, target_user_id: int):
    meeting, error = views._meeting_for_user_ref_or_404(request.user, meeting_ref)
    if error:
        return error
    return meeting_controls_service._meeting_unblock_member_impl(request, meeting, target_user_id, meeting.id)
