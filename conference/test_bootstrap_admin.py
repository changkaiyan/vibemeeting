import os
from io import StringIO
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase
from conference.models import RecordingStorageConfig


class BootstrapAdminTests(TestCase):
    def test_initializes_recording_storage_without_overwriting_user_configuration(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {
                'DJANGO_SUPERUSER_USERNAME': 'owner',
                'DJANGO_SUPERUSER_PASSWORD': 'strong-password',
                'RECORDING_STORAGE_ROOT': directory,
            }):
                call_command('bootstrap_admin', stdout=StringIO())
                storage = RecordingStorageConfig.objects.get()
                self.assertEqual(storage.storage_root, directory)
                storage.storage_root = directory + '/custom'
                storage.save()
                call_command('bootstrap_admin', stdout=StringIO())
                storage.refresh_from_db()
                self.assertEqual(storage.storage_root, directory + '/custom')

    def test_creates_admin_without_printing_password(self):
        output = StringIO()
        with patch.dict(os.environ, {
            'DJANGO_SUPERUSER_USERNAME': 'owner',
            'DJANGO_SUPERUSER_PASSWORD': 'generated-strong-password',
            'DJANGO_SUPERUSER_EMAIL': 'owner@example.test',
        }):
            call_command('bootstrap_admin', stdout=output)
        user = get_user_model().objects.get(username='owner')
        self.assertTrue(user.is_superuser)
        self.assertTrue(user.check_password('generated-strong-password'))
        self.assertNotIn('generated-strong-password', output.getvalue())

    def test_repeated_start_does_not_reset_existing_admin_password(self):
        user = get_user_model().objects.create_superuser('owner', password='changed-by-owner')
        with patch.dict(os.environ, {
            'DJANGO_SUPERUSER_USERNAME': 'owner',
            'DJANGO_SUPERUSER_PASSWORD': 'initial-password',
        }):
            call_command('bootstrap_admin', stdout=StringIO())
        user.refresh_from_db()
        self.assertTrue(user.check_password('changed-by-owner'))

    def test_existing_regular_account_is_not_silently_promoted(self):
        user = get_user_model().objects.create_user('owner', password='regular-password')
        with patch.dict(os.environ, {
            'DJANGO_SUPERUSER_USERNAME': 'owner',
            'DJANGO_SUPERUSER_PASSWORD': 'initial-password',
        }), self.assertRaises(CommandError):
            call_command('bootstrap_admin', stdout=StringIO())
        user.refresh_from_db()
        self.assertFalse(user.is_superuser)

    def test_missing_password_fails_without_creating_an_account(self):
        with patch.dict(os.environ, {'DJANGO_SUPERUSER_USERNAME': 'owner', 'DJANGO_SUPERUSER_PASSWORD': ''}):
            with self.assertRaises(CommandError):
                call_command('bootstrap_admin', stdout=StringIO())
        self.assertFalse(get_user_model().objects.exists())
