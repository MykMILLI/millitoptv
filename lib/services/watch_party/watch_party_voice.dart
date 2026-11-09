import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../app_log.dart';
import 'watch_party_service.dart';

class _Peer {
  final RTCPeerConnection pc;
  final bool polite;
  bool makingOffer = false;
  bool ignoreOffer = false;
  bool remoteSet = false;
  final List<RTCIceCandidate> pending = [];
  _Peer(this.pc, this.polite);
}

/// Voice chat over a WebRTC audio mesh. Wire-compatible with the browser
/// join page (`watch-party-web/voice.js`): same perfect-negotiation roles
/// (the participant with the larger id is polite) and payload shapes.
class WatchPartyVoice extends ChangeNotifier {
  WatchPartyVoice(this._service);
  final WatchPartyService _service;

  bool active = false;
  bool muted = false;
  bool listenOnly = false;
  String? notice;
  MediaStream? _stream;
  List<Map<String, dynamic>> _iceServers = const [];
  final Map<String, _Peer> _peers = {};
  bool _joining = false;

  int get connectedPeers => _peers.length;

  Future<void> join() async {
    if (active || _joining || !_service.active) return;
    _joining = true;
    try {
      final ice = await _service.call('GET', '/api/watch/ice');
      final servers = ice['iceServers'];
      _iceServers = [
        if (servers is List)
          for (final item in servers)
            if (item is Map) item.cast<String, dynamic>(),
      ];
      try {
        _stream = await navigator.mediaDevices.getUserMedia({
          'audio': {
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
          },
          'video': false,
        });
        listenOnly = false;
        notice = null;
      } catch (error) {
        _stream = null;
        listenOnly = true;
        notice = 'No microphone is available, so you joined listen-only.';
      }
      active = true;
      muted = false;
      await _announce();
      sync(_service.people);
    } catch (error) {
      notice = 'Voice chat could not start: $error';
      AppLog.warn(LogCategory.sync, 'Watch party voice failed', error: error);
    } finally {
      _joining = false;
      notifyListeners();
    }
  }

  Future<void> _announce() => _service.call('POST', '/api/watch/voice', {
    'active': active,
    'muted': muted,
    'listenOnly': listenOnly,
  });

  Future<void> setMuted(bool value) async {
    muted = value;
    for (final track
        in _stream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = !value;
    }
    notifyListeners();
    try {
      await _announce();
    } catch (_) {}
  }

  Future<void> leave({bool announce = true}) async {
    if (!active) return;
    active = false;
    for (final id in _peers.keys.toList()) {
      if (announce) {
        unawaited(_send(id, 'hangup', const {}).catchError((_) {}));
      }
      await _close(id);
    }
    for (final track in _stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _stream?.dispose();
    _stream = null;
    if (announce && _service.active) {
      try {
        await _service.call('POST', '/api/watch/voice', {'active': false});
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Connects to everyone else who is online and in voice.
  void sync(List<WatchPartyPerson> people) {
    if (!active) return;
    final me = _service.meId;
    final wanted = {
      for (final p in people)
        if (p.id != me && p.online && p.inVoice) p.id,
    };
    for (final id in wanted) {
      if (!_peers.containsKey(id)) unawaited(_peer(id));
    }
    for (final id in _peers.keys.toList()) {
      if (!wanted.contains(id)) unawaited(_close(id));
    }
  }

  final Map<String, Future<_Peer>> _creating = {};

  Future<_Peer> _peer(String id) {
    final existing = _peers[id];
    if (existing != null) return Future.value(existing);
    return _creating[id] ??= _createPeer(
      id,
    ).whenComplete(() => _creating.remove(id));
  }

  Future<_Peer> _createPeer(String id) async {
    final pc = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
    });
    final me = _service.meId ?? '';
    final peer = _Peer(pc, me.compareTo(id) > 0);
    _peers[id] = peer;
    pc.onRenegotiationNeeded = () => unawaited(_negotiate(id, peer));
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      unawaited(
        _send(id, 'candidate', {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        }).catchError((_) {}),
      );
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(pc.restartIce());
      }
      notifyListeners();
    };
    // Remote audio plays automatically on native platforms once the track
    // arrives; no renderer is needed for audio-only streams.
    final stream = _stream;
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        await pc.addTrack(track, stream);
      }
    } else {
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
    }
    notifyListeners();
    return peer;
  }

  Future<void> _negotiate(String id, _Peer peer) async {
    try {
      peer.makingOffer = true;
      final offer = await peer.pc.createOffer();
      if (peer.pc.signalingState != RTCSignalingState.RTCSignalingStateStable) {
        return;
      }
      await peer.pc.setLocalDescription(offer);
      await _send(id, 'description', {'type': offer.type, 'sdp': offer.sdp});
    } catch (_) {
      // A later negotiation retries.
    } finally {
      peer.makingOffer = false;
    }
  }

  Future<void> _close(String id) async {
    final peer = _peers.remove(id);
    if (peer == null) return;
    try {
      await peer.pc.close();
      await peer.pc.dispose();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _send(String to, String kind, Map<String, dynamic> payload) =>
      _service.call('POST', '/api/watch/signal', {
        'to': to,
        'kind': kind,
        'payload': payload,
      });

  Future<void> handleSignal(Map<String, dynamic> data) async {
    final from = data['from']?.toString();
    final kind = data['kind']?.toString();
    final payload = data['payload'];
    if (from == null || from == _service.meId) return;
    if (kind == 'hangup') {
      await _close(from);
      return;
    }
    if (!active || payload is! Map) return;
    final peer = await _peer(from);
    final pc = peer.pc;
    try {
      if (kind == 'description') {
        final type = payload['type']?.toString();
        final sdp = payload['sdp']?.toString();
        if (type == null || sdp == null) return;
        final stable =
            pc.signalingState == RTCSignalingState.RTCSignalingStateStable ||
            pc.signalingState == null;
        final collision = type == 'offer' && (peer.makingOffer || !stable);
        peer.ignoreOffer = !peer.polite && collision;
        if (peer.ignoreOffer) return;
        if (collision &&
            pc.signalingState ==
                RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          // Polite peer: roll back our own offer and accept theirs.
          await pc.setLocalDescription(RTCSessionDescription('', 'rollback'));
        }
        await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
        peer.remoteSet = true;
        for (final candidate in List.of(peer.pending)) {
          await pc.addCandidate(candidate).catchError((_) {});
        }
        peer.pending.clear();
        if (type == 'offer') {
          final answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);
          await _send(from, 'description', {
            'type': answer.type,
            'sdp': answer.sdp,
          });
        }
      } else if (kind == 'candidate') {
        final candidate = RTCIceCandidate(
          payload['candidate']?.toString(),
          payload['sdpMid']?.toString(),
          (payload['sdpMLineIndex'] as num?)?.toInt(),
        );
        if (!peer.remoteSet) {
          peer.pending.add(candidate);
          return;
        }
        await pc.addCandidate(candidate);
      }
    } catch (error) {
      if (!peer.ignoreOffer) {
        AppLog.warn(LogCategory.sync, 'Voice negotiation error', error: error);
      }
    }
  }
}
