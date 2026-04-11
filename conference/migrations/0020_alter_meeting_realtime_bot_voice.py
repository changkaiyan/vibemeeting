from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ("conference", "0019_meeting_separate_openai_volc_fields"),
    ]

    operations = [
        migrations.AlterField(
            model_name="meeting",
            name="realtime_bot_voice",
            field=models.CharField(blank=True, default="marin", max_length=120),
        ),
    ]
