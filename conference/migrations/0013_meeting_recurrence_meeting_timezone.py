from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("conference", "0012_meetingmember_display_name_version_and_more"),
    ]

    operations = [
        migrations.AddField(
            model_name="meeting",
            name="meeting_recurrence",
            field=models.CharField(
                choices=[
                    ("once", "Once"),
                    ("daily", "Daily"),
                    ("weekly", "Weekly"),
                    ("monthly", "Monthly"),
                ],
                default="once",
                max_length=16,
            ),
        ),
        migrations.AddField(
            model_name="meeting",
            name="meeting_timezone",
            field=models.CharField(default="Asia/Shanghai", max_length=64),
        ),
    ]
