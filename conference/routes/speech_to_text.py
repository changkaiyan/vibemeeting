from django.urls import path

from conference.speech_to_text import views


urlpatterns = [
    path("api/meetings/<int:meeting_id>/transcripts/stt-upload", views.meeting_stt_upload),
]
