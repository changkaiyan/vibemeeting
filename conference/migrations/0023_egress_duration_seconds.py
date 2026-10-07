from django.db import migrations


def convert_existing_duration(apps, schema_editor):
    Recording = apps.get_model('conference', 'MeetingRecording')
    records = Recording.objects.using(schema_editor.connection.alias)
    pending = []
    for row in records.exclude(egress_id='').filter(duration_seconds__isnull=False).iterator(chunk_size=500):
        row.duration_seconds = max(0, row.duration_seconds // 1_000_000_000)
        pending.append(row)
        if len(pending) == 500:
            records.bulk_update(pending, ['duration_seconds'], batch_size=500)
            pending.clear()
    if pending:
        records.bulk_update(pending, ['duration_seconds'], batch_size=500)


class Migration(migrations.Migration):
    dependencies = [('conference', '0022_alter_meetingtranscriptchunk_source')]
    operations = [migrations.RunPython(convert_existing_duration)]
