import json
import os
import tempfile
import base64
import hashlib
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from django.conf import settings
from django.contrib.auth.models import User
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from django.utils import timezone
from livekit import api as lk_api
from livekit.api.twirp_client import TwirpError
from livekit.protocol import egress as lk_egress
from rest_framework.test import APIClient

from conference.models import (
    BillingPlan,
    Meeting,
    MeetingBlockedMember,
    MeetingMember,
    MeetingGuestParticipant,
    MeetingMessage,
    MeetingRecording,
    MeetingRole,
    RecordingStorageConfig,
    MeetingWaitingRoomEntry,
    UserBillingProfile,
    WaitingRoomStatus,
)
from conference.meeting_refs import ensure_meeting_ref
from conference.share import build_meeting_share_code


class MeetingControlPolicyTests(TestCase):
    def setUp(self):
        self.host = User.objects.create_user(username="host", password="pass1234")
        self.participant = User.objects.create_user(username="participant", password="pass1234")
        self.meeting = Meeting.objects.create(
            title="Team Sync",
            room_name="room-policy-test",
            owner=self.host,
            waiting_room_enabled=True,
            allow_chat=False,
            allow_screen_share=False,
            mute_on_entry=True,
            allow_recording=True,
            max_participants=20,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.host,
            role=MeetingRole.HOST,
            muted_by_host=False,
        )

    def _auth_client(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def test_waiting_room_blocks_uninvited_join(self):
        client = self._auth_client(self.participant)
        response = client.post(
            "/api/meetings/join",
            {"room_name": self.meeting.room_name},
            format="json",
        )
        self.assertEqual(response.status_code, 403)
        payload = response.json()
        self.assertIn("waiting room enabled", payload.get("detail", "").lower())
        self.assertEqual(payload.get("waiting_room_status"), WaitingRoomStatus.PENDING)
        self.assertEqual(payload.get("room_name"), self.meeting.room_name)
        self.assertTrue((payload.get("meeting_ref") or "").strip())

    def test_host_leave_without_cohost_auto_ends_meeting(self):
        client = self._auth_client(self.host)
        response = client.post(
            f"/api/meetings/{self.meeting.id}/host-leave",
            {},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json().get("meeting_ended"))
        self.assertFalse(Meeting.objects.filter(id=self.meeting.id).exists())

    def test_join_token_applies_chat_and_screen_share_controls(self):
        self.meeting.mute_on_entry = False
        self.meeting.waiting_room_enabled = False
        self.meeting.save(update_fields=["mute_on_entry", "waiting_room_enabled"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        client = self._auth_client(self.participant)
        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ) as create_token:
            response = client.post(
                f"/api/meetings/{self.meeting.id}/join-token",
                {"display_name": "Participant"},
                format="json",
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertFalse(payload["allow_chat"])
        self.assertFalse(payload["allow_screen_share"])
        self.assertTrue(payload["can_publish"])

        kwargs = create_token.call_args.kwargs
        self.assertFalse(kwargs["can_publish_data"])
        self.assertCountEqual(kwargs["can_publish_sources"], ["camera", "microphone"])
        self.assertTrue(kwargs["can_update_own_metadata"])

    def test_join_token_sets_actual_started_at_once(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.save(update_fields=["waiting_room_enabled"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        client = self._auth_client(self.participant)

        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ):
            first_response = client.post(
                f"/api/meetings/{self.meeting.id}/join-token",
                {"display_name": "Participant"},
                format="json",
            )
        self.assertEqual(first_response.status_code, 200)
        self.meeting.refresh_from_db()
        first_started_at = self.meeting.actual_started_at
        self.assertIsNotNone(first_started_at)
        self.assertEqual(first_response.json().get("max_participants"), self.meeting.max_participants)
        self.assertTrue((first_response.json().get("actual_started_at") or "").strip())

        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token-2",
        ):
            second_response = client.post(
                f"/api/meetings/{self.meeting.id}/join-token",
                {"display_name": "Participant 2"},
                format="json",
            )
        self.assertEqual(second_response.status_code, 200)
        self.meeting.refresh_from_db()
        self.assertEqual(self.meeting.actual_started_at, first_started_at)

    def test_mute_on_entry_join_token_does_not_reject_and_marks_member_muted(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.mute_on_entry = True
        self.meeting.allow_self_unmute = False
        self.meeting.save(update_fields=["waiting_room_enabled", "mute_on_entry", "allow_self_unmute"])
        member = MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        client = self._auth_client(self.participant)

        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ) as create_token:
            response = client.post(
                f"/api/meetings/{self.meeting.id}/join-token",
                {"display_name": "Participant"},
                format="json",
            )

        self.assertEqual(response.status_code, 200)
        member.refresh_from_db()
        self.assertTrue(member.muted_by_host)
        kwargs = create_token.call_args.kwargs
        self.assertNotIn("microphone", kwargs["can_publish_sources"])

    def test_public_join_token_blocked_when_waiting_room_enabled(self):
        share_code = build_meeting_share_code(self.meeting.room_name)
        response = APIClient().post(
            f"/api/public/meetings/share/{share_code}/join-token",
            {"display_name": "Guest"},
            format="json",
        )
        self.assertEqual(response.status_code, 403)
        self.assertIn("waiting room enabled", response.json().get("detail", "").lower())

    def test_public_join_token_waiting_room_for_authenticated_user(self):
        share_code = build_meeting_share_code(self.meeting.room_name)
        participant_client = self._auth_client(self.participant)
        pending_response = participant_client.post(
            f"/api/public/meetings/share/{share_code}/join-token",
            {"display_name": "Participant"},
            format="json",
        )
        self.assertEqual(pending_response.status_code, 403)
        pending_payload = pending_response.json()
        self.assertEqual(pending_payload.get("waiting_room_status"), WaitingRoomStatus.PENDING)
        self.assertTrue((pending_payload.get("meeting_ref") or "").strip())

        host_client = self._auth_client(self.host)
        review_response = host_client.patch(
            f"/api/meetings/{self.meeting.id}/waiting-room/{self.participant.id}",
            {"status": WaitingRoomStatus.APPROVED},
            format="json",
        )
        self.assertEqual(review_response.status_code, 200)

        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ):
            approved_response = participant_client.post(
                f"/api/public/meetings/share/{share_code}/join-token",
                {"display_name": "Participant"},
                format="json",
            )
        self.assertEqual(approved_response.status_code, 200)

    def test_public_join_token_blocked_when_guest_link_disabled(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.allow_guest_link_join = False
        self.meeting.save(update_fields=["waiting_room_enabled", "allow_guest_link_join"])
        share_code = build_meeting_share_code(self.meeting.room_name)
        response = APIClient().post(
            f"/api/public/meetings/share/{share_code}/join-token",
            {"display_name": "Guest"},
            format="json",
        )
        self.assertEqual(response.status_code, 403)
        payload = response.json()
        self.assertEqual(payload.get("guest_link_join_status"), "disabled")
        self.assertIn("guest link join is disabled", payload.get("detail", "").lower())

    def test_public_join_token_authenticated_user_allowed_when_guest_link_disabled(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.allow_guest_link_join = False
        self.meeting.save(update_fields=["waiting_room_enabled", "allow_guest_link_join"])
        share_code = build_meeting_share_code(self.meeting.room_name)
        participant_client = self._auth_client(self.participant)
        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ):
            response = participant_client.post(
                f"/api/public/meetings/share/{share_code}/join-token",
                {"display_name": "Participant"},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        self.assertTrue((response.json().get("meeting_ref") or "").strip())

    def test_public_join_token_sets_actual_started_at(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.save(update_fields=["waiting_room_enabled"])
        share_code = build_meeting_share_code(self.meeting.room_name)
        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ) as create_token:
            response = APIClient().post(
                f"/api/public/meetings/share/{share_code}/join-token",
                {"display_name": "Guest"},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        kwargs = create_token.call_args.kwargs
        self.assertTrue(kwargs["can_update_own_metadata"])
        self.meeting.refresh_from_db()
        self.assertIsNotNone(self.meeting.actual_started_at)
        payload = response.json()
        self.assertEqual(payload.get("max_participants"), self.meeting.max_participants)
        self.assertTrue((payload.get("actual_started_at") or "").strip())

    @override_settings(LIVEKIT_URL="ws://localhost:7880", LIVEKIT_PUBLIC_URL="")
    def test_join_token_rewrites_localhost_livekit_url_to_request_host(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.save(update_fields=["waiting_room_enabled"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        client = self._auth_client(self.participant)
        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ):
            response = client.post(
                f"/api/meetings/{self.meeting.id}/join-token",
                {"display_name": "Participant"},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json().get("livekit_url"), "ws://testserver:7880")

    @override_settings(LIVEKIT_URL="ws://localhost:7880", LIVEKIT_PUBLIC_URL="")
    def test_join_token_uses_wss_when_request_is_https(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.save(update_fields=["waiting_room_enabled"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        client = self._auth_client(self.participant)
        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ):
            response = client.post(
                f"/api/meetings/{self.meeting.id}/join-token",
                {"display_name": "Participant"},
                format="json",
                secure=True,
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json().get("livekit_url"), "wss://testserver:7880")

    @override_settings(
        LIVEKIT_URL="ws://localhost:7880",
        LIVEKIT_PUBLIC_URL="wss://rtc.example.com:7880",
    )
    def test_join_token_prefers_configured_livekit_public_url(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.save(update_fields=["waiting_room_enabled"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        client = self._auth_client(self.participant)
        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ):
            response = client.post(
                f"/api/meetings/{self.meeting.id}/join-token",
                {"display_name": "Participant"},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json().get("livekit_url"), "wss://rtc.example.com:7880")

    @override_settings(
        LIVEKIT_URL="ws://localhost:7880",
        LIVEKIT_PUBLIC_URL="ws://rtc.example.com:7880",
    )
    def test_join_token_upgrades_public_url_to_wss_on_https(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.save(update_fields=["waiting_room_enabled"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        client = self._auth_client(self.participant)
        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ):
            response = client.post(
                f"/api/meetings/{self.meeting.id}/join-token",
                {"display_name": "Participant"},
                format="json",
                secure=True,
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json().get("livekit_url"), "wss://rtc.example.com:7880")

    def test_private_messages_are_blocked_when_chat_disabled(self):
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        client = self._auth_client(self.participant)

        get_response = client.get(f"/api/meetings/{self.meeting.id}/messages")
        self.assertEqual(get_response.status_code, 200)
        self.assertEqual(get_response.json(), [])

        post_response = client.post(
            f"/api/meetings/{self.meeting.id}/messages",
            {"content": "hello"},
            format="json",
        )
        self.assertEqual(post_response.status_code, 403)
        self.assertEqual(post_response.json()["detail"], "Chat is disabled for this meeting")

    def test_public_messages_are_empty_when_chat_disabled(self):
        share_code = build_meeting_share_code(self.meeting.room_name)
        response = APIClient().get(f"/api/public/meetings/share/{share_code}/messages")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), [])


class MeetingMessageRecallTests(TestCase):
    def setUp(self):
        self.host = User.objects.create_user(username="host_chat", password="pass1234")
        self.cohost = User.objects.create_user(username="cohost_chat", password="pass1234")
        self.member = User.objects.create_user(username="member_chat", password="pass1234")
        self.other_member = User.objects.create_user(username="other_member_chat", password="pass1234")
        self.meeting = Meeting.objects.create(
            title="Chat Recall",
            room_name="room-chat-recall-test",
            owner=self.host,
            waiting_room_enabled=False,
            allow_chat=True,
            allow_screen_share=True,
            allow_self_unmute=True,
            allow_member_video=True,
            mute_on_entry=False,
            allow_recording=True,
            max_participants=20,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.host,
            role=MeetingRole.HOST,
            display_name="Host",
            muted_by_host=False,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.cohost,
            role=MeetingRole.COHOST,
            display_name="CoHost",
            muted_by_host=False,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.member,
            role=MeetingRole.PARTICIPANT,
            display_name="MemberDisplay",
            muted_by_host=False,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.other_member,
            role=MeetingRole.PARTICIPANT,
            display_name="OtherMemberDisplay",
            muted_by_host=False,
        )

    def _auth_client(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def _send_message(self, user, content="hello"):
        client = self._auth_client(user)
        response = client.post(
            f"/api/meetings/{self.meeting.id}/messages",
            {"content": content},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        return response.json()

    def test_message_list_returns_sender_display_name(self):
        self._send_message(self.member, "display-name-check")
        response = self._auth_client(self.host).get(f"/api/meetings/{self.meeting.id}/messages")
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(len(payload), 1)
        self.assertEqual(payload[0]["sender_username"], "member_chat")
        self.assertEqual(payload[0]["sender_display_name"], "MemberDisplay")

    def test_member_can_recall_own_message_within_3_minutes(self):
        payload = self._send_message(self.member, "recall-me")
        message_id = payload["id"]
        delete_response = self._auth_client(self.member).delete(
            f"/api/meetings/{self.meeting.id}/messages/{message_id}",
        )
        self.assertEqual(delete_response.status_code, 200)
        self.assertFalse(
            MeetingMessage.objects.filter(meeting=self.meeting, id=message_id).exists(),
        )

    def test_member_cannot_recall_others_message(self):
        payload = self._send_message(self.member, "cannot-recall-others")
        message_id = payload["id"]
        delete_response = self._auth_client(self.other_member).delete(
            f"/api/meetings/{self.meeting.id}/messages/{message_id}",
        )
        self.assertEqual(delete_response.status_code, 403)
        self.assertTrue(
            MeetingMessage.objects.filter(meeting=self.meeting, id=message_id).exists(),
        )

    def test_member_cannot_recall_own_message_after_3_minutes(self):
        payload = self._send_message(self.member, "expired-window")
        message_id = payload["id"]
        MeetingMessage.objects.filter(id=message_id).update(
            created_at=timezone.now() - timedelta(minutes=4),
        )
        delete_response = self._auth_client(self.member).delete(
            f"/api/meetings/{self.meeting.id}/messages/{message_id}",
        )
        self.assertEqual(delete_response.status_code, 403)
        self.assertTrue(
            MeetingMessage.objects.filter(meeting=self.meeting, id=message_id).exists(),
        )

    def test_cohost_can_recall_any_message_any_time(self):
        payload = self._send_message(self.member, "cohost-recall")
        message_id = payload["id"]
        MeetingMessage.objects.filter(id=message_id).update(
            created_at=timezone.now() - timedelta(days=1),
        )
        delete_response = self._auth_client(self.cohost).delete(
            f"/api/meetings/{self.meeting.id}/messages/{message_id}",
        )
        self.assertEqual(delete_response.status_code, 200)
        self.assertFalse(
            MeetingMessage.objects.filter(meeting=self.meeting, id=message_id).exists(),
        )

    def test_public_share_authenticated_member_can_send_message(self):
        share_code = build_meeting_share_code(self.meeting.room_name)
        response = self._auth_client(self.member).post(
            f"/api/public/meetings/share/{share_code}/messages",
            {"content": "hello-from-share"},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["sender_user_id"], self.member.id)
        self.assertEqual(payload["sender_display_name"], "MemberDisplay")

    def test_public_share_guest_cannot_send_message(self):
        share_code = build_meeting_share_code(self.meeting.room_name)
        response = APIClient().post(
            f"/api/public/meetings/share/{share_code}/messages",
            {"content": "guest-send"},
            format="json",
        )
        self.assertEqual(response.status_code, 403)

    def test_public_share_member_can_recall_message(self):
        share_code = build_meeting_share_code(self.meeting.room_name)
        post_response = self._auth_client(self.member).post(
            f"/api/public/meetings/share/{share_code}/messages",
            {"content": "recall-share"},
            format="json",
        )
        self.assertEqual(post_response.status_code, 200)
        message_id = post_response.json()["id"]
        delete_response = self._auth_client(self.member).delete(
            f"/api/public/meetings/share/{share_code}/messages/{message_id}",
        )
        self.assertEqual(delete_response.status_code, 200)
        self.assertFalse(MeetingMessage.objects.filter(id=message_id).exists())

    def test_public_share_member_cannot_recall_others_message(self):
        share_code = build_meeting_share_code(self.meeting.room_name)
        post_response = self._auth_client(self.member).post(
            f"/api/public/meetings/share/{share_code}/messages",
            {"content": "other-cannot-recall"},
            format="json",
        )
        self.assertEqual(post_response.status_code, 200)
        message_id = post_response.json()["id"]
        delete_response = self._auth_client(self.other_member).delete(
            f"/api/public/meetings/share/{share_code}/messages/{message_id}",
        )
        self.assertEqual(delete_response.status_code, 403)
        self.assertTrue(MeetingMessage.objects.filter(id=message_id).exists())


class MeetingModerationControlTests(TestCase):
    def setUp(self):
        self.host = User.objects.create_user(username="host_mod", password="pass1234")
        self.cohost = User.objects.create_user(username="cohost_mod", password="pass1234")
        self.participant = User.objects.create_user(username="participant_mod", password="pass1234")
        self.participant2 = User.objects.create_user(username="participant_mod_2", password="pass1234")
        self.meeting = Meeting.objects.create(
            title="Moderation Test",
            room_name="room-moderation-test",
            owner=self.host,
            waiting_room_enabled=True,
            allow_chat=True,
            allow_screen_share=True,
            allow_self_unmute=True,
            allow_member_video=True,
            mute_on_entry=False,
            allow_recording=True,
            max_participants=20,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.host,
            role=MeetingRole.HOST,
            muted_by_host=False,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.cohost,
            role=MeetingRole.COHOST,
            muted_by_host=False,
        )

    def _auth_client(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def test_waiting_room_review_approve_allows_join_token(self):
        participant_client = self._auth_client(self.participant)
        response = participant_client.post(
            "/api/meetings/join",
            {"room_name": self.meeting.room_name},
            format="json",
        )
        self.assertEqual(response.status_code, 403)
        waiting_entry = MeetingWaitingRoomEntry.objects.filter(meeting=self.meeting, user=self.participant).first()
        self.assertIsNotNone(waiting_entry)
        self.assertEqual(waiting_entry.status, WaitingRoomStatus.PENDING)

        host_client = self._auth_client(self.host)
        review_response = host_client.patch(
            f"/api/meetings/{self.meeting.id}/waiting-room/{self.participant.id}",
            {"status": WaitingRoomStatus.APPROVED},
            format="json",
        )
        self.assertEqual(review_response.status_code, 200)

        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ):
            token_response = participant_client.post(
                f"/api/meetings/{self.meeting.id}/join-token",
                {"display_name": "P1"},
                format="json",
            )
        self.assertEqual(token_response.status_code, 200)

    def test_waiting_member_can_open_ref_page_and_poll_join_token(self):
        participant_client = self._auth_client(self.participant)
        join_response = participant_client.post(
            "/api/meetings/join",
            {"room_name": self.meeting.room_name},
            format="json",
        )
        self.assertEqual(join_response.status_code, 403)
        join_payload = join_response.json()
        meeting_ref = (join_payload.get("meeting_ref") or "").strip()
        self.assertTrue(meeting_ref)

        detail_response = participant_client.get(f"/api/my/meetings/{meeting_ref}")
        self.assertEqual(detail_response.status_code, 200)

        pending_token_response = participant_client.post(
            f"/api/my/meetings/{meeting_ref}/join-token",
            {"display_name": "P1"},
            format="json",
        )
        self.assertEqual(pending_token_response.status_code, 403)
        self.assertEqual(
            pending_token_response.json().get("waiting_room_status"),
            WaitingRoomStatus.PENDING,
        )

    def test_host_can_leave_and_transfer_to_member(self):
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        host_client = self._auth_client(self.host)
        with patch(
            "conference.views.livekit_service.list_participants",
            return_value=[
                SimpleNamespace(identity=f"u{self.host.id}_{self.host.username}"),
                SimpleNamespace(identity=f"u{self.participant.id}_{self.participant.username}"),
            ],
        ):
            response = host_client.post(
                f"/api/meetings/{self.meeting.id}/host-leave",
                {"transfer_user_id": self.participant.id},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json().get("meeting_ended"))
        self.assertEqual(response.json().get("handover_to_user_id"), self.participant.id)

        self.assertFalse(MeetingMember.objects.filter(meeting=self.meeting, user=self.host).exists())
        target_member = MeetingMember.objects.get(meeting=self.meeting, user=self.participant)
        self.assertEqual(target_member.role, MeetingRole.HOST)
        self.meeting.refresh_from_db()
        self.assertEqual(self.meeting.owner_id, self.participant.id)

    def test_host_transfer_rejects_user_not_currently_in_meeting(self):
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        host_client = self._auth_client(self.host)
        with patch(
            "conference.views.livekit_service.list_participants",
            return_value=[
                SimpleNamespace(identity=f"u{self.host.id}_{self.host.username}"),
            ],
        ):
            response = host_client.post(
                f"/api/meetings/{self.meeting.id}/host-leave",
                {"transfer_user_id": self.participant.id},
                format="json",
            )
        self.assertEqual(response.status_code, 400)
        self.assertIn("not currently in meeting", response.json().get("detail", "").lower())

    def test_host_leave_without_transfer_auto_handover_to_cohost(self):
        host_client = self._auth_client(self.host)
        response = host_client.post(
            f"/api/meetings/{self.meeting.id}/host-leave",
            {},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json().get("meeting_ended"))
        self.assertTrue(response.json().get("auto_handover"))
        self.assertEqual(response.json().get("handover_to_user_id"), self.cohost.id)

        self.assertFalse(MeetingMember.objects.filter(meeting=self.meeting, user=self.host).exists())
        cohost_member = MeetingMember.objects.get(meeting=self.meeting, user=self.cohost)
        self.assertEqual(cohost_member.role, MeetingRole.HOST)
        self.meeting.refresh_from_db()
        self.assertEqual(self.meeting.owner_id, self.cohost.id)

    def test_remove_member_with_ban_blocks_rejoin(self):
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        host_client = self._auth_client(self.host)
        remove_response = host_client.delete(
            f"/api/meetings/{self.meeting.id}/members/{self.participant.id}?ban=true",
        )
        self.assertEqual(remove_response.status_code, 200)
        self.assertTrue(remove_response.json()["banned"])
        self.assertTrue(
            MeetingBlockedMember.objects.filter(meeting=self.meeting, user=self.participant).exists()
        )
        self.assertFalse(
            MeetingMember.objects.filter(meeting=self.meeting, user=self.participant).exists()
        )

        participant_client = self._auth_client(self.participant)
        join_response = participant_client.post(
            "/api/meetings/join",
            {"room_name": self.meeting.room_name},
            format="json",
        )
        self.assertEqual(join_response.status_code, 403)
        self.assertIn("cannot rejoin", join_response.json().get("detail", "").lower())

    def test_mute_all_and_disable_self_unmute_blocks_microphone_publish(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.save(update_fields=["waiting_room_enabled"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant2,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        host_client = self._auth_client(self.host)
        controls_response = host_client.patch(
            f"/api/meetings/{self.meeting.id}/controls",
            {"allow_self_unmute": False},
            format="json",
        )
        self.assertEqual(controls_response.status_code, 200)

        mute_all_response = host_client.post(f"/api/meetings/{self.meeting.id}/members/mute-all", format="json")
        self.assertEqual(mute_all_response.status_code, 200)
        self.assertEqual(mute_all_response.json()["muted_count"], 3)

        participant_client = self._auth_client(self.participant)
        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ) as create_token:
            token_response = participant_client.post(
                f"/api/meetings/{self.meeting.id}/join-token",
                {"display_name": "Participant"},
                format="json",
            )
        self.assertEqual(token_response.status_code, 200)
        kwargs = create_token.call_args.kwargs
        self.assertNotIn("microphone", kwargs["can_publish_sources"])

    def test_cohost_can_update_controls_and_participant_cannot(self):
        participant_member = MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        cohost_client = self._auth_client(self.cohost)
        cohost_response = cohost_client.patch(
            f"/api/meetings/{self.meeting.id}/controls",
            {"allow_chat": False, "allow_member_video": False},
            format="json",
        )
        self.assertEqual(cohost_response.status_code, 200)

        participant_client = self._auth_client(self.participant)
        denied_response = participant_client.patch(
            f"/api/meetings/{self.meeting.id}/controls",
            {"allow_chat": True},
            format="json",
        )
        self.assertEqual(denied_response.status_code, 403)
        participant_member.refresh_from_db()
        self.assertEqual(participant_member.role, MeetingRole.PARTICIPANT)

    def test_member_video_control_and_waiting_room_reject(self):
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        host_client = self._auth_client(self.host)
        disable_response = host_client.patch(
            f"/api/meetings/{self.meeting.id}/members/{self.participant.id}/video",
            {"disabled": True},
            format="json",
        )
        self.assertEqual(disable_response.status_code, 200)
        member = MeetingMember.objects.get(meeting=self.meeting, user=self.participant)
        self.assertTrue(member.video_blocked_by_host)

        participant_client = self._auth_client(self.participant2)
        participant_client.post(
            "/api/meetings/join",
            {"room_name": self.meeting.room_name},
            format="json",
        )
        reject_response = host_client.patch(
            f"/api/meetings/{self.meeting.id}/waiting-room/{self.participant2.id}",
            {"status": WaitingRoomStatus.REJECTED},
            format="json",
        )
        self.assertEqual(reject_response.status_code, 200)

        retry_response = participant_client.post(
            "/api/meetings/join",
            {"room_name": self.meeting.room_name},
            format="json",
        )
        self.assertEqual(retry_response.status_code, 403)
        self.assertIn("rejected", retry_response.json().get("detail", "").lower())

    def test_controls_update_syncs_guest_permissions(self):
        guest_identity = "g_controls_guest"
        guest_participant = SimpleNamespace(
            identity=guest_identity,
            permission=SimpleNamespace(
                can_publish=True,
                can_publish_sources=[1, 2, 3, 4],
            ),
        )
        host_client = self._auth_client(self.host)

        with (
            patch(
                "conference.views.livekit_service.list_participants",
                return_value=[guest_participant],
            ),
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.mute_participant_track_sources"),
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/controls",
                {"allow_chat": False, "allow_screen_share": False},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(
            any(
                len(call.args) >= 2 and call.args[1] == guest_identity
                for call in update_permissions.call_args_list
            )
        )

    def test_mute_all_includes_guest_participants(self):
        guest_identity = "g_muteall_guest"
        guest_participant = SimpleNamespace(
            identity=guest_identity,
            permission=SimpleNamespace(
                can_publish=True,
                can_publish_sources=[2],
            ),
        )
        host_client = self._auth_client(self.host)

        with (
            patch(
                "conference.views.livekit_service.list_participants",
                return_value=[guest_participant],
            ),
            patch("conference.views.livekit_service.update_participant_permissions"),
            patch("conference.views.livekit_service.mute_participant_track_sources"),
        ):
            response = host_client.post(
                f"/api/meetings/{self.meeting.id}/members/mute-all",
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        # Targets include cohost (1) + guest participant (1).
        self.assertEqual(response.json().get("muted_count"), 2)

    def test_host_can_update_guest_display_name(self):
        guest_identity = "g_rename_guest"
        host_client = self._auth_client(self.host)

        with patch("conference.views.livekit_service.update_participant_name") as update_name:
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/display-name",
                {"display_name": "Guest Renamed"},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json().get("display_name"), "Guest Renamed")
        update_name.assert_called_with(
            self.meeting.room_name,
            guest_identity,
            name="Guest Renamed",
        )

    def test_my_display_name_update_syncs_livekit_participant_name(self):
        host_client = self._auth_client(self.host)
        expected_identity = f"u{self.host.id}_{self.host.username}"

        with patch("conference.views.livekit_service.update_participant_name") as update_name:
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/my-display-name",
                {"display_name": "Host Renamed"},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json().get("display_name"), "Host Renamed")
        update_name.assert_called_with(
            self.meeting.room_name,
            expected_identity,
            name="Host Renamed",
        )

    def test_my_display_name_conflict_returns_409(self):
        membership = MeetingMember.objects.get(meeting=self.meeting, user=self.host)
        membership.display_name = "Host Initial"
        membership.display_name_version = 3
        membership.save(update_fields=["display_name", "display_name_version"])
        host_client = self._auth_client(self.host)

        with patch("conference.views.livekit_service.update_participant_name") as update_name:
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/my-display-name",
                {
                    "display_name": "Host Renamed",
                    "expected_display_name_version": 2,
                },
                format="json",
            )
        self.assertEqual(response.status_code, 409)
        payload = response.json()
        self.assertEqual(payload.get("code"), "display_name_version_conflict")
        self.assertEqual(payload.get("current_display_name"), "Host Initial")
        self.assertEqual(payload.get("current_display_name_version"), 3)
        update_name.assert_not_called()
        membership.refresh_from_db()
        self.assertEqual(membership.display_name, "Host Initial")
        self.assertEqual(membership.display_name_version, 3)

    def test_host_update_guest_display_name_conflict_returns_409(self):
        guest_identity = "g_conflict_guest"
        guest = MeetingGuestParticipant.objects.create(
            meeting=self.meeting,
            participant_identity=guest_identity,
            display_name="Guest Initial",
            display_name_version=5,
        )
        host_client = self._auth_client(self.host)

        with patch("conference.views.livekit_service.update_participant_name") as update_name:
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/display-name",
                {
                    "display_name": "Guest Renamed",
                    "expected_display_name_version": 4,
                },
                format="json",
            )
        self.assertEqual(response.status_code, 409)
        payload = response.json()
        self.assertEqual(payload.get("code"), "display_name_version_conflict")
        self.assertEqual(payload.get("current_display_name"), "Guest Initial")
        self.assertEqual(payload.get("current_display_name_version"), 5)
        update_name.assert_not_called()
        guest.refresh_from_db()
        self.assertEqual(guest.display_name, "Guest Initial")
        self.assertEqual(guest.display_name_version, 5)

    def test_host_rename_registered_member_syncs_livekit_participant_name(self):
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        host_client = self._auth_client(self.host)
        expected_identity = f"u{self.participant.id}_{self.participant.username}"

        with patch("conference.views.livekit_service.update_participant_name") as update_name:
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/members/{self.participant.id}/display-name",
                {"display_name": "Participant Renamed"},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json().get("display_name"), "Participant Renamed")
        update_name.assert_called_with(
            self.meeting.room_name,
            expected_identity,
            name="Participant Renamed",
        )

    def test_host_can_manage_guest_participant_identity(self):
        guest_identity = "g_abc1234567_guest_user"
        host_client = self._auth_client(self.host)

        with (
            patch("conference.views.livekit_service.list_participants", return_value=[]),
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.mute_participant_track_sources"),
            patch("conference.views.livekit_service.remove_participant") as remove_participant,
        ):
            mute_response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/mute",
                {"muted": True},
                format="json",
            )
            self.assertEqual(mute_response.status_code, 200)
            self.assertEqual(mute_response.json().get("identity"), guest_identity)
            self.assertTrue(mute_response.json().get("muted"))
            update_permissions.assert_called()

            remove_response = host_client.delete(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}",
            )
            self.assertEqual(remove_response.status_code, 200)
            self.assertFalse(remove_response.json().get("banned"))
            remove_participant.assert_called_with(self.meeting.room_name, guest_identity)

    def test_host_can_manage_guest_permission_actions(self):
        guest_identity = "g_permission_guest"
        guest_participant = SimpleNamespace(
            identity=guest_identity,
            permission=SimpleNamespace(
                can_publish=True,
                can_publish_sources=[1, 2, 3, 4],
                can_publish_data=True,
            ),
        )
        host_client = self._auth_client(self.host)

        with (
            patch(
                "conference.views.livekit_service.list_participants",
                return_value=[guest_participant],
            ),
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.mute_participant_track_sources"),
        ):
            mic_response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/mic-permission",
                {"allowed": False},
                format="json",
            )
            self.assertEqual(mic_response.status_code, 200)
            self.assertFalse(mic_response.json().get("allow_self_unmute"))

            video_response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/video-permission",
                {"allowed": False},
                format="json",
            )
            self.assertEqual(video_response.status_code, 200)
            self.assertFalse(video_response.json().get("allow_member_video"))

            chat_response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/chat-permission",
                {"allowed": False},
                format="json",
            )
            self.assertEqual(chat_response.status_code, 400)
            self.assertIn("meeting-level", chat_response.json().get("detail", "").lower())

            share_response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/screen-share-permission",
                {"allowed": False},
                format="json",
            )
            self.assertEqual(share_response.status_code, 200)
            self.assertFalse(share_response.json().get("allow_screen_share"))
            self.assertTrue(update_permissions.called)

    def test_unmute_member_immediate_control_directly_opens_mic(self):
        member = MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=True,
            mic_request_pending=True,
        )
        host_client = self._auth_client(self.host)

        with (
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.update_participant_metadata") as update_metadata,
            patch("conference.views.livekit_service.mute_participant_track_sources") as mute_tracks,
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/members/{self.participant.id}/mute",
                {"muted": False},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        member.refresh_from_db()
        self.assertFalse(member.muted_by_host)
        self.assertIsNone(member.allow_self_unmute_override)
        self.assertFalse(member.mic_request_pending)
        self.assertIn("microphone", update_permissions.call_args.kwargs.get("can_publish_sources", []))
        self.assertTrue(
            any(
                call.kwargs.get("track_sources") == ["microphone"]
                and call.kwargs.get("muted") is False
                for call in mute_tracks.call_args_list
            )
        )
        metadata_payload = json.loads(update_metadata.call_args.kwargs.get("metadata", "{}"))
        self.assertTrue(metadata_payload.get("host_force_open_mic_nonce"))

    def test_unmute_member_immediate_control_respects_mic_permission(self):
        self.meeting.allow_self_unmute = False
        self.meeting.save(update_fields=["allow_self_unmute"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=True,
            allow_self_unmute_override=False,
        )
        host_client = self._auth_client(self.host)

        with (
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.update_participant_metadata") as update_metadata,
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/members/{self.participant.id}/mute",
                {"muted": False},
                format="json",
            )
        self.assertEqual(response.status_code, 400)
        self.assertIn("allow mic first", response.json().get("detail", "").lower())
        update_permissions.assert_not_called()
        update_metadata.assert_not_called()

    def test_video_on_member_immediate_control_directly_opens_camera(self):
        member = MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant2,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
            video_blocked_by_host=True,
            video_request_pending=True,
        )
        host_client = self._auth_client(self.host)

        with (
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.update_participant_metadata") as update_metadata,
            patch("conference.views.livekit_service.mute_participant_track_sources") as mute_tracks,
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/members/{self.participant2.id}/video",
                {"disabled": False},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        member.refresh_from_db()
        self.assertFalse(member.video_blocked_by_host)
        self.assertIsNone(member.allow_member_video_override)
        self.assertFalse(member.video_request_pending)
        self.assertIn("camera", update_permissions.call_args.kwargs.get("can_publish_sources", []))
        self.assertTrue(
            any(
                call.kwargs.get("track_sources") == ["camera"]
                and call.kwargs.get("muted") is False
                for call in mute_tracks.call_args_list
            )
        )
        metadata_payload = json.loads(update_metadata.call_args.kwargs.get("metadata", "{}"))
        self.assertTrue(metadata_payload.get("host_force_open_video_nonce"))

    def test_video_on_member_immediate_control_respects_video_permission(self):
        self.meeting.allow_member_video = False
        self.meeting.save(update_fields=["allow_member_video"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant2,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
            video_blocked_by_host=True,
            allow_member_video_override=False,
        )
        host_client = self._auth_client(self.host)

        with (
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.update_participant_metadata") as update_metadata,
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/members/{self.participant2.id}/video",
                {"disabled": False},
                format="json",
            )
        self.assertEqual(response.status_code, 400)
        self.assertIn("allow video first", response.json().get("detail", "").lower())
        update_permissions.assert_not_called()
        update_metadata.assert_not_called()

    def test_unmute_guest_immediate_control_directly_opens_mic(self):
        guest_identity = "g_open_mic_guest"
        guest_participant = SimpleNamespace(
            identity=guest_identity,
            permission=SimpleNamespace(
                can_publish=True,
                can_publish_sources=[2],  # microphone only
                can_publish_data=True,
            ),
        )
        host_client = self._auth_client(self.host)

        with (
            patch(
                "conference.views.livekit_service.list_participants",
                return_value=[guest_participant],
            ),
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.update_participant_metadata") as update_metadata,
            patch("conference.views.livekit_service.mute_participant_track_sources") as mute_tracks,
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/mute",
                {"muted": False},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertTrue(payload.get("allow_self_unmute"))
        self.assertFalse(payload.get("allow_member_video"))
        self.assertEqual(
            update_permissions.call_args.kwargs.get("can_publish_sources"),
            ["microphone"],
        )
        self.assertTrue(
            any(
                call.kwargs.get("track_sources") == ["microphone"]
                and call.kwargs.get("muted") is False
                for call in mute_tracks.call_args_list
            )
        )
        metadata_payload = json.loads(update_metadata.call_args.kwargs.get("metadata", "{}"))
        self.assertTrue(metadata_payload.get("host_force_open_mic_nonce"))

    def test_unmute_guest_immediate_control_respects_mic_permission(self):
        guest_identity = "g_open_mic_blocked_guest"
        guest_participant = SimpleNamespace(
            identity=guest_identity,
            permission=SimpleNamespace(
                can_publish=True,
                can_publish_sources=[1],  # camera only
                can_publish_data=True,
            ),
        )
        host_client = self._auth_client(self.host)

        with (
            patch(
                "conference.views.livekit_service.list_participants",
                return_value=[guest_participant],
            ),
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.update_participant_metadata") as update_metadata,
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/mute",
                {"muted": False},
                format="json",
            )
        self.assertEqual(response.status_code, 400)
        self.assertIn("allow mic first", response.json().get("detail", "").lower())
        update_permissions.assert_not_called()
        update_metadata.assert_not_called()

    def test_video_on_guest_immediate_control_directly_opens_camera(self):
        guest_identity = "g_open_video_guest"
        guest_participant = SimpleNamespace(
            identity=guest_identity,
            permission=SimpleNamespace(
                can_publish=True,
                can_publish_sources=[1],  # camera only
                can_publish_data=True,
            ),
        )
        host_client = self._auth_client(self.host)

        with (
            patch(
                "conference.views.livekit_service.list_participants",
                return_value=[guest_participant],
            ),
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.update_participant_metadata") as update_metadata,
            patch("conference.views.livekit_service.mute_participant_track_sources") as mute_tracks,
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/video",
                {"disabled": False},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertFalse(payload.get("allow_self_unmute"))
        self.assertTrue(payload.get("allow_member_video"))
        self.assertEqual(
            update_permissions.call_args.kwargs.get("can_publish_sources"),
            ["camera"],
        )
        self.assertTrue(
            any(
                call.kwargs.get("track_sources") == ["camera"]
                and call.kwargs.get("muted") is False
                for call in mute_tracks.call_args_list
            )
        )
        metadata_payload = json.loads(update_metadata.call_args.kwargs.get("metadata", "{}"))
        self.assertTrue(metadata_payload.get("host_force_open_video_nonce"))

    def test_video_on_guest_immediate_control_respects_video_permission(self):
        guest_identity = "g_open_video_blocked_guest"
        guest_participant = SimpleNamespace(
            identity=guest_identity,
            permission=SimpleNamespace(
                can_publish=True,
                can_publish_sources=[2],  # microphone only
                can_publish_data=True,
            ),
        )
        host_client = self._auth_client(self.host)

        with (
            patch(
                "conference.views.livekit_service.list_participants",
                return_value=[guest_participant],
            ),
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.update_participant_metadata") as update_metadata,
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/video",
                {"disabled": False},
                format="json",
            )
        self.assertEqual(response.status_code, 400)
        self.assertIn("allow video first", response.json().get("detail", "").lower())
        update_permissions.assert_not_called()
        update_metadata.assert_not_called()

    def test_video_permission_allow_for_member_only_enables_camera_permission(self):
        member = MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
            allow_self_unmute_override=False,
            allow_member_video_override=False,
            allow_screen_share_override=False,
            video_request_pending=True,
        )
        host_client = self._auth_client(self.host)

        with (
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.mute_participant_track_sources"),
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/members/{self.participant.id}/video-permission",
                {"allowed": True},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        member.refresh_from_db()
        self.assertTrue(member.allow_member_video_override)
        self.assertFalse(member.video_request_pending)
        self.assertFalse(member.allow_self_unmute_override)
        self.assertFalse(member.allow_screen_share_override)
        self.assertEqual(
            update_permissions.call_args.kwargs.get("can_publish_sources"),
            ["camera"],
        )

    def test_video_permission_allow_for_member_keeps_existing_mic_and_share_permissions(self):
        member = MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant2,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
            allow_self_unmute_override=True,
            allow_member_video_override=False,
            allow_screen_share_override=True,
            video_request_pending=True,
        )
        host_client = self._auth_client(self.host)

        with (
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.mute_participant_track_sources"),
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/members/{self.participant2.id}/video-permission",
                {"allowed": True},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        member.refresh_from_db()
        self.assertTrue(member.allow_self_unmute_override)
        self.assertTrue(member.allow_member_video_override)
        self.assertTrue(member.allow_screen_share_override)
        self.assertEqual(
            update_permissions.call_args.kwargs.get("can_publish_sources"),
            ["microphone", "camera", "screen_share", "screen_share_audio"],
        )

    def test_video_permission_allow_for_guest_keeps_mic_and_share_sources(self):
        guest_identity = "g_video_perm_guest"
        guest_participant = SimpleNamespace(
            identity=guest_identity,
            permission=SimpleNamespace(
                can_publish=True,
                can_publish_sources=[
                    SimpleNamespace(name="MICROPHONE"),
                    SimpleNamespace(name="SCREEN_SHARE"),
                    SimpleNamespace(name="SCREEN_SHARE_AUDIO"),
                ],
                can_publish_data=True,
            ),
        )
        host_client = self._auth_client(self.host)

        with (
            patch(
                "conference.views.livekit_service.list_participants",
                return_value=[guest_participant],
            ),
            patch("conference.views.livekit_service.update_participant_permissions") as update_permissions,
            patch("conference.views.livekit_service.mute_participant_track_sources"),
        ):
            response = host_client.patch(
                f"/api/meetings/{self.meeting.id}/participants/{guest_identity}/video-permission",
                {"allowed": True},
                format="json",
            )
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertTrue(payload.get("allow_self_unmute"))
        self.assertTrue(payload.get("allow_member_video"))
        self.assertTrue(payload.get("allow_screen_share"))
        self.assertEqual(
            update_permissions.call_args.kwargs.get("can_publish_sources"),
            ["microphone", "camera", "screen_share", "screen_share_audio"],
        )

    def test_participant_cannot_manage_guest_participant_identity(self):
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        participant_client = self._auth_client(self.participant)

        response = participant_client.patch(
            f"/api/meetings/{self.meeting.id}/participants/g_abc1234567_guest/mute",
            {"muted": True},
            format="json",
        )
        self.assertEqual(response.status_code, 403)

    def test_registered_identity_must_use_member_api(self):
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        host_client = self._auth_client(self.host)
        registered_identity = f"u{self.participant.id}_{self.participant.username}"

        response = host_client.patch(
            f"/api/meetings/{self.meeting.id}/participants/{registered_identity}/mute",
            {"muted": True},
            format="json",
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("member id", response.json().get("detail", "").lower())

    def test_guest_participant_management_ref_api(self):
        meeting_ref = ensure_meeting_ref(self.meeting, self.host)
        guest_identity = "g_ref1234567_guest"
        host_client = self._auth_client(self.host)

        with patch("conference.views.livekit_service.remove_participant") as remove_participant:
            response = host_client.delete(
                f"/api/my/meetings/{meeting_ref}/participants/{guest_identity}",
            )
        self.assertEqual(response.status_code, 200)
        remove_participant.assert_called_with(self.meeting.room_name, guest_identity)

    def test_member_permission_override_can_allow_mic_when_meeting_self_unmute_disabled(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.allow_self_unmute = False
        self.meeting.save(update_fields=["waiting_room_enabled", "allow_self_unmute"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        host_client = self._auth_client(self.host)
        allow_response = host_client.patch(
            f"/api/meetings/{self.meeting.id}/members/{self.participant.id}/mic-permission",
            {"allowed": True},
            format="json",
        )
        self.assertEqual(allow_response.status_code, 200)
        self.assertTrue(allow_response.json().get("allow_self_unmute"))

        participant_client = self._auth_client(self.participant)
        with patch(
            "conference.views.livekit_service.create_participant_token",
            return_value="fake-token",
        ) as create_token:
            token_response = participant_client.post(
                f"/api/meetings/{self.meeting.id}/join-token",
                {"display_name": "Participant"},
                format="json",
            )
        self.assertEqual(token_response.status_code, 200)
        kwargs = create_token.call_args.kwargs
        self.assertIn("microphone", kwargs["can_publish_sources"])

    def test_member_chat_permission_blocks_message_send(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.allow_chat = True
        self.meeting.save(update_fields=["waiting_room_enabled", "allow_chat"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        host_client = self._auth_client(self.host)
        block_response = host_client.patch(
            f"/api/meetings/{self.meeting.id}/members/{self.participant.id}/chat-permission",
            {"allowed": False},
            format="json",
        )
        self.assertEqual(block_response.status_code, 200)
        self.assertFalse(block_response.json().get("allow_chat"))

        participant_client = self._auth_client(self.participant)
        message_response = participant_client.post(
            f"/api/meetings/{self.meeting.id}/messages",
            {"content": "hello"},
            format="json",
        )
        self.assertEqual(message_response.status_code, 403)
        self.assertIn("chat permission", message_response.json().get("detail", "").lower())

    def test_raise_hand_then_host_approve_mic_permission(self):
        self.meeting.waiting_room_enabled = False
        self.meeting.allow_self_unmute = False
        self.meeting.save(update_fields=["waiting_room_enabled", "allow_self_unmute"])
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            muted_by_host=False,
        )
        participant_client = self._auth_client(self.participant)
        raise_response = participant_client.post(
            f"/api/meetings/{self.meeting.id}/members/raise-hand",
            {"request": "mic"},
            format="json",
        )
        self.assertEqual(raise_response.status_code, 200)
        self.assertTrue(raise_response.json().get("mic_request_pending"))

        host_client = self._auth_client(self.host)
        approve_response = host_client.patch(
            f"/api/meetings/{self.meeting.id}/members/{self.participant.id}/mic-permission",
            {"allowed": True},
            format="json",
        )
        self.assertEqual(approve_response.status_code, 200)
        payload = approve_response.json()
        self.assertTrue(payload.get("allow_self_unmute"))
        self.assertFalse(payload.get("mic_request_pending"))


class MeetingRecordingTests(TestCase):
    def setUp(self):
        self.super_admin = User.objects.create_superuser(
            username="admin_recording",
            email="admin_recording@example.com",
            password="pass1234",
        )
        self.host = User.objects.create_user(username="host_recording", password="pass1234")
        self.cohost = User.objects.create_user(username="cohost_recording", password="pass1234")
        self.participant = User.objects.create_user(username="participant_recording", password="pass1234")
        self.other_user = User.objects.create_user(username="other_recording", password="pass1234")

        self.meeting = Meeting.objects.create(
            title="Recording Meeting",
            room_name="room-recording-tests",
            owner=self.host,
            waiting_room_enabled=False,
            allow_recording=True,
            max_participants=50,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.host,
            role=MeetingRole.HOST,
            display_name="Host Recorder",
            muted_by_host=False,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.cohost,
            role=MeetingRole.COHOST,
            display_name="CoHost Recorder",
            muted_by_host=False,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.participant,
            role=MeetingRole.PARTICIPANT,
            display_name="Participant Recorder",
            muted_by_host=False,
        )

        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        RecordingStorageConfig.objects.create(
            storage_root=self.temp_dir.name,
            updated_by=self.super_admin,
        )

    def _auth_client(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def _upload_recording(self, client, path: str):
        payload = SimpleUploadedFile(
            "meeting-recording.webm",
            b"test-recording-content",
            content_type="video/webm",
        )
        return client.post(
            path,
            {"file": payload, "duration_seconds": 12},
            format="multipart",
        )

    def test_super_admin_can_update_recording_storage_root(self):
        client = self._auth_client(self.super_admin)
        temp_root = tempfile.TemporaryDirectory()
        self.addCleanup(temp_root.cleanup)
        new_root = temp_root.name
        response = client.patch(
            "/api/system/recording-storage",
            {"storage_root": new_root},
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload.get("storage_root"), str(new_root))

    def test_non_super_admin_cannot_update_recording_storage_root(self):
        client = self._auth_client(self.host)
        response = client.patch(
            "/api/system/recording-storage",
            {"storage_root": self.temp_dir.name},
            format="json",
        )
        self.assertEqual(response.status_code, 403)

    def test_host_and_cohost_recordings_are_stored_under_separate_user_folders(self):
        host_client = self._auth_client(self.host)
        cohost_client = self._auth_client(self.cohost)

        host_response = self._upload_recording(
            host_client,
            f"/api/meetings/{self.meeting.id}/recordings",
        )
        self.assertEqual(host_response.status_code, 200)

        cohost_response = self._upload_recording(
            cohost_client,
            f"/api/meetings/{self.meeting.id}/recordings",
        )
        self.assertEqual(cohost_response.status_code, 200)

        host_recording = MeetingRecording.objects.get(id=host_response.json()["id"])
        cohost_recording = MeetingRecording.objects.get(id=cohost_response.json()["id"])
        self.assertTrue(host_recording.relative_path.startswith(f"user_{self.host.id}_"))
        self.assertTrue(cohost_recording.relative_path.startswith(f"user_{self.cohost.id}_"))
        self.assertNotEqual(
            host_recording.relative_path.split("/")[0],
            cohost_recording.relative_path.split("/")[0],
        )

    def test_participant_cannot_upload_meeting_recording(self):
        participant_client = self._auth_client(self.participant)
        response = self._upload_recording(
            participant_client,
            f"/api/meetings/{self.meeting.id}/recordings",
        )
        self.assertEqual(response.status_code, 403)

    def test_upload_recording_rejected_when_meeting_recording_disabled(self):
        self.meeting.allow_recording = False
        self.meeting.save(update_fields=["allow_recording"])
        host_client = self._auth_client(self.host)
        response = self._upload_recording(
            host_client,
            f"/api/meetings/{self.meeting.id}/recordings",
        )
        self.assertEqual(response.status_code, 403)
        self.assertIn("recording is disabled", response.json().get("detail", "").lower())

    def test_recordings_list_scoped_for_regular_user_and_all_for_super_admin(self):
        host_client = self._auth_client(self.host)
        cohost_client = self._auth_client(self.cohost)
        super_client = self._auth_client(self.super_admin)

        self._upload_recording(host_client, f"/api/meetings/{self.meeting.id}/recordings")
        self._upload_recording(cohost_client, f"/api/meetings/{self.meeting.id}/recordings")

        host_list = host_client.get("/api/recordings")
        self.assertEqual(host_list.status_code, 200)
        host_rows = host_list.json()
        self.assertEqual(len(host_rows), 1)
        self.assertEqual(host_rows[0]["owner_user_id"], self.host.id)

        super_list = super_client.get("/api/recordings")
        self.assertEqual(super_list.status_code, 200)
        super_rows = super_list.json()
        self.assertEqual(len(super_rows), 2)

    def test_recordings_remain_visible_after_meeting_deleted(self):
        host_client = self._auth_client(self.host)
        super_client = self._auth_client(self.super_admin)
        meeting_id = self.meeting.id
        meeting_title = self.meeting.title

        upload_response = self._upload_recording(
            host_client,
            f"/api/meetings/{meeting_id}/recordings",
        )
        self.assertEqual(upload_response.status_code, 200)
        recording_id = upload_response.json()["id"]

        delete_response = host_client.delete(f"/api/meetings/{meeting_id}")
        self.assertEqual(delete_response.status_code, 200)

        recording = MeetingRecording.objects.get(id=recording_id)
        self.assertIsNone(recording.meeting_id)
        self.assertEqual(recording.meeting_id_snapshot, meeting_id)
        self.assertEqual(recording.meeting_title_snapshot, meeting_title)

        list_response = super_client.get("/api/recordings")
        self.assertEqual(list_response.status_code, 200)
        rows = list_response.json()
        row = next((item for item in rows if item.get("id") == recording_id), None)
        self.assertIsNotNone(row)
        self.assertTrue(row.get("meeting_deleted"))
        self.assertEqual(row.get("meeting_display_id"), meeting_id)
        self.assertEqual(row.get("meeting_title"), meeting_title)

        search_response = super_client.get("/api/recordings", {"q": meeting_title})
        self.assertEqual(search_response.status_code, 200)
        search_ids = {item.get("id") for item in search_response.json()}
        self.assertIn(recording_id, search_ids)

    def test_recording_download_requires_owner_or_super_admin(self):
        host_client = self._auth_client(self.host)
        participant_client = self._auth_client(self.participant)
        super_client = self._auth_client(self.super_admin)

        upload_response = self._upload_recording(
            host_client,
            f"/api/meetings/{self.meeting.id}/recordings",
        )
        self.assertEqual(upload_response.status_code, 200)
        recording_id = upload_response.json()["id"]

        forbidden_response = participant_client.get(f"/api/recordings/{recording_id}/download")
        self.assertEqual(forbidden_response.status_code, 403)

        owner_response = host_client.get(f"/api/recordings/{recording_id}/download")
        self.assertEqual(owner_response.status_code, 200)
        self.assertIn("attachment", owner_response.get("Content-Disposition", ""))
        owner_response.close()

        super_response = super_client.get(f"/api/recordings/{recording_id}/download")
        self.assertEqual(super_response.status_code, 200)
        super_response.close()

    def test_download_uses_windows_storage_root_for_linux_recording_root(self):
        if os.name != "nt":
            self.skipTest("Windows-specific storage root handling")

        host_client = self._auth_client(self.host)
        relative_path = "user_1_host/meeting_1_room/fallback.mp4"
        actual_file = (Path(self.temp_dir.name) / relative_path).resolve()
        actual_file.parent.mkdir(parents=True, exist_ok=True)
        actual_file.write_bytes(b"fake-mp4")

        recording = MeetingRecording.objects.create(
            meeting=self.meeting,
            owner=self.host,
            recorded_by_display_name="Host Recorder",
            file_name="fallback.mp4",
            storage_root="/recordings",
            relative_path=relative_path,
            mime_type="video/mp4",
            size_bytes=actual_file.stat().st_size,
            duration_seconds=1,
        )

        response = host_client.get(f"/api/recordings/{recording.id}/download")
        self.assertEqual(response.status_code, 200)
        response.close()

    def test_download_falls_back_to_current_storage_root_when_recording_root_stale(self):
        host_client = self._auth_client(self.host)
        relative_path = "user_1_host/meeting_1_room/fallback_stale.mp4"
        actual_file = (Path(self.temp_dir.name) / relative_path).resolve()
        actual_file.parent.mkdir(parents=True, exist_ok=True)
        actual_file.write_bytes(b"fake-mp4")

        stale_root = (Path(self.temp_dir.name).parent / "missing_recording_root_for_test").resolve()
        recording = MeetingRecording.objects.create(
            meeting=self.meeting,
            owner=self.host,
            recorded_by_display_name="Host Recorder",
            file_name="fallback_stale.mp4",
            storage_root=str(stale_root),
            relative_path=relative_path,
            mime_type="video/mp4",
            size_bytes=actual_file.stat().st_size,
            duration_seconds=1,
        )

        response = host_client.get(f"/api/recordings/{recording.id}/download")
        self.assertEqual(response.status_code, 200)
        response.close()

    def test_recording_delete_requires_owner_or_super_admin(self):
        host_client = self._auth_client(self.host)
        participant_client = self._auth_client(self.participant)
        super_client = self._auth_client(self.super_admin)

        upload_response = self._upload_recording(
            host_client,
            f"/api/meetings/{self.meeting.id}/recordings",
        )
        self.assertEqual(upload_response.status_code, 200)
        recording_id = upload_response.json()["id"]

        forbidden_response = participant_client.delete(f"/api/recordings/{recording_id}")
        self.assertEqual(forbidden_response.status_code, 403)

        owner_delete = host_client.delete(f"/api/recordings/{recording_id}")
        self.assertEqual(owner_delete.status_code, 200)
        self.assertFalse(MeetingRecording.objects.filter(id=recording_id).exists())

        second_upload = self._upload_recording(
            host_client,
            f"/api/meetings/{self.meeting.id}/recordings",
        )
        self.assertEqual(second_upload.status_code, 200)
        second_id = second_upload.json()["id"]
        super_delete = super_client.delete(f"/api/recordings/{second_id}")
        self.assertEqual(super_delete.status_code, 200)
        self.assertFalse(MeetingRecording.objects.filter(id=second_id).exists())

    def test_recording_delete_removes_file_from_storage(self):
        host_client = self._auth_client(self.host)
        upload_response = self._upload_recording(
            host_client,
            f"/api/meetings/{self.meeting.id}/recordings",
        )
        self.assertEqual(upload_response.status_code, 200)
        recording = MeetingRecording.objects.get(id=upload_response.json()["id"])
        stored_path = (Path(recording.storage_root) / recording.relative_path).resolve()
        self.assertTrue(stored_path.exists())

        delete_response = host_client.delete(f"/api/recordings/{recording.id}")
        self.assertEqual(delete_response.status_code, 200)
        self.assertFalse(stored_path.exists())
        self.assertFalse(MeetingRecording.objects.filter(id=recording.id).exists())

    def test_recording_upload_supports_meeting_ref_endpoint(self):
        meeting_ref = ensure_meeting_ref(self.meeting, self.host)
        host_client = self._auth_client(self.host)
        response = self._upload_recording(
            host_client,
            f"/api/my/meetings/{meeting_ref}/recordings",
        )
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload.get("meeting_id"), self.meeting.id)

    def test_participant_cannot_start_recording_egress(self):
        participant_client = self._auth_client(self.participant)
        response = participant_client.post(
            f"/api/meetings/{self.meeting.id}/recordings/egress/start",
            {"layout": "grid"},
            format="json",
        )
        self.assertEqual(response.status_code, 403)

    def test_host_can_start_recording_egress(self):
        host_client = self._auth_client(self.host)
        started_info = SimpleNamespace(
            egress_id="egress_start_1",
            status=int(lk_egress.EGRESS_STARTING),
            file=None,
            file_results=[],
        )
        with patch(
            "conference.views.livekit_service.start_room_composite_egress_to_file",
            return_value=started_info,
        ) as start_mock, patch(
            "conference.views.livekit_service.list_egress",
            return_value=[started_info],
        ):
            response = host_client.post(
                f"/api/meetings/{self.meeting.id}/recordings/egress/start",
                {"layout": "grid"},
                format="json",
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertTrue(payload.get("active"))
        self.assertEqual(payload.get("egress_id"), "egress_start_1")
        start_mock.assert_called_once()

        self.meeting.refresh_from_db()
        self.assertEqual(self.meeting.active_egress_id, "egress_start_1")
        self.assertTrue((self.meeting.active_egress_file_name or "").endswith(".mp4"))

    @override_settings(LIVEKIT_EGRESS_OUTPUT_ROOT="/recordings")
    def test_host_can_start_recording_egress_with_container_output_root(self):
        host_client = self._auth_client(self.host)
        started_info = SimpleNamespace(
            egress_id="egress_start_container_1",
            status=int(lk_egress.EGRESS_STARTING),
            file=None,
            file_results=[],
        )
        with patch(
            "conference.views.livekit_service.start_room_composite_egress_to_file",
            return_value=started_info,
        ) as start_mock, patch(
            "conference.views.livekit_service.list_egress",
            return_value=[started_info],
        ):
            response = host_client.post(
                f"/api/meetings/{self.meeting.id}/recordings/egress/start",
                {"layout": "grid"},
                format="json",
            )

        self.assertEqual(response.status_code, 200)
        start_mock.assert_called_once()
        output_path = start_mock.call_args.args[1]
        self.assertTrue(output_path.startswith("/recordings/"))

    def test_start_recording_egress_returns_actionable_error_when_egress_not_connected(self):
        host_client = self._auth_client(self.host)
        with patch(
            "conference.views.livekit_service.start_room_composite_egress_to_file",
            side_effect=TwirpError(
                "internal",
                "twirp error unknown: egress not connected (redis required)",
                status=500,
                metadata={},
            ),
        ):
            response = host_client.post(
                f"/api/meetings/{self.meeting.id}/recordings/egress/start",
                {"layout": "grid"},
                format="json",
            )

        self.assertEqual(response.status_code, 503)
        detail = response.json().get("detail", "").lower()
        self.assertIn("egress", detail)
        self.assertIn("redis", detail)

    def test_stop_recording_egress_finalizes_recording(self):
        host_client = self._auth_client(self.host)
        relative_path = "user_1_host/meeting_1_room/final.mp4"
        self.meeting.active_egress_id = "egress_stop_1"
        self.meeting.active_egress_file_name = "final.mp4"
        self.meeting.active_egress_relative_path = relative_path
        self.meeting.active_egress_storage_root = self.temp_dir.name
        self.meeting.active_egress_started_by = self.host
        self.meeting.active_egress_started_at = timezone.now()
        self.meeting.save(
            update_fields=[
                "active_egress_id",
                "active_egress_file_name",
                "active_egress_relative_path",
                "active_egress_storage_root",
                "active_egress_started_by",
                "active_egress_started_at",
            ]
        )

        active_info = SimpleNamespace(
            egress_id="egress_stop_1",
            status=int(lk_egress.EGRESS_ACTIVE),
            file=None,
            file_results=[],
        )
        complete_info = SimpleNamespace(
            egress_id="egress_stop_1",
            status=int(lk_egress.EGRESS_COMPLETE),
            file=SimpleNamespace(
                filename="final.mp4",
                location=str((Path(self.temp_dir.name) / relative_path).resolve()),
                size=4321,
                duration=18,
            ),
            file_results=[],
        )

        with patch(
            "conference.views.livekit_service.list_egress",
            side_effect=[[active_info], [complete_info]],
        ), patch("conference.views.livekit_service.stop_egress") as stop_mock:
            response = host_client.post(
                f"/api/meetings/{self.meeting.id}/recordings/egress/stop",
                {},
                format="json",
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertFalse(payload.get("active"))
        self.assertEqual(payload.get("status"), "complete")
        stop_mock.assert_called_once_with("egress_stop_1")

        recording = MeetingRecording.objects.filter(egress_id="egress_stop_1").first()
        self.assertIsNotNone(recording)
        self.assertEqual(recording.file_name, "final.mp4")
        self.assertEqual(recording.owner_id, self.host.id)

        self.meeting.refresh_from_db()
        self.assertEqual(self.meeting.active_egress_id, "")

    def test_recording_egress_status_returns_friendly_message_for_short_recording(self):
        host_client = self._auth_client(self.host)
        self.meeting.active_egress_id = "egress_short_1"
        self.meeting.active_egress_file_name = "short.mp4"
        self.meeting.active_egress_relative_path = "user_1/short.mp4"
        self.meeting.active_egress_storage_root = self.temp_dir.name
        self.meeting.active_egress_started_by = self.host
        self.meeting.active_egress_started_at = timezone.now()
        self.meeting.save(
            update_fields=[
                "active_egress_id",
                "active_egress_file_name",
                "active_egress_relative_path",
                "active_egress_storage_root",
                "active_egress_started_by",
                "active_egress_started_at",
            ]
        )

        aborted_info = SimpleNamespace(
            egress_id="egress_short_1",
            status=int(lk_egress.EGRESS_ABORTED),
            error="Start signal not received",
            details="End reason: Source closed",
            file=None,
            file_results=[],
        )
        with patch(
            "conference.views.livekit_service.list_egress",
            return_value=[aborted_info],
        ):
            response = host_client.get(
                f"/api/meetings/{self.meeting.id}/recordings/egress",
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertFalse(payload.get("active"))
        self.assertEqual(payload.get("status"), "aborted")
        error_text = payload.get("error", "").lower()
        self.assertIn("recording ended before egress fully started", error_text)
        self.assertIn("stopped too quickly", error_text)

    def test_recording_egress_status_supports_meeting_ref(self):
        meeting_ref = ensure_meeting_ref(self.meeting, self.host)
        host_client = self._auth_client(self.host)
        self.meeting.active_egress_id = "egress_status_1"
        self.meeting.active_egress_file_name = "status.mp4"
        self.meeting.active_egress_relative_path = "user_1/status.mp4"
        self.meeting.active_egress_storage_root = self.temp_dir.name
        self.meeting.active_egress_started_by = self.host
        self.meeting.active_egress_started_at = timezone.now()
        self.meeting.save(
            update_fields=[
                "active_egress_id",
                "active_egress_file_name",
                "active_egress_relative_path",
                "active_egress_storage_root",
                "active_egress_started_by",
                "active_egress_started_at",
            ]
        )

        active_info = SimpleNamespace(
            egress_id="egress_status_1",
            status=int(lk_egress.EGRESS_ACTIVE),
            file=None,
            file_results=[],
        )
        with patch(
            "conference.views.livekit_service.list_egress",
            return_value=[active_info],
        ):
            response = host_client.get(
                f"/api/my/meetings/{meeting_ref}/recordings/egress",
            )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertTrue(payload.get("active"))
        self.assertEqual(payload.get("status"), "active")
        self.assertEqual(payload.get("egress_id"), "egress_status_1")


@override_settings(LIVEKIT_API_KEY="devkey", LIVEKIT_API_SECRET="secret")
class LiveKitWebhookRoomSessionTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.owner = User.objects.create_user(username="webhook-host", password="pass1234")
        self.meeting = Meeting.objects.create(
            title="Webhook Meeting",
            room_name="room-webhook-1",
            owner=self.owner,
            max_participants=20,
        )
        MeetingMember.objects.create(
            meeting=self.meeting,
            user=self.owner,
            role=MeetingRole.HOST,
        )

    def _webhook_token(self, body: str, *, hash_body: str | None = None) -> str:
        hashed_source = hash_body if hash_body is not None else body
        sha = base64.b64encode(hashlib.sha256(hashed_source.encode("utf-8")).digest()).decode("ascii")
        return (
            lk_api.AccessToken(
                api_key=settings.LIVEKIT_API_KEY,
                api_secret=settings.LIVEKIT_API_SECRET,
            )
            .with_sha256(sha)
            .to_jwt()
        )

    def _post_webhook(self, payload: dict, *, hash_payload: dict | None = None):
        body = json.dumps(payload, separators=(",", ":"))
        hash_source = body
        if hash_payload is not None:
            hash_source = json.dumps(hash_payload, separators=(",", ":"))
        token = self._webhook_token(body, hash_body=hash_source)
        return self.client.generic(
            "POST",
            "/api/livekit/webhook",
            body,
            content_type="application/json",
            HTTP_AUTHORIZATION=f"Bearer {token}",
        )

    def test_participant_joined_webhook_starts_room_session(self):
        self.assertIsNone(self.meeting.room_session_started_at)

        response = self._post_webhook(
            {
                "event": "participant_joined",
                "room": {
                    "name": self.meeting.room_name,
                    "numParticipants": 1,
                },
            }
        )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertTrue(payload.get("state_changed"))
        self.assertEqual(payload.get("online_count"), 1)
        self.meeting.refresh_from_db()
        self.assertIsNotNone(self.meeting.room_session_started_at)

    def test_participant_joined_webhook_reaching_room_used_limit_forces_room_timeout(self):
        plan = BillingPlan.objects.create(
            name="seconds-limit-plan",
            max_active_rooms=1,
            max_room_participants=100,
            max_room_used_seconds=100,
            max_current_room_used_seconds=3600,
            max_recording_storage_bytes=1024 * 1024,
            max_meeting_count=10,
        )
        profile = UserBillingProfile.objects.get_or_create(user=self.owner)[0]
        profile.plan = plan
        profile.accumulated_room_used_seconds = 100
        profile.save(update_fields=["plan", "accumulated_room_used_seconds", "updated_at"])

        with patch("conference.views.livekit_service.delete_room") as delete_room:
            response = self._post_webhook(
                {
                    "event": "participant_joined",
                    "room": {
                        "name": self.meeting.room_name,
                        "numParticipants": 1,
                    },
                }
            )

        self.assertEqual(response.status_code, 200)
        delete_room.assert_called_once_with(self.meeting.room_name)
        self.meeting.refresh_from_db()
        self.assertIsNone(self.meeting.room_session_started_at)

    def test_active_webhook_reaching_current_room_limit_forces_room_timeout(self):
        plan = BillingPlan.objects.create(
            name="current-room-limit-plan",
            max_active_rooms=2,
            max_room_participants=100,
            max_room_used_seconds=10_000,
            max_current_room_used_seconds=10,
            max_recording_storage_bytes=1024 * 1024,
            max_meeting_count=10,
        )
        profile = UserBillingProfile.objects.get_or_create(user=self.owner)[0]
        profile.plan = plan
        profile.accumulated_room_used_seconds = 0
        profile.save(update_fields=["plan", "accumulated_room_used_seconds", "updated_at"])
        self.meeting.room_session_started_at = timezone.now() - timedelta(seconds=20)
        self.meeting.save(update_fields=["room_session_started_at"])

        with patch("conference.views.livekit_service.delete_room") as delete_room:
            response = self._post_webhook(
                {
                    "event": "participant_active",
                    "room": {
                        "name": self.meeting.room_name,
                        "numParticipants": 1,
                    },
                }
            )

        self.assertEqual(response.status_code, 200)
        delete_room.assert_called_once_with(self.meeting.room_name)
        self.meeting.refresh_from_db()
        self.assertIsNone(self.meeting.room_session_started_at)

    def test_participant_left_webhook_zero_online_finalizes_room_session_usage(self):
        started_at = timezone.now() - timedelta(seconds=120)
        self.meeting.room_session_started_at = started_at
        self.meeting.save(update_fields=["room_session_started_at"])
        profile = UserBillingProfile.objects.get_or_create(user=self.owner)[0]
        profile.accumulated_room_used_seconds = 0
        profile.save(update_fields=["accumulated_room_used_seconds", "updated_at"])

        response = self._post_webhook(
            {
                "event": "participant_left",
                "room": {
                    "name": self.meeting.room_name,
                    "numParticipants": 0,
                },
            }
        )

        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertTrue(payload.get("state_changed"))
        self.assertEqual(payload.get("online_count"), 0)

        self.meeting.refresh_from_db()
        profile.refresh_from_db()
        self.assertIsNone(self.meeting.room_session_started_at)
        self.assertGreaterEqual(profile.accumulated_room_used_seconds, 100)

    def test_webhook_rejects_invalid_signature(self):
        payload = {
            "event": "participant_joined",
            "room": {
                "name": self.meeting.room_name,
                "numParticipants": 1,
            },
        }
        response = self._post_webhook(
            payload,
            hash_payload={
                "event": "participant_joined",
                "room": {
                    "name": self.meeting.room_name,
                    "numParticipants": 999,
                },
            },
        )
        self.assertEqual(response.status_code, 401)
        self.meeting.refresh_from_db()
        self.assertIsNone(self.meeting.room_session_started_at)


class BillingSelfViewAndUnlimitedPlanTests(TestCase):
    def setUp(self):
        self.admin = User.objects.create_superuser(
            username="billing-admin",
            email="billing-admin@example.com",
            password="pass1234",
        )
        self.user = User.objects.create_user(
            username="billing-user",
            email="billing-user@example.com",
            password="pass1234",
        )

    def _auth_client(self, user):
        client = APIClient()
        client.force_authenticate(user=user)
        return client

    def test_billing_plan_api_accepts_zero_as_unlimited(self):
        admin_client = self._auth_client(self.admin)
        response = admin_client.post(
            "/api/billing/plans",
            {
                "name": "unlimited-plan-via-api",
                "description": "unlimited values with zero",
                "max_active_rooms": 0,
                "max_room_participants": 0,
                "max_room_used_seconds": 0,
                "max_current_room_used_seconds": 0,
                "max_recording_storage_bytes": 0,
                "max_meeting_count": 0,
            },
            format="json",
        )
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload.get("max_active_rooms"), 0)
        self.assertEqual(payload.get("max_room_participants"), 0)
        self.assertEqual(payload.get("max_room_used_seconds"), 0)
        self.assertEqual(payload.get("max_current_room_used_seconds"), 0)
        self.assertEqual(payload.get("max_recording_storage_bytes"), 0)
        self.assertEqual(payload.get("max_meeting_count"), 0)

    def test_billing_me_returns_null_limits_for_unlimited_plan_values(self):
        plan = BillingPlan.objects.create(
            name="unlimited-plan-self-view",
            max_active_rooms=0,
            max_room_participants=0,
            max_room_used_seconds=0,
            max_current_room_used_seconds=0,
            max_recording_storage_bytes=0,
            max_meeting_count=0,
        )
        profile = UserBillingProfile.objects.get_or_create(user=self.user)[0]
        profile.plan = plan
        profile.save(update_fields=["plan", "updated_at"])

        user_client = self._auth_client(self.user)
        response = user_client.get("/api/billing/me")
        self.assertEqual(response.status_code, 200)
        limits = response.json().get("limits", {})
        self.assertIsNone(limits.get("max_active_rooms"))
        self.assertIsNone(limits.get("max_room_participants"))
        self.assertIsNone(limits.get("max_room_used_seconds"))
        self.assertIsNone(limits.get("max_current_room_used_seconds"))
        self.assertIsNone(limits.get("max_recording_storage_bytes"))
        self.assertIsNone(limits.get("max_meeting_count"))
