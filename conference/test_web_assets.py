"""Regression coverage for the single Flutter Web deployment directory."""
import runpy
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from django.test import RequestFactory, SimpleTestCase, override_settings
from django.template.loader import render_to_string

from conference.views import dashboard_view


ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts" / "flutter_app_web"


class WebAssetSettingsTests(SimpleTestCase):
    def test_auth_pages_display_copyright_beside_the_form(self):
        for template in ['registration/login.html', 'registration/register.html']:
            with self.subTest(template=template):
                html = render_to_string(template, {'local_login_enabled': True, 'local_register_enabled': True})
                self.assertIn('© 2026 VibeMeeting contributors', html)
                self.assertIn('class="auth-copyright"', html)
                self.assertIn('<form', html)
                self.assertIn('src="/static/brand/vibemeeting-logo.png"', html)
                self.assertIn('alt="VibeMeeting"', html)
                self.assertNotIn('智能会议', html)

    def test_browser_shells_and_home_use_the_product_brand(self):
        for template in ['flutter_app.html', 'flutter_meeting.html', 'home.html', 'meeting_room.html']:
            with self.subTest(template=template):
                html = render_to_string(template)
                self.assertIn('<title>VibeMeeting</title>', html)
                self.assertNotIn('智能会议', html)

    def load_settings(self, artifacts_exist):
        original_exists = Path.exists

        def exists(path):
            if path == ARTIFACTS:
                return artifacts_exist
            return original_exists(path)

        with patch.object(Path, "exists", exists), patch("dotenv.load_dotenv"):
            return runpy.run_path(str(ROOT / "smart_meeting" / "settings.py"))

    def test_existing_artifacts_are_mounted_alongside_handwritten_static_files(self):
        config = self.load_settings(True)
        self.assertEqual(config["FLUTTER_APP_BUILD_DIR"], ARTIFACTS)
        self.assertEqual(config["STATICFILES_DIRS"], [
            ("flutter_app", ARTIFACTS), ROOT / "app" / "static",
        ])

    def test_missing_artifacts_do_not_select_the_retired_bundle(self):
        config = self.load_settings(False)
        self.assertEqual(config["FLUTTER_APP_BUILD_DIR"], ARTIFACTS)
        self.assertEqual(config["STATICFILES_DIRS"], [ROOT / "app" / "static"])

    def test_missing_build_shows_rebuild_instructions(self):
        request = RequestFactory().get("/dashboard")
        request.user = SimpleNamespace(is_authenticated=True)
        with tempfile.TemporaryDirectory() as missing:
            with override_settings(FLUTTER_APP_BUILD_DIR=Path(missing)):
                response = dashboard_view(request)
        self.assertEqual(response.status_code, 503)
        self.assertIn(b"flutter build web", response.content)
        self.assertIn(b"artifacts/flutter_app_web", response.content)
