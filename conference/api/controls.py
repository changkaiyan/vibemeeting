from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated

from conference import views
from conference.services import meeting_controls as meeting_controls_service


def _resolve_ref_meeting(request, meeting_ref: str):
    return views._meeting_for_user_ref_or_404(request.user, meeting_ref)


def _service_view(methods, handler):
    @api_view(methods)
    @permission_classes([IsAuthenticated])
    def view(request, *args, **kwargs):
        return handler(request, *args, **kwargs)

    return view


def _meeting_action_view(methods, service_impl):
    def handler(request, meeting_id: int):
        meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
        if error:
            return error
        return service_impl(request, meeting, meeting_id)

    return _service_view(methods, handler)


def _meeting_action_ref_view(methods, service_impl):
    def handler(request, meeting_ref: str):
        meeting, error = _resolve_ref_meeting(request, meeting_ref)
        if error:
            return error
        return service_impl(request, meeting, meeting.id)

    return _service_view(methods, handler)


def _member_control_view(action: str, methods):
    def handler(request, meeting_id: int, target_user_id: int):
        return meeting_controls_service._meeting_member_control(
            request,
            meeting_id,
            target_user_id,
            action,
        )

    return _service_view(methods, handler)


def _member_control_ref_view(action: str, methods):
    def handler(request, meeting_ref: str, target_user_id: int):
        meeting, error = _resolve_ref_meeting(request, meeting_ref)
        if error:
            return error
        return meeting_controls_service._meeting_member_control_impl(
            request,
            meeting,
            target_user_id,
            action,
            meeting.id,
        )

    return _service_view(methods, handler)


def _participant_action(request, participant_identity: str):
    return "detail" if request.method == "GET" else "remove"


def _participant_control_view(action: str, methods):
    def handler(request, meeting_id: int, participant_identity: str):
        resolved_action = action(request, participant_identity) if callable(action) else action
        return meeting_controls_service._meeting_participant_control(
            request,
            meeting_id,
            participant_identity,
            resolved_action,
        )

    return _service_view(methods, handler)


def _participant_control_ref_view(action: str, methods):
    def handler(request, meeting_ref: str, participant_identity: str):
        meeting, error = _resolve_ref_meeting(request, meeting_ref)
        if error:
            return error
        resolved_action = action(request, participant_identity) if callable(action) else action
        return meeting_controls_service._meeting_participant_control_impl(
            request,
            meeting,
            participant_identity,
            resolved_action,
            meeting.id,
        )

    return _service_view(methods, handler)


def _waiting_room_review_view(methods):
    def handler(request, meeting_id: int, target_user_id: int):
        meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
        if error:
            return error
        return meeting_controls_service._meeting_waiting_room_review_impl(
            request,
            meeting,
            target_user_id,
            meeting_id,
        )

    return _service_view(methods, handler)


def _waiting_room_review_ref_view(methods):
    def handler(request, meeting_ref: str, target_user_id: int):
        meeting, error = _resolve_ref_meeting(request, meeting_ref)
        if error:
            return error
        return meeting_controls_service._meeting_waiting_room_review_impl(
            request,
            meeting,
            target_user_id,
            meeting.id,
        )

    return _service_view(methods, handler)


def _unblock_member_view(methods):
    def handler(request, meeting_id: int, target_user_id: int):
        meeting, error = views._meeting_for_user_or_403(request.user, meeting_id)
        if error:
            return error
        return meeting_controls_service._meeting_unblock_member_impl(
            request,
            meeting,
            target_user_id,
            meeting_id,
        )

    return _service_view(methods, handler)


def _unblock_member_ref_view(methods):
    def handler(request, meeting_ref: str, target_user_id: int):
        meeting, error = _resolve_ref_meeting(request, meeting_ref)
        if error:
            return error
        return meeting_controls_service._meeting_unblock_member_impl(
            request,
            meeting,
            target_user_id,
            meeting.id,
        )

    return _service_view(methods, handler)


meeting_member_role = _member_control_view("role", ["PATCH"])
meeting_member_mute = _member_control_view("mute", ["PATCH"])
meeting_member_video = _member_control_view("video", ["PATCH"])
meeting_member_mic_permission = _member_control_view("mic_permission", ["PATCH"])
meeting_member_video_permission = _member_control_view("video_permission", ["PATCH"])
meeting_member_chat_permission = _member_control_view("chat_permission", ["PATCH"])
meeting_member_screen_share_permission = _member_control_view("screen_share_permission", ["PATCH"])
meeting_member_display_name_control = _member_control_view("display_name", ["PATCH"])
meeting_member_stop_share = _member_control_view("stop_share", ["POST"])
meeting_member_remove = _member_control_view("remove", ["DELETE"])

meeting_member_role_ref = _member_control_ref_view("role", ["PATCH"])
meeting_member_mute_ref = _member_control_ref_view("mute", ["PATCH"])
meeting_member_video_ref = _member_control_ref_view("video", ["PATCH"])
meeting_member_mic_permission_ref = _member_control_ref_view("mic_permission", ["PATCH"])
meeting_member_video_permission_ref = _member_control_ref_view("video_permission", ["PATCH"])
meeting_member_chat_permission_ref = _member_control_ref_view("chat_permission", ["PATCH"])
meeting_member_screen_share_permission_ref = _member_control_ref_view("screen_share_permission", ["PATCH"])
meeting_member_display_name_control_ref = _member_control_ref_view("display_name", ["PATCH"])
meeting_member_stop_share_ref = _member_control_ref_view("stop_share", ["POST"])
meeting_member_remove_ref = _member_control_ref_view("remove", ["DELETE"])

meeting_participant_mute = _participant_control_view("mute", ["PATCH"])
meeting_participant_video = _participant_control_view("video", ["PATCH"])
meeting_participant_mic_permission = _participant_control_view("mic_permission", ["PATCH"])
meeting_participant_video_permission = _participant_control_view("video_permission", ["PATCH"])
meeting_participant_chat_permission = _participant_control_view("chat_permission", ["PATCH"])
meeting_participant_screen_share_permission = _participant_control_view("screen_share_permission", ["PATCH"])
meeting_participant_display_name_control = _participant_control_view("display_name", ["PATCH"])
meeting_participant_stop_share = _participant_control_view("stop_share", ["POST"])
meeting_participant_remove = _participant_control_view(_participant_action, ["GET", "DELETE"])

meeting_participant_mute_ref = _participant_control_ref_view("mute", ["PATCH"])
meeting_participant_video_ref = _participant_control_ref_view("video", ["PATCH"])
meeting_participant_mic_permission_ref = _participant_control_ref_view("mic_permission", ["PATCH"])
meeting_participant_video_permission_ref = _participant_control_ref_view("video_permission", ["PATCH"])
meeting_participant_chat_permission_ref = _participant_control_ref_view("chat_permission", ["PATCH"])
meeting_participant_screen_share_permission_ref = _participant_control_ref_view("screen_share_permission", ["PATCH"])
meeting_participant_display_name_control_ref = _participant_control_ref_view("display_name", ["PATCH"])
meeting_participant_stop_share_ref = _participant_control_ref_view("stop_share", ["POST"])
meeting_participant_remove_ref = _participant_control_ref_view(_participant_action, ["GET", "DELETE"])

meeting_host_leave = _meeting_action_view(["POST"], meeting_controls_service._meeting_host_leave_impl)
meeting_host_leave_ref = _meeting_action_ref_view(["POST"], meeting_controls_service._meeting_host_leave_impl)
meeting_controls = _meeting_action_view(["PATCH"], meeting_controls_service._meeting_controls_impl)
meeting_controls_ref = _meeting_action_ref_view(["PATCH"], meeting_controls_service._meeting_controls_impl)
meeting_mute_all = _meeting_action_view(["POST"], meeting_controls_service._meeting_mute_all_impl)
meeting_mute_all_ref = _meeting_action_ref_view(["POST"], meeting_controls_service._meeting_mute_all_impl)
meeting_waiting_room_entries = _meeting_action_view(
    ["GET"],
    meeting_controls_service._meeting_waiting_room_entries_impl,
)
meeting_waiting_room_entries_ref = _meeting_action_ref_view(
    ["GET"],
    meeting_controls_service._meeting_waiting_room_entries_impl,
)
meeting_waiting_room_review = _waiting_room_review_view(["PATCH"])
meeting_waiting_room_review_ref = _waiting_room_review_ref_view(["PATCH"])
meeting_blocked_members = _meeting_action_view(
    ["GET"],
    meeting_controls_service._meeting_blocked_members_impl,
)
meeting_blocked_members_ref = _meeting_action_ref_view(
    ["GET"],
    meeting_controls_service._meeting_blocked_members_impl,
)
meeting_unblock_member = _unblock_member_view(["DELETE"])
meeting_unblock_member_ref = _unblock_member_ref_view(["DELETE"])
