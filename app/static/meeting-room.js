(function () {
  const meetingId = window.MEETING_ID;
  const livekitMeetUrl = window.LIVEKIT_MEET_URL || "https://meet.livekit.io";

  const meetingTitleEl = document.getElementById("meetingTitle");
  const meetingMetaEl = document.getElementById("meetingMeta");
  const messageEl = document.getElementById("roomMessage");
  const participantStatsEl = document.getElementById("participantStats");
  const participantListEl = document.getElementById("participantList");
  const stageGridEl = document.getElementById("stageGrid");
  const chatListEl = document.getElementById("chatList");
  const chatFormEl = document.getElementById("chatForm");
  const chatInputEl = document.getElementById("chatInput");

  const joinBtn = document.getElementById("joinBtn");
  const joinMeetUiBtn = document.getElementById("joinMeetUiBtn");
  const leaveBtn = document.getElementById("leaveBtn");
  const micBtn = document.getElementById("micBtn");
  const camBtn = document.getElementById("camBtn");
  const screenBtn = document.getElementById("screenBtn");

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
    allowChat: true,
    participants: new Map(),
    chatTimer: null,
    latestMessageId: 0,
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
    if (!headers["Content-Type"] && options.body && !(options.body instanceof URLSearchParams)) {
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

  function renderParticipantList() {
    participantListEl.innerHTML = "";
    const sorted = Array.from(state.participants.values()).sort((a, b) =>
      a.identity.localeCompare(b.identity),
    );
    for (const p of sorted) {
      const li = document.createElement("li");
      li.className = "participant-item";
      li.innerHTML = `
        <span class="participant-name">${p.identity}</span>
        <span class="participant-role">${p.isLocal ? "host" : "member"}</span>
      `;
      participantListEl.appendChild(li);
    }
    participantStatsEl.textContent = `${sorted.length} online`;
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
    chatInputEl.disabled = !connected || !state.allowChat;
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

  function appendChatMessage(message) {
    const row = document.createElement("div");
    row.className = "chat-item";
    row.innerHTML = `
      <div class="chat-meta">${message.sender_username}</div>
      <div>${message.content}</div>
    `;
    chatListEl.appendChild(row);
    chatListEl.scrollTop = chatListEl.scrollHeight;
    state.latestMessageId = Math.max(state.latestMessageId, message.id);
  }

  async function loadMessages() {
    if (!state.allowChat) {
      chatListEl.innerHTML = "";
      state.latestMessageId = 0;
      return;
    }
    const messages = await api(`/api/meetings/${meetingId}/messages?limit=100`);
    chatListEl.innerHTML = "";
    state.latestMessageId = 0;
    for (const message of messages) {
      appendChatMessage(message);
    }
  }

  async function pollMessages() {
    if (!state.room || !state.allowChat) return;
    const messages = await api(`/api/meetings/${meetingId}/messages?limit=30`);
    for (const message of messages) {
      if (message.id > state.latestMessageId) {
        appendChatMessage(message);
      }
    }
  }

  async function fetchMeetingInfo() {
    const meeting = await api(`/api/meetings/${meetingId}`);
    meetingTitleEl.textContent = meeting.title;
    meetingMetaEl.textContent = `会议号: ${meeting.room_name}`;
    state.allowScreenShare = meeting.allow_screen_share !== false;
    state.allowChat = meeting.allow_chat !== false;
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
    state.allowChat = tokenData.allow_chat !== false;

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
    await loadMessages();
    if (state.chatTimer) clearInterval(state.chatTimer);
    state.chatTimer = setInterval(() => {
      pollMessages().catch(() => {});
    }, 3000);
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
    if (state.chatTimer) {
      clearInterval(state.chatTimer);
      state.chatTimer = null;
    }
    chatListEl.innerHTML = "";
    state.latestMessageId = 0;
    updateControls(false);
    updateButtonLabels();
    renderParticipantList();
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

  chatFormEl.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (!state.room) return;
    if (!state.allowChat) {
      setMessage("Chat is disabled for this meeting", true);
      return;
    }
    const content = (chatInputEl.value || "").trim();
    if (!content) return;
    try {
      const message = await api(`/api/meetings/${meetingId}/messages`, {
        method: "POST",
        body: JSON.stringify({ content }),
      });
      if (message.id > state.latestMessageId) {
        appendChatMessage(message);
      }
      chatInputEl.value = "";
    } catch (err) {
      setMessage(err.message || "Send message failed", true);
    }
  });

  window.addEventListener("beforeunload", () => {
    if (state.room) state.room.disconnect();
  });

  updateControls(false);
  updateButtonLabels();
  renderParticipantList();
  chatInputEl.disabled = true;
  fetchMeetingInfo().catch((err) => {
    setMessage(err.message || "Load meeting info failed", true);
  });
})();
