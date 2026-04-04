from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("conference", "0014_billing_models_and_meeting_room_session_started_at"),
    ]

    operations = [
        migrations.AddField(
            model_name="billingplan",
            name="max_current_room_used_seconds",
            field=models.PositiveBigIntegerField(default=0),
        ),
    ]
