from dataclasses import dataclass

from conference.meeting_refs import meeting_from_ref
from conference.models import Meeting


@dataclass(frozen=True)
class MeetingLookup:
    meeting_id: int | None = None
    meeting_ref: str | None = None
    hidden_forbidden: bool = False

    def resolve(self, user):
        if self.meeting_ref is not None:
            return meeting_from_ref(user, self.meeting_ref)
        if self.meeting_id is not None:
            return Meeting.objects.filter(id=self.meeting_id).first()
        raise ValueError("MeetingLookup requires meeting_id or meeting_ref")
