from dataclasses import dataclass


@dataclass(frozen=True)
class StabilizedTranscript:
    stable_prefix: str
    unstable_suffix: str
    combined_text: str
    stable_delta: str
    should_emit: bool


class TranscriptStabilizer:
    def __init__(self):
        self._previous_text = ""
        self._stable_prefix = ""

    def update(self, text: str) -> StabilizedTranscript:
        current = str(text or "").strip()
        common_prefix = _longest_common_prefix(self._previous_text, current)
        unstable_suffix = current[len(common_prefix) :]
        stable_delta = common_prefix[len(self._stable_prefix) :] if len(common_prefix) >= len(self._stable_prefix) else ""
        should_emit = current != self._previous_text
        self._previous_text = current
        self._stable_prefix = common_prefix
        return StabilizedTranscript(
            stable_prefix=common_prefix,
            unstable_suffix=unstable_suffix,
            combined_text=current,
            stable_delta=stable_delta,
            should_emit=should_emit,
        )

    def reset(self) -> None:
        self._previous_text = ""
        self._stable_prefix = ""


def _longest_common_prefix(left: str, right: str) -> str:
    limit = min(len(left), len(right))
    index = 0
    while index < limit and left[index] == right[index]:
        index += 1
    return left[:index]
