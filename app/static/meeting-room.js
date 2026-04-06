(function () {
  const meetingId = window.MEETING_ID;
  const livekitMeetUrl = window.LIVEKIT_MEET_URL || "https://meet.livekit.io";

  const meetingTitleEl = document.getElementById("meetingTitle");
  const meetingMetaEl = document.getElementById("meetingMeta");
  const messageEl = document.getElementById("roomMessage");
  const participantStatsEl = document.getElementById("participantStats");
  const participantListEl = document.getElementById("participantList");
  const stageGridEl = document.getElementById("stageGrid");
  const agentPanelEl = document.getElementById("agentPanel");
  const contextPanelEl = document.getElementById("contextPanel");
  const transcriptListEl = document.getElementById("transcriptList");
  const transcriptFormEl = document.getElementById("transcriptForm");
  const transcriptSpeakerInputEl = document.getElementById("transcriptSpeakerInput");
  const transcriptTextInputEl = document.getElementById("transcriptTextInput");
  const artifactListEl = document.getElementById("artifactList");
  const workspaceActionFormEl = document.getElementById("workspaceActionForm");
  const workspaceInstructionInputEl = document.getElementById("workspaceInstructionInput");
  const workspaceTargetSelectEl = document.getElementById("workspaceTargetSelect");
  const workspaceTaskTypeSelectEl = document.getElementById("workspaceTaskTypeSelect");

  const joinBtn = document.getElementById("joinBtn");
  const joinMeetUiBtn = document.getElementById("joinMeetUiBtn");
  const leaveBtn = document.getElementById("leaveBtn");
  const micBtn = document.getElementById("micBtn");
  const camBtn = document.getElementById("camBtn");
  const screenBtn = document.getElementById("screenBtn");

  const AGENT_DEFS = [
    { agentType: "codex", displayName: "Alice / Codex" },
    { agentType: "claude", displayName: "Bob / Claude" },
  ];

  const state = {
    room: null,
    roomName: "",
    localIdentity: "",
    localMicTrack: null,
    localCamTrack: null,
    localScreenTrack: null,
    micEnabled: true,
    camEnabled: true,
    screenSharing: false,
    allowScreenShare: true,
    participants: new Map(),
    workspaceTimer: null,
    agentSessions: [],
    transcripts: [],
    artifacts: [],
    currentContext: null,
    selectedTranscriptIds: new Set(),
  };

  function setMessage(text, isError = false) {
    messageEl.textContent = text;
    messageEl.classList.toggle("error", isError);
  }

  function getToken() {
    return localStorage.getItem("access_token");
  }

  async function ensureToken() {
    const existing = getToken();
    if (existing) return existing;
    const response = await fetch("/auth/jwt", { credentials: "same-origin" });
    if (!response.ok) {
      setMessage("Session expired, please login again", true);
      return null;
    }
    const payload = await response.json();
    localStorage.setItem("access_token", payload.access_token);
    return payload.access_token;
  }

  async function api(url, options = {}, retry = true) {
    const token = await ensureToken();
    if (!token) throw new Error("Not logged in");
    const headers = options.headers || {};
    headers.Authorization = `Bearer ${token}`;
    if (
      !headers["Content-Type"] &&
      options.body &&
      !(options.body instanceof URLSearchParams) &&
      !(typeof FormData !== "undefined" && options.body instanceof FormData)
    ) {
      headers["Content-Type"] = "application/json";
    }
    let response = await fetch(url, { ...options, headers, credentials: "same-origin" });
    if (response.status === 401 && retry) {
      localStorage.removeItem("access_token");
      const fresh = await ensureToken();
      if (!fresh) throw new Error("Not logged in");
      headers.Authorization = `Bearer ${fresh}`;
      response = await fetch(url, { ...options, headers, credentials: "same-origin" });
    }
    if (!response.ok) {
      const payload = await response.json().catch(() => ({ detail: "Request failed" }));
      throw new Error(payload.detail || "Request failed");
    }
    return response.json();
  }

  function getTile(identity) {
    return stageGridEl.querySelector(`[data-identity="${identity}"]`);
  }

  function createTile(identity, isLocal = false) {
    const tile = document.createElement("article");
    tile.className = "tile";
    tile.dataset.identity = identity;
    const media = document.createElement("div");
    media.className = "tile-media";
    tile.appendChild(media);
    const meta = document.createElement("div");
    meta.className = "tile-meta";
    meta.innerHTML = `
      <span class="tile-name">${identity}</span>
      <span class="tile-badge">${isLocal ? "You" : "Guest"}</span>
    `;
    tile.appendChild(meta);
    stageGridEl.appendChild(tile);
    return tile;
  }

  function getOrCreateTile(identity, isLocal = false) {
    let tile = getTile(identity);
    if (!tile) tile = createTile(identity, isLocal);
    return tile;
  }

  function ensureNoPlaceholder() {
    stageGridEl.querySelector(".placeholder-tile")?.remove();
  }

  function restorePlaceholderIfEmpty() {
    if (stageGridEl.childElementCount > 0) return;
    stageGridEl.innerHTML = `
      <div class="tile placeholder-tile">
        <div class="placeholder-content">
          <p>No media yet</p>
          <p class="hint-text">Click Join to enter the meeting</p>
        </div>
      </div>
    `;
  }

  function agentPresenceLabel(status) {
    return (status || "offline").replace(/_/g, " ");
  }

  function agentSessionFor(agentType) {
    return state.agentSessions.find((item) => item.agent_type === agentType) || null;
  }

  function renderParticipantList() {
    participantListEl.innerHTML = "";
    const participantRows = Array.from(state.participants.values())
      .sort((a, b) => a.identity.localeCompare(b.identity))
      .map((participant) => ({
        name: participant.identity,
        role: participant.isLocal ? "host" : "member",
      }));
    const agentRows = state.agentSessions.map((session) => ({
      name: session.display_name || session.agent_type,
      role: `agent · ${agentPresenceLabel(session.presence_status)}`,
    }));
    const rows = participantRows.concat(agentRows);
    for (const row of rows) {
      const li = document.createElement("li");
      li.className = "participant-item";
      li.innerHTML = `
        <span class="participant-name">${row.name}</span>
        <span class="participant-role">${row.role}</span>
      `;
      participantListEl.appendChild(li);
    }
    participantStatsEl.textContent = `${rows.length} online`;
  }

  function upsertParticipant(identity, isLocal = false) {
    state.participants.set(identity, { identity, isLocal });
    renderParticipantList();
  }

  function removeParticipant(identity) {
    state.participants.delete(identity);
    renderParticipantList();
  }

  function updateControls(connected) {
    joinBtn.disabled = connected;
    leaveBtn.disabled = !connected;
    micBtn.disabled = !connected;
    camBtn.disabled = !connected;
    screenBtn.disabled = !connected || !state.allowScreenShare;
    transcriptSpeakerInputEl.disabled = !connected;
    transcriptTextInputEl.disabled = !connected;
    workspaceInstructionInputEl.disabled = !connected;
    workspaceTargetSelectEl.disabled = !connected;
    workspaceTaskTypeSelectEl.disabled = !connected;
  }

  function updateButtonLabels() {
    micBtn.textContent = state.micEnabled ? "Mute" : "Unmute";
    camBtn.textContent = state.camEnabled ? "Camera Off" : "Camera On";
    screenBtn.textContent = state.screenSharing ? "Stop Share" : "Share Screen";
  }

  function attachTrackToTile(track, identity, isLocal = false) {
    ensureNoPlaceholder();
    const tile = getOrCreateTile(identity, isLocal);
    const mediaEl = tile.querySelector(".tile-media");
    if (track.kind === "video") {
      mediaEl.querySelectorAll("video").forEach((el) => el.remove());
    }
    const attached = track.attach();
    attached.className = "video-element";
    mediaEl.appendChild(attached);
  }

  function renderAgentPanel() {
    agentPanelEl.innerHTML = "";
    for (const agent of AGENT_DEFS) {
      const session = agentSessionFor(agent.agentType);
      const card = document.createElement("div");
      card.className = "agent-card";
      card.innerHTML = `
        <div class="agent-card-header">
          <span class="agent-title">${agent.displayName}</span>
          <span class="presence-badge">${agentPresenceLabel(session?.presence_status || "offline")}</span>
        </div>
        <div class="agent-meta">
          ${session?.current_task_title ? `Task: ${session.current_task_title}` : "Not connected yet"}
          ${session?.bridge_online ? " · bridge online" : ""}
        </div>
        <div class="agent-meta">
          ${session?.latest_short_reply || "No recent reply"}
        </div>
        <div class="agent-actions">
          <div class="agent-actions-row">
            <button type="button" class="control-btn" data-agent-connect="${agent.agentType}">Bring ${agent.displayName}</button>
            <button type="button" class="control-btn" data-agent-quick="${agent.agentType}:summarize">Summarize</button>
            <button type="button" class="control-btn" data-agent-quick="${agent.agentType}:extract_todos">Todos</button>
            <button type="button" class="control-btn" data-agent-quick="${agent.agentType}:draft_api">Draft API</button>
          </div>
          <div class="agent-actions-row">
            <input type="text" data-agent-input="${agent.agentType}" placeholder="Talk to ${agent.displayName}..." maxlength="4000" />
            <button type="button" class="control-btn control-primary" data-agent-send="${agent.agentType}">Ask</button>
          </div>
        </div>
      `;
      agentPanelEl.appendChild(card);
    }
  }

  function renderContextPanel() {
    if (!state.currentContext) {
      contextPanelEl.innerHTML = '<p class="empty-text">No context yet.</p>';
      return;
    }
    const { topic_label, summary_text, decisions, todos, source_chunk_ids } = state.currentContext;
    contextPanelEl.innerHTML = `
      <div class="context-block">
        <div class="artifact-head">
          <span class="artifact-title">${topic_label || "Current discussion"}</span>
          <span class="artifact-type">${source_chunk_ids?.length || 0} chunks</span>
        </div>
        <div class="context-summary">${summary_text || "No rolling summary yet."}</div>
        <ul class="context-list">
          ${(decisions || []).map((item) => `<li>${item}</li>`).join("")}
          ${(todos || []).map((item) => `<li>${item}</li>`).join("")}
        </ul>
      </div>
    `;
  }

  function renderTranscriptList() {
    transcriptListEl.innerHTML = "";
    if (!state.transcripts.length) {
      transcriptListEl.innerHTML = '<p class="empty-text">No transcript yet. Add manual transcript or connect realtime STT later.</p>';
      return;
    }
    for (const item of state.transcripts) {
      const selected = state.selectedTranscriptIds.has(item.id);
      const row = document.createElement("div");
      row.className = "transcript-item";
      row.innerHTML = `
        <div class="check-row">
          <input type="checkbox" data-transcript-checkbox="${item.id}" ${selected ? "checked" : ""} />
          <div class="transcript-body">
            <div class="transcript-head">
              <span class="transcript-speaker">${item.speaker_name || item.speaker_identity || "Speaker"}</span>
              <span class="transcript-badge">${item.source}${item.is_final ? "" : " · partial"}</span>
            </div>
            <div class="transcript-text">${item.text}</div>
            <div class="transcript-meta">chunk #${item.id} · seq ${item.sequence_no}</div>
            <div class="transcript-actions-row">
              <button type="button" class="control-btn" data-transcript-send="codex:${item.id}">To Alice</button>
              <button type="button" class="control-btn" data-transcript-send="claude:${item.id}">To Bob</button>
            </div>
          </div>
        </div>
      `;
      transcriptListEl.appendChild(row);
    }
  }

  function renderArtifacts() {
    artifactListEl.innerHTML = "";
    if (!state.artifacts.length) {
      artifactListEl.innerHTML = '<p class="empty-text">No outputs yet.</p>';
      return;
    }
    for (const artifact of state.artifacts) {
      const row = document.createElement("div");
      row.className = "artifact-item";
      row.innerHTML = `
        <div class="artifact-head">
          <span class="artifact-title">${artifact.title || "Untitled output"}</span>
          <span class="artifact-type">${artifact.artifact_type}</span>
        </div>
        <div class="artifact-content">${artifact.content}</div>
        <div class="artifact-meta">artifact #${artifact.id}</div>
      `;
      artifactListEl.appendChild(row);
    }
  }

  async function loadWorkspace() {
    if (!state.room) return;
    const [agents, context, transcripts, artifacts] = await Promise.all([
      api(`/api/meetings/${meetingId}/agents`),
      api(`/api/meetings/${meetingId}/context/current`),
      api(`/api/meetings/${meetingId}/transcripts?limit=80`),
      api(`/api/meetings/${meetingId}/artifacts?limit=20`),
    ]);
    state.agentSessions = agents;
    state.currentContext = context;
    state.transcripts = transcripts;
    state.artifacts = artifacts;
    renderParticipantList();
    renderAgentPanel();
    renderContextPanel();
    renderTranscriptList();
    renderArtifacts();
  }

  async function fetchMeetingInfo() {
    const meeting = await api(`/api/meetings/${meetingId}`);
    meetingTitleEl.textContent = meeting.title;
    meetingMetaEl.textContent = `会议号: ${meeting.room_name}`;
    state.allowScreenShare = meeting.allow_screen_share !== false;
    updateControls(Boolean(state.room));
    return meeting;
  }

  async function fetchJoinToken() {
    return api(`/api/meetings/${meetingId}/join-token`, { method: "POST" });
  }

  async function joinMeeting() {
    const tokenData = await fetchJoinToken();
    state.roomName = tokenData.room_name;
    state.localIdentity = tokenData.participant_identity;
    state.allowScreenShare = tokenData.allow_screen_share !== false;

    const room = new LivekitClient.Room({ adaptiveStream: true, dynacast: true });
    state.room = room;

    room.on(LivekitClient.RoomEvent.ParticipantConnected, (participant) => {
      upsertParticipant(participant.identity, false);
      getOrCreateTile(participant.identity, false);
    });

    room.on(LivekitClient.RoomEvent.ParticipantDisconnected, (participant) => {
      getTile(participant.identity)?.remove();
      removeParticipant(participant.identity);
      restorePlaceholderIfEmpty();
    });

    room.on(LivekitClient.RoomEvent.TrackSubscribed, (track, _publication, participant) => {
      attachTrackToTile(track, participant.identity, false);
    });

    room.on(LivekitClient.RoomEvent.TrackUnsubscribed, (track, _publication, participant) => {
      track.detach().forEach((el) => el.remove());
      const tile = getTile(participant.identity);
      if (tile && tile.querySelector(".tile-media").childElementCount === 0) {
        tile.remove();
      }
      restorePlaceholderIfEmpty();
    });

    await room.connect(tokenData.livekit_url, tokenData.token);

    upsertParticipant(state.localIdentity, true);
    getOrCreateTile(state.localIdentity, true);
    for (const remote of room.remoteParticipants.values()) {
      upsertParticipant(remote.identity, false);
      getOrCreateTile(remote.identity, false);
    }

    state.localMicTrack = await LivekitClient.createLocalAudioTrack();
    state.localCamTrack = await LivekitClient.createLocalVideoTrack();
    await room.localParticipant.publishTrack(state.localMicTrack);
    await room.localParticipant.publishTrack(state.localCamTrack);
    attachTrackToTile(state.localCamTrack, state.localIdentity, true);

    state.micEnabled = true;
    state.camEnabled = true;
    state.screenSharing = false;
    updateControls(true);
    updateButtonLabels();
    await loadWorkspace();
    if (state.workspaceTimer) clearInterval(state.workspaceTimer);
    state.workspaceTimer = setInterval(() => {
      loadWorkspace().catch(() => {});
    }, 5000);
    setMessage(`Connected to ${state.roomName}`);
  }

  async function leaveMeeting() {
    if (!state.room) return;
    await state.room.disconnect();
    state.localMicTrack?.stop();
    state.localCamTrack?.stop();
    state.localScreenTrack?.stop();
    stageGridEl.innerHTML = "";
    participantListEl.innerHTML = "";
    state.participants.clear();
    state.room = null;
    state.localMicTrack = null;
    state.localCamTrack = null;
    state.localScreenTrack = null;
    state.screenSharing = false;
    state.agentSessions = [];
    state.transcripts = [];
    state.artifacts = [];
    state.currentContext = null;
    state.selectedTranscriptIds.clear();
    if (state.workspaceTimer) {
      clearInterval(state.workspaceTimer);
      state.workspaceTimer = null;
    }
    updateControls(false);
    updateButtonLabels();
    renderParticipantList();
    renderAgentPanel();
    renderContextPanel();
    renderTranscriptList();
    renderArtifacts();
    restorePlaceholderIfEmpty();
    setMessage("Disconnected");
  }

  async function toggleMic() {
    if (!state.localMicTrack) return;
    if (state.micEnabled) await state.localMicTrack.mute();
    else await state.localMicTrack.unmute();
    state.micEnabled = !state.micEnabled;
    updateButtonLabels();
  }

  async function toggleCam() {
    if (!state.localCamTrack) return;
    if (state.camEnabled) await state.localCamTrack.mute();
    else await state.localCamTrack.unmute();
    state.camEnabled = !state.camEnabled;
    updateButtonLabels();
  }

  async function toggleScreenShare() {
    if (!state.room) return;
    if (!state.allowScreenShare) {
      setMessage("Screen sharing is disabled for this meeting", true);
      return;
    }
    if (!state.screenSharing) {
      const screenTracks = await LivekitClient.createLocalScreenTracks();
      state.localScreenTrack = screenTracks[0];
      await state.room.localParticipant.publishTrack(state.localScreenTrack);
      attachTrackToTile(state.localScreenTrack, state.localIdentity, true);
      state.screenSharing = true;
      state.localScreenTrack.onended = async () => {
        if (!state.room || !state.localScreenTrack) return;
        await state.room.localParticipant.unpublishTrack(state.localScreenTrack);
        state.localScreenTrack.stop();
        state.localScreenTrack = null;
        state.screenSharing = false;
        attachTrackToTile(state.localCamTrack, state.localIdentity, true);
        updateButtonLabels();
      };
      setMessage("Screen sharing started");
    } else if (state.localScreenTrack) {
      await state.room.localParticipant.unpublishTrack(state.localScreenTrack);
      state.localScreenTrack.stop();
      state.localScreenTrack = null;
      state.screenSharing = false;
      attachTrackToTile(state.localCamTrack, state.localIdentity, true);
      setMessage("Screen sharing stopped");
    }
    updateButtonLabels();
  }

  async function openLiveKitMeet() {
    const tokenData = await fetchJoinToken();
    const base = livekitMeetUrl.replace(/\/+$/, "");
    const url = `${base}/custom/?liveKitUrl=${encodeURIComponent(tokenData.livekit_url)}&token=${encodeURIComponent(tokenData.token)}`;
    window.open(url, "_blank");
  }

  async function connectAgent(agentType) {
    await api(`/api/meetings/${meetingId}/agents`, {
      method: "POST",
      body: JSON.stringify({ agent_type: agentType }),
    });
    await loadWorkspace();
    setMessage(`${agentType} connected to this meeting workspace`);
  }

  async function runAgentAction(agentType, taskType, instruction = "", chunkIds = null) {
    await api(`/api/meetings/${meetingId}/agent-actions`, {
      method: "POST",
      body: JSON.stringify({
        agent_type: agentType,
        task_type: taskType,
        instruction,
        chunk_ids: chunkIds || Array.from(state.selectedTranscriptIds),
      }),
    });
    await loadWorkspace();
    setMessage(`${agentType} completed ${taskType}`);
  }

  joinBtn.addEventListener("click", async () => {
    try {
      await joinMeeting();
    } catch (err) {
      setMessage(err.message || "Join failed", true);
      updateControls(false);
    }
  });

  joinMeetUiBtn.addEventListener("click", async () => {
    try {
      await openLiveKitMeet();
    } catch (err) {
      setMessage(err.message || "Open LiveKit Meet failed", true);
    }
  });

  leaveBtn.addEventListener("click", async () => {
    try {
      await leaveMeeting();
    } catch (err) {
      setMessage(err.message || "Leave failed", true);
    }
  });

  micBtn.addEventListener("click", async () => {
    try {
      await toggleMic();
    } catch (err) {
      setMessage(err.message || "Mic toggle failed", true);
    }
  });

  camBtn.addEventListener("click", async () => {
    try {
      await toggleCam();
    } catch (err) {
      setMessage(err.message || "Camera toggle failed", true);
    }
  });

  screenBtn.addEventListener("click", async () => {
    try {
      await toggleScreenShare();
    } catch (err) {
      setMessage(err.message || "Share screen failed", true);
    }
  });

  agentPanelEl.addEventListener("click", async (event) => {
    const connectBtn = event.target.closest("[data-agent-connect]");
    const quickBtn = event.target.closest("[data-agent-quick]");
    const sendBtn = event.target.closest("[data-agent-send]");
    try {
      if (connectBtn) {
        await connectAgent(connectBtn.dataset.agentConnect);
      } else if (quickBtn) {
        const [agentType, taskType] = quickBtn.dataset.agentQuick.split(":");
        await runAgentAction(agentType, taskType);
      } else if (sendBtn) {
        const agentType = sendBtn.dataset.agentSend;
        const input = agentPanelEl.querySelector(`[data-agent-input="${agentType}"]`);
        const instruction = (input?.value || "").trim();
        if (!instruction) return;
        await runAgentAction(agentType, "ask", instruction);
        if (input) input.value = "";
      }
    } catch (err) {
      setMessage(err.message || "Agent action failed", true);
    }
  });

  transcriptListEl.addEventListener("change", (event) => {
    const checkbox = event.target.closest("[data-transcript-checkbox]");
    if (!checkbox) return;
    const chunkId = Number(checkbox.dataset.transcriptCheckbox);
    if (checkbox.checked) state.selectedTranscriptIds.add(chunkId);
    else state.selectedTranscriptIds.delete(chunkId);
  });

  transcriptListEl.addEventListener("click", async (event) => {
    const sendBtn = event.target.closest("[data-transcript-send]");
    if (!sendBtn) return;
    try {
      const [agentType, chunkId] = sendBtn.dataset.transcriptSend.split(":");
      await runAgentAction(agentType, "ask", "", [Number(chunkId)]);
    } catch (err) {
      setMessage(err.message || "Transcript action failed", true);
    }
  });

  transcriptFormEl.addEventListener("submit", async (event) => {
    event.preventDefault();
    const text = (transcriptTextInputEl.value || "").trim();
    if (!text) return;
    try {
      await api(`/api/meetings/${meetingId}/transcripts`, {
        method: "POST",
        body: JSON.stringify({
          speaker_name: (transcriptSpeakerInputEl.value || "").trim(),
          text,
          source: "manual",
          is_final: true,
        }),
      });
      transcriptTextInputEl.value = "";
      await loadWorkspace();
      setMessage("Transcript added");
    } catch (err) {
      setMessage(err.message || "Add transcript failed", true);
    }
  });

  workspaceActionFormEl.addEventListener("submit", async (event) => {
    event.preventDefault();
    try {
      await runAgentAction(
        workspaceTargetSelectEl.value,
        workspaceTaskTypeSelectEl.value,
        (workspaceInstructionInputEl.value || "").trim(),
      );
      workspaceInstructionInputEl.value = "";
    } catch (err) {
      setMessage(err.message || "Workspace action failed", true);
    }
  });

  window.addEventListener("beforeunload", () => {
    if (state.room) state.room.disconnect();
  });

  updateControls(false);
  updateButtonLabels();
  renderParticipantList();
  renderAgentPanel();
  renderContextPanel();
  renderTranscriptList();
  renderArtifacts();
  fetchMeetingInfo().catch((err) => {
    setMessage(err.message || "Load meeting info failed", true);
  });
})();
