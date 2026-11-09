// Voice chat for watch parties: a WebRTC audio mesh (fine for small groups)
// using the "perfect negotiation" pattern. Signalling travels through the
// party event stream. The same wire format is used by the MILLITOP TV app:
//   description: { type, sdp }
//   candidate:   { candidate, sdpMid, sdpMLineIndex }
//   hangup:      {}
export class VoiceMesh {
  constructor({ api, audioHost, onChange }) {
    this.api = api;
    this.audioHost = audioHost;
    this.onChange = onChange ?? (() => {});
    this.meId = null;
    this.active = false;
    this.muted = false;
    this.listenOnly = false;
    this.stream = null;
    this.peers = new Map();
    this.iceServers = null;
    this.levels = new Map();
    this.audioContext = null;
    this.meterTimer = null;
  }

  async join(meId) {
    this.meId = meId;
    const { iceServers } = await this.api('GET', '/api/watch/ice');
    this.iceServers = iceServers;
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }, video: false
      });
      this.listenOnly = false;
    } catch (error) {
      this.stream = null;
      this.listenOnly = true;
      this.permissionError = error?.name === 'NotAllowedError'
        ? 'Microphone permission was blocked, so you joined listen-only.'
        : 'No microphone was found, so you joined listen-only.';
    }
    this.active = true;
    this.muted = false;
    this.startMeters();
    await this.announce();
    this.onChange();
  }

  async announce() {
    await this.api('POST', '/api/watch/voice', { active: this.active, muted: this.muted, listenOnly: this.listenOnly });
  }

  async setMuted(muted) {
    this.muted = muted;
    for (const track of this.stream?.getAudioTracks() ?? []) track.enabled = !muted;
    await this.announce();
    this.onChange();
  }

  async leave() {
    if (!this.active) return;
    this.active = false;
    for (const id of [...this.peers.keys()]) {
      this.api('POST', '/api/watch/signal', { to: id, kind: 'hangup', payload: {} }).catch(() => {});
      this.closePeer(id);
    }
    for (const track of this.stream?.getTracks() ?? []) track.stop();
    this.stream = null;
    clearInterval(this.meterTimer);
    this.levels.clear();
    await this.api('POST', '/api/watch/voice', { active: false }).catch(() => {});
    this.onChange();
  }

  // Called with the latest participant list; connects to everyone in voice.
  sync(participants) {
    if (!this.active) return;
    const wanted = new Set(participants.filter(p => p.id !== this.meId && p.online && p.voice).map(p => p.id));
    for (const id of wanted) if (!this.peers.has(id)) this.peer(id);
    for (const id of [...this.peers.keys()]) if (!wanted.has(id)) this.closePeer(id);
  }

  peer(id) {
    let entry = this.peers.get(id);
    if (entry) return entry;
    const pc = new RTCPeerConnection({ iceServers: this.iceServers ?? [] });
    entry = { pc, polite: this.meId > id, makingOffer: false, ignoreOffer: false, audio: null, pendingCandidates: [] };
    this.peers.set(id, entry);
    if (this.stream) for (const track of this.stream.getAudioTracks()) pc.addTrack(track, this.stream);
    else pc.addTransceiver('audio', { direction: 'recvonly' });
    pc.onnegotiationneeded = async () => {
      try {
        entry.makingOffer = true;
        await pc.setLocalDescription();
        await this.send(id, 'description', { type: pc.localDescription.type, sdp: pc.localDescription.sdp });
      } catch {
        // A later negotiation will retry.
      } finally {
        entry.makingOffer = false;
      }
    };
    pc.onicecandidate = ({ candidate }) => {
      if (candidate) this.send(id, 'candidate', { candidate: candidate.candidate, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex }).catch(() => {});
    };
    pc.ontrack = ({ streams, track }) => {
      const stream = streams[0] ?? new MediaStream([track]);
      if (!entry.audio) {
        entry.audio = document.createElement('audio');
        entry.audio.autoplay = true;
        this.audioHost.append(entry.audio);
      }
      entry.audio.srcObject = stream;
      entry.audio.play().catch(() => {});
      this.meter(id, stream);
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'failed') pc.restartIce?.();
      this.onChange();
    };
    return entry;
  }

  closePeer(id) {
    const entry = this.peers.get(id);
    if (!entry) return;
    this.peers.delete(id);
    this.levels.delete(id);
    try { entry.pc.close(); } catch {}
    entry.audio?.remove();
  }

  send(to, kind, payload) { return this.api('POST', '/api/watch/signal', { to, kind, payload }); }

  async handleSignal({ from, kind, payload }) {
    if (kind === 'hangup') { this.closePeer(from); this.onChange(); return; }
    if (!this.active) return;
    const entry = this.peer(from);
    const pc = entry.pc;
    try {
      if (kind === 'description') {
        const offerCollision = payload.type === 'offer' && (entry.makingOffer || pc.signalingState !== 'stable');
        entry.ignoreOffer = !entry.polite && offerCollision;
        if (entry.ignoreOffer) return;
        await pc.setRemoteDescription({ type: payload.type, sdp: payload.sdp });
        for (const candidate of entry.pendingCandidates.splice(0)) await pc.addIceCandidate(candidate).catch(() => {});
        if (payload.type === 'offer') {
          await pc.setLocalDescription();
          await this.send(from, 'description', { type: pc.localDescription.type, sdp: pc.localDescription.sdp });
        }
      } else if (kind === 'candidate') {
        const candidate = { candidate: payload.candidate, sdpMid: payload.sdpMid, sdpMLineIndex: payload.sdpMLineIndex };
        if (!pc.remoteDescription) { entry.pendingCandidates.push(candidate); return; }
        await pc.addIceCandidate(candidate).catch(error => { if (!entry.ignoreOffer) throw error; });
      }
    } catch {
      // Negotiation errors are recovered by the next offer or ICE restart.
    }
  }

  startMeters() {
    try {
      this.audioContext ??= new AudioContext();
      this.audioContext.resume?.();
      if (this.stream) this.meter(this.meId, this.stream);
    } catch {}
    clearInterval(this.meterTimer);
    this.meterTimer = setInterval(() => {
      let changed = false;
      for (const [id, meter] of this.levels) {
        meter.analyser.getByteFrequencyData(meter.data);
        let sum = 0;
        for (const value of meter.data) sum += value;
        const speaking = sum / meter.data.length > 18 && !(id === this.meId && this.muted);
        if (speaking !== meter.speaking) { meter.speaking = speaking; changed = true; }
      }
      if (changed) this.onChange();
    }, 250);
  }

  meter(id, stream) {
    if (!this.audioContext) return;
    try {
      const source = this.audioContext.createMediaStreamSource(stream);
      const analyser = this.audioContext.createAnalyser();
      analyser.fftSize = 256;
      source.connect(analyser);
      this.levels.set(id, { analyser, data: new Uint8Array(analyser.frequencyBinCount), speaking: false });
    } catch {}
  }

  speaking(id) { return this.levels.get(id)?.speaking === true; }
}
