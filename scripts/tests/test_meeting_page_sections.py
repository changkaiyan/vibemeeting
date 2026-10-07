"""Composition guards for the dart:html/LiveKit meeting page.

Participant menu behavior is also covered by Flutter unit tests.
"""
from pathlib import Path
import unittest


LIB = Path(__file__).resolve().parents[2] / 'flutter_app/lib/meeting_room'


class MeetingPageSectionsTests(unittest.TestCase):
    def test_desktop_and_mobile_do_not_mount_workspace(self):
        page = (LIB / 'page.dart').read_text(encoding='utf-8')
        layout = (LIB / 'widgets/layout_panels.dart').read_text(encoding='utf-8')
        for source in (page, layout):
            self.assertFalse('_buildWorkspacePanel(' in source)
        self.assertFalse("text: '工作区'" in page)
        self.assertIn('_buildChatPanel(', layout)
        for label in ('舞台', '成员', '聊天'):
            self.assertIn(f"text: '{label}'", page)
        self.assertIn('length: 3,', page)

    def test_no_ai_control_entry_points(self):
        page = (LIB / 'page.dart').read_text(encoding='utf-8')
        self.assertFalse('_openAiControlDialog' in page)
        self.assertFalse("'ai_control'" in page)
        self.assertIn("title: '会议管控'", page)
        self.assertIn('_buildMobileMoreAction(),', page)

    def test_both_layouts_use_the_collapsible_header(self):
        page = (LIB / 'page.dart').read_text(encoding='utf-8')
        self.assertEqual(page.count('_buildMeetingHeader(),'), 2)
        self.assertIn('return MeetingRoomHeader(', page)
        self.assertFalse('右上角“加入会议”' in page)

    def test_join_does_not_load_or_poll_workspace(self):
        session = (LIB / 'logic/room_session_logic.dart').read_text(encoding='utf-8')
        self.assertFalse('_loadWorkspace(' in session)
        self.assertFalse('_startWorkspacePolling(' in session)
        self.assertIn('_startChatPolling()', session)
        self.assertIn('_startMemberPolling()', session)


if __name__ == '__main__':
    unittest.main()
