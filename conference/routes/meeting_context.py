from django.urls import path

from conference.meeting_context import views


urlpatterns = [
    path("api/meetings/<int:meeting_id>/transcripts", views.meeting_transcripts),
    path("api/meetings/<int:meeting_id>/context/current", views.meeting_context_current),
    path("api/meetings/<int:meeting_id>/agents", views.meeting_agents),
    path("api/meetings/<int:meeting_id>/agent-actions", views.meeting_agent_actions),
    path("api/meetings/<int:meeting_id>/artifacts", views.meeting_artifacts),
]
