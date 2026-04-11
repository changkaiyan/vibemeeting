from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("conference", "0021_meeting_separate_openai_volc_fields"),
    ]

    operations = [
        migrations.AlterField(
            model_name="meetingtranscriptchunk",
            name="source",
            field=models.CharField(
                choices=[
                    ("live_stream", "Live Stream"),
                    ("manual", "Manual"),
                    ("stt_upload", "STT Upload"),
                    ("mock", "Mock"),
                ],
                default="manual",
                max_length=16,
            ),
        ),
    ]
