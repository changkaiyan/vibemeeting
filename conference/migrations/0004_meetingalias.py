from django.conf import settings
from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ("conference", "0003_meetingmember_display_name_userprofile"),
    ]

    operations = [
        migrations.CreateModel(
            name="MeetingAlias",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("meeting_ref", models.CharField(max_length=24)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("meeting", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="aliases", to="conference.meeting")),
                ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="meeting_aliases", to=settings.AUTH_USER_MODEL)),
            ],
        ),
        migrations.AddConstraint(
            model_name="meetingalias",
            constraint=models.UniqueConstraint(fields=("user", "meeting"), name="uq_meeting_alias_user_meeting"),
        ),
        migrations.AddConstraint(
            model_name="meetingalias",
            constraint=models.UniqueConstraint(fields=("user", "meeting_ref"), name="uq_meeting_alias_user_ref"),
        ),
    ]
