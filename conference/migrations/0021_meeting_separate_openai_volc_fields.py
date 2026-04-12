from django.db import migrations, models


def _seed_separate_engine_fields(apps, schema_editor):
    Meeting = apps.get_model("conference", "Meeting")
    default_openai_model = "gpt-realtime"
    default_openai_voice = "marin"
    default_volc_model = "2.2.0.0"

    for meeting in Meeting.objects.all().iterator():
        provider = str(getattr(meeting, "realtime_bot_provider", "") or "").strip().lower()
        legacy_model = str(getattr(meeting, "realtime_bot_model", "") or "").strip()
        legacy_voice = str(getattr(meeting, "realtime_bot_voice", "") or "").strip()

        next_openai_model = (
            legacy_model if provider != "volcengine" and legacy_model else default_openai_model
        )
        next_openai_voice = (
            legacy_voice if provider != "volcengine" and legacy_voice else default_openai_voice
        )
        next_volc_model = legacy_model if provider == "volcengine" and legacy_model else default_volc_model
        next_volc_voice = legacy_voice if provider == "volcengine" and legacy_voice else ""

        meeting.realtime_bot_openai_model = next_openai_model
        meeting.realtime_bot_openai_voice = next_openai_voice
        meeting.realtime_bot_volc_model = next_volc_model
        meeting.realtime_bot_volc_voice = next_volc_voice
        meeting.save(
            update_fields=[
                "realtime_bot_openai_model",
                "realtime_bot_openai_voice",
                "realtime_bot_volc_model",
                "realtime_bot_volc_voice",
            ]
        )


class Migration(migrations.Migration):
    dependencies = [
        ("conference", "0020_merge_20260410_1422"),
    ]

    operations = [
        migrations.AddField(
            model_name="meeting",
            name="realtime_bot_openai_model",
            field=models.CharField(blank=True, default="gpt-realtime", max_length=120),
        ),
        migrations.AddField(
            model_name="meeting",
            name="realtime_bot_openai_voice",
            field=models.CharField(blank=True, default="marin", max_length=40),
        ),
        migrations.AddField(
            model_name="meeting",
            name="realtime_bot_volc_model",
            field=models.CharField(blank=True, default="2.2.0.0", max_length=20),
        ),
        migrations.AddField(
            model_name="meeting",
            name="realtime_bot_volc_voice",
            field=models.CharField(blank=True, default="", max_length=120),
        ),
        migrations.AlterField(
            model_name="meeting",
            name="realtime_bot_voice",
            field=models.CharField(blank=True, default="marin", max_length=120),
        ),
        migrations.RunPython(_seed_separate_engine_fields, migrations.RunPython.noop),
    ]
