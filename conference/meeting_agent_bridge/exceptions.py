class MeetingAgentBridgeError(RuntimeError):
    pass


class MeetingAgentBridgeUnavailable(MeetingAgentBridgeError):
    pass


class MeetingAgentActionError(MeetingAgentBridgeError):
    pass
