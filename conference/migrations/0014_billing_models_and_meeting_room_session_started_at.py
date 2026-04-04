from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    dependencies = [
        ("auth", "0012_alter_user_first_name_max_length"),
        ("conference", "0013_meeting_recurrence_meeting_timezone"),
    ]

    operations = [
        migrations.CreateModel(
            name="BillingPlan",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(db_index=True, max_length=100, unique=True)),
                ("description", models.CharField(blank=True, default="", max_length=300)),
                ("max_active_rooms", models.PositiveIntegerField(default=1)),
                ("max_room_participants", models.PositiveIntegerField(default=100)),
                ("max_room_used_seconds", models.PositiveBigIntegerField(default=0)),
                ("max_recording_storage_bytes", models.PositiveBigIntegerField(default=0)),
                ("max_meeting_count", models.PositiveIntegerField(default=10)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
        ),
        migrations.CreateModel(
            name="UserBillingProfile",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("room_peak_count", models.PositiveIntegerField(default=0)),
                ("accumulated_room_used_seconds", models.PositiveBigIntegerField(default=0)),
                ("updated_at", models.DateTimeField(auto_now=True)),
                ("plan", models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="user_profiles", to="conference.billingplan")),
                ("user", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="billing_profile", to="auth.user")),
            ],
        ),
        migrations.AddField(
            model_name="meeting",
            name="room_session_started_at",
            field=models.DateTimeField(blank=True, db_index=True, null=True),
        ),
    ]
