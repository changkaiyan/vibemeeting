"""Idempotent first-install administration and recording setup."""
import os
from pathlib import Path

from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError

from conference.models import RecordingStorageConfig


class Command(BaseCommand):
    help = 'Create the initial administrator and configure recording storage without resetting existing settings.'

    def handle(self, *args, **options):
        username = os.getenv('DJANGO_SUPERUSER_USERNAME', '').strip()
        password = os.getenv('DJANGO_SUPERUSER_PASSWORD', '')
        if not username or not password:
            raise CommandError('DJANGO_SUPERUSER_USERNAME and DJANGO_SUPERUSER_PASSWORD are required.')
        users = get_user_model().objects
        user = users.filter(username=username).first()
        if user is None:
            users.create_superuser(username=username, password=password,
                                   email=os.getenv('DJANGO_SUPERUSER_EMAIL', ''))
            self.stdout.write('Initial administrator created.')
        elif not user.is_superuser:
            raise CommandError('The configured administrator name belongs to a regular account; choose a different name.')
        else:
            self.stdout.write('Existing administrator preserved; password unchanged.')
        root = os.getenv('RECORDING_STORAGE_ROOT', '').strip()
        if root:
            directory = Path(root).expanduser().resolve()
            directory.mkdir(parents=True, exist_ok=True)
            config = RecordingStorageConfig.objects.order_by('id').first()
            if config is None:
                RecordingStorageConfig.objects.create(storage_root=str(directory))
            elif not config.storage_root.strip():
                config.storage_root = str(directory)
                config.save(update_fields=['storage_root', 'updated_at'])
            self.stdout.write('Recording storage initialized; existing configuration preserved.')
