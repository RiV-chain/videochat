import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logging/logging.dart';

import '../utils/device_info.dart'
    if (dart.library.js) '../utils/device_info_web.dart';
import '../utils/websocket_loop.dart'
    if (dart.library.js) '../utils/websocket_web.dart';
import '../utils/rivutil.dart';
import '../types.dart';

enum SignalingState {
  ConnectionOpen,
  ConnectionClosed,
  ConnectionError,
}

enum CallState {
  CallStateNew,
  CallStateRinging,
  CallStateInvite,
  CallStateConnected,
  CallStateBye,
}

class PendingResponse {
  final int eventId;
  final Future<Map<String, dynamic>> future;
  PendingResponse({required this.eventId, required this.future});
}

enum VideoSource { Camera, Screen, AudioOnly }

class Session {
  Session({required this.sid, required this.peer});
  Node peer;
  String sid;
  RTCPeerConnection? pc;
  RTCDataChannel? dc;
  List<RTCIceCandidate> remoteCandidates = [];
  List<MediaStream> remoteStreams = <MediaStream>[];
  List<RTCRtpSender> senders = <RTCRtpSender>[];

  void startPinger(Future<bool> Function(String to) pingPeer,
      Function(Session session) bye) {
    if (pc != null) {
      Future.delayed(const Duration(seconds: 10), () async {
        if (pc != null) {
          if (!await pingPeer(peer.address)) {
            Logger("").warning(
                "Peer ${peer.address} disconnected. Closing connection");
            bye(this);
          } else {
            startPinger(pingPeer, bye);
          }
        }
      });
    }
  }
}

class AcceptResult {
  bool join;
  VideoSource source;
  AcceptResult(this.join, this.source);
}

class Signaling {
  static final log = Logger('Signaling');

  String? _host;
  Signaling() {
    riv = RivApiClient(
        endpoint: "http://${DeviceInfo.domain}:19019", signaling: this);
  }
  List<dynamic> _peers = [];
  int lastEventId = 0;
  Map<int, Completer<Map<String, dynamic>>> pendingResponse = {};
  JsonEncoder _encoder = JsonEncoder();
  JsonDecoder _decoder = JsonDecoder();
  String get _selfId => riv.selfNode.address;
  SimpleWebSocket? _socket;
  Map<String, Session> _sessions = {};
  MediaStream? _localStream;
  VideoSource? _videoSource;
  late RivApiClient riv;
  Function(SignalingState state)? onSignalingStateChange;
  Future<MediaStream?> Function(VideoSource source)? createStream;
  Future<AcceptResult?> Function(
          Session session, bool joinMode, VideoSource offeredSource)?
      showAcceptDialog;
  Function(Session session, CallState state)? onCallStateChange;
  Function(MediaStream? stream)? onLocalStream;
  Function(Session session, MediaStream stream)? onAddRemoteStream;
  Function(Session session, MediaStream stream)? onRemoveRemoteStream;
  Function(dynamic event)? onPeersUpdate;
  Function(Session session, RTCDataChannel dc, RTCDataChannelMessage data)?
      onDataChannelMessage;
  Function(Session session, RTCDataChannel dc)? onDataChannel;

  String get sdpSemantics => 'unified-plan';

  final Map<String, dynamic> _config = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ]
  };

  final Map<String, dynamic> _dcConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': false,
      'OfferToReceiveVideo': false,
    },
    'optional': [],
  };

  close() async {
    await _cleanSessions();
    _socket?.close();
  }

  checkOut() async {
    await _cleanSessions();
    onCallStateChange = null;
    onLocalStream = null;
    onAddRemoteStream = null;
    onRemoveRemoteStream = null;
    onPeersUpdate = null;
    onDataChannelMessage = null;
    onDataChannel = null;
    if (_selfId != _host) {
      _peers.where((peer) => peer['id'] != _selfId).forEach((peer) {
        _send(peer['id'], 'leave', _selfId);
      });
      _peers.removeWhere((peer) => peer['id'] != _selfId);
    }
  }

  void switchCamera() {
    if (_localStream != null) {
      if (_videoSource != VideoSource.Camera) {
        _sessions.values.forEach((sess) {
          sess.senders.forEach((sender) {
            if (sender.track!.kind == 'video') {
              sender.replaceTrack(_localStream!.getVideoTracks()[0]);
            }
          });
        });
        _videoSource = VideoSource.Camera;
        onLocalStream?.call(_localStream!);
      } else {
        Helper.switchCamera(_localStream!.getVideoTracks()[0]);
      }
    }
  }

  void switchScreenSharing(MediaStream stream) {
    if (_localStream != null && _videoSource != VideoSource.Screen) {
      _sessions.values.forEach((sess) {
        sess.senders.forEach((sender) {
          if (sender.track!.kind == 'video') {
            sender.replaceTrack(stream.getVideoTracks()[0]);
          }
        });
      });
      onLocalStream?.call(stream);
      _videoSource = VideoSource.Screen;
    }
  }

  void switchAudio() {
    if (_localStream != null) {
      _sessions.values.forEach((sess) {
        sess.senders.forEach((sender) {
          if (sender.track!.kind == 'video') {
            sender.replaceTrack(null);
          }
        });
      });
      onLocalStream?.call(_localStream!);
      _videoSource = VideoSource.AudioOnly;
    }
  }

  void muteMic(bool isMute) {
    if (_localStream != null) {
//      bool enabled = _localStream!.getAudioTracks()[0].enabled;
      _localStream!.getAudioTracks()[0].enabled = !isMute;
    }
  }

  static String makeSessionId(String ida, String idb) {
    return ida.compareTo(idb) > 0 ? "$ida-$idb" : "$idb-$ida";
  }

  void invite(String peerId, String media, VideoSource videoSource) async {
    await _createLocalStream(videoSource);
    var sessionId = makeSessionId(_selfId, peerId);
    Session session = await _createSession(
      null,
      peerId: peerId,
      sessionId: sessionId,
      media: media,
    );
    await _setSender(session);
    if (_localStream != null) {
      _sessions[sessionId] = session;
      _createOffer(session, media);
      onCallStateChange?.call(session, CallState.CallStateNew);
      onCallStateChange?.call(session, CallState.CallStateInvite);
    }
  }

  void _inviteJoin(VideoSource videoSource) async {
    _peers.where((peer) => peer['id'] != _selfId).forEach((peer) async {
      var sessionId = makeSessionId(_selfId, peer['id']);
      if (!_sessions.containsKey(sessionId)) {
        Session session = await _createSession(
          null,
          peerId: peer['id'],
          sessionId: sessionId,
          media: 'video',
        );
        await _setSender(session);
        if (_localStream != null) {
          _sessions[sessionId] = session;
          _createOffer(session, 'video');
          onCallStateChange?.call(session, CallState.CallStateNew);
          //onCallStateChange?.call(session, CallState.CallStateInvite);
        }
      }
    });
  }

  void bye(Session session) {
    log.finest("Bye ${session.peer.label}");
    _send(session.peer.address, 'bye', {
      'session_id': session.sid,
    });
    var sess = _sessions[session.sid];
    if (sess != null) {
      _closeSession(sess);
    }
  }

  void accept(String sessionId) {
    var session = _sessions[sessionId];
    if (session == null) {
      return;
    }
    _createAnswer(session, 'video');
  }

  void reject(String sessionId) {
    var session = _sessions[sessionId];
    if (session == null) {
      return;
    }
    bye(session);
  }

  List<dynamic> get peers => _peers;

  Future<bool> pingPeer(String to) async {
    var r = _makePendingResponse(to, 'ping', <String, dynamic>{});
    Future.delayed(const Duration(seconds: 1), () {
      var compl = pendingResponse.remove(r.eventId);
      if (compl != null) {
        compl.complete({'online': false});
      }
    });
    try {
      return (await r.future)['online'];
    } catch (e) {
      return false;
    }
  }

  Future<http.Response> httpGet(String address,
      {Map<String, String>? headers}) async {
    var r = await _makePendingResponse(null, 'httpget', {
      'address': address,
      'headers': headers,
    }).future;
    Map<String, String> respHeaders = r["headers"].map<String, String>(
        (key, value) => MapEntry<String, String>(key, value));
    return http.Response(r["body"], r["statusCode"], headers: respHeaders);
  }

  void onMessage(Map<String, dynamic> mapData) async {
    var data = mapData['data'];
    logMessage() {
      var d = _decoder.convert(_encoder.convert(mapData));
      try {
        (d['data'] as Map).remove('description');
      } catch (e) {}
      log.fine("onMessage: $d");
    }

    switch (mapData['type']) {
      case 'new':
        {
          logMessage();
          if (_peers.where((peer) => peer['id'] == data['id']).isEmpty) {
            _peers.add(data);
          }
          _peers.where((peer) => peer['id'] != _selfId).forEach((peer) {
            _send(peer['id'], 'peers', _peers);
          });
          if (onPeersUpdate != null) {
            onPeersUpdate?.call(null);
          }
        }
        break;
      case 'peers':
        {
          logMessage();
          _peers = data;
          if (onPeersUpdate != null) {
            onPeersUpdate?.call(null);
          }
        }
        break;
      case 'offer':
        {
          logMessage();
          var peerId = mapData['from'];
          var description = data['description'];
          var media = data['media'];
          var sessionId = data['session_id'];
          VideoSource offeredVideoSource;
          try {
            offeredVideoSource =
                VideoSource.values.byName(data['video_source']);
          } catch (e) {
            offeredVideoSource = VideoSource.AudioOnly;
            log.severe(e);
          }
          var session = _sessions[sessionId];
          var newSession = await _createSession(session,
              peerId: peerId, sessionId: sessionId, media: media);
          _sessions[sessionId] = newSession;
          await newSession.pc?.setRemoteDescription(
              RTCSessionDescription(description['sdp'], description['type']));
          if (newSession.remoteCandidates.length > 0) {
            newSession.remoteCandidates.forEach((candidate) async {
              await newSession.pc?.addCandidate(candidate);
            });
            newSession.remoteCandidates.clear();
          }
          AcceptResult? acceptRes;
          if (_sessions.length == 1 || _host == _selfId) {
            acceptRes = showAcceptDialog != null
                ? await showAcceptDialog!(
                    newSession, _sessions.length > 1, offeredVideoSource)
                : null;
            if (acceptRes != null && _localStream == null) {
              await _createLocalStream(acceptRes.source);
            }
          }
          await _setSender(newSession);
          if (_localStream != null) {
            accept(newSession.sid);
            onCallStateChange?.call(newSession, CallState.CallStateNew);
            onCallStateChange?.call(newSession, CallState.CallStateRinging);
          } else {
            reject(newSession.sid);
          }
        }
        break;
      case 'answer':
        {
          logMessage();
          var description = data['description'];
          var sessionId = data['session_id'];
          var session = _sessions[sessionId];
          session?.pc?.setRemoteDescription(
              RTCSessionDescription(description['sdp'], description['type']));
          onCallStateChange?.call(session!, CallState.CallStateConnected);
          _inviteJoin(_videoSource!);
        }
        break;
      case 'candidate':
        {
//          var peerId = mapData['from'];
          var candidateMap = data['candidate'];
          var sessionId = data['session_id'];
          var session = _sessions[sessionId];

          if (session != null) {
            RTCIceCandidate candidate = RTCIceCandidate(
                candidateMap['candidate'],
                candidateMap['sdpMid'],
                candidateMap['sdpMLineIndex']);
            if (session.pc != null) {
              await session.pc?.addCandidate(candidate);
            } else {
              log.fine("Session isn't initialized");
              session.remoteCandidates.add(candidate);
            }
          } else {
            log.fine("Candidate without session: $data");
            //   _sessions[sessionId] = Session(pid: peerId, sid: sessionId)
            //     ..remoteCandidates.add(candidate);
          }
        }
        break;
      case 'leave': //leave host's room
        {
          logMessage();
          var peerId = data as String;
          _closeSessionByPeerId(peerId);
          _peers.removeWhere((peer) => peer['id'] == peerId);
        }
        break;
      case 'bye': //hangup peer's connection
        {
          logMessage();
          var sessionId = data['session_id'];
          log.info('bye: ' + sessionId);
          var session = _sessions.remove(sessionId);
          if (session != null) {
            _closeSession(session);
          }
        }
        break;
      case 'ping':
        _send(mapData['from'], 'success', {'online': true},
            eventId: mapData['eventId']);
        break;
      case 'error':
//        log.warning('ERROR: $mapData');
        var eventId = mapData['eventId'];
        if (eventId != null) {
          var handler = pendingResponse.remove(eventId);
          if (handler != null) {
            handler.completeError(data);
          }
        }
        break;
      case 'success':
        var eventId = mapData['eventId'];
        if (eventId != null) {
          var handler = pendingResponse.remove(eventId);
          try {
            if (handler != null) {
              handler.complete(data);
            }
          } catch (e) {
            log.severe("$e: $mapData");
          }
        }
        break;
      default:
        break;
    }
  }

  Future<void> connect() async {
    var url = DeviceInfo.signalingLocation;
    _socket = SimpleWebSocket(url);

    log.info('connect to $url');

    _socket?.onOpen = () async {
//      print('onOpen');
      await riv.connect();
      onSignalingStateChange?.call(SignalingState.ConnectionOpen);
      if (_peers.isEmpty) {
        _peers.add({
          'name': riv.selfNode.label,
          'id': _selfId,
          'user_agent': DeviceInfo.userAgent,
        });
      }
    };

    _socket?.onMessage = (message) {
      //if (message != '{}') print('Received data: ' + message);
      onMessage(_decoder.convert(message));
    };

    _socket?.onClose = (int? code, String? reason) {
      log.info('Closed by server [$code => $reason]!');
      onSignalingStateChange?.call(SignalingState.ConnectionClosed);
    };

    await _socket?.connect();
  }

  Future<void> checkIn(host) async {
    this._host = host;
    _send(host, 'new', {
      'name': riv.selfNode.label,
      'id': _selfId,
      'user_agent': DeviceInfo.userAgent,
    });
    onLocalStream?.call(_localStream);
    log.fine("on checkIn");

//    _localRenderer.srcObject = session.remoteStream;
  }

  _setSender(Session session) async {
    if (_localStream != null) {
      switch (sdpSemantics) {
        case 'plan-b':
          await session.pc!.addStream(_localStream!);
          break;
        case 'unified-plan':
          _localStream!.getTracks().forEach((track) async {
            session.senders
                .add(await session.pc!.addTrack(track, _localStream!));
            log.fine("Added sender for ${session.peer.address}");
          });
          break;
      }
    } else {
      log.fine("Sender doesn't added");
    }
  }

  _createLocalStream(VideoSource vs) async {
    if (createStream != null) {
      _localStream = await createStream!(vs);
      onLocalStream?.call(_localStream);
      if (_localStream != null) {
        _videoSource = vs;
      }
    }
  }

  Future<Session> _createSession(
    Session? session, {
    required String peerId,
    required String sessionId,
    required String media,
  }) async {
    //TODO forward actual node
    var node = Node(address: peerId, key: "");
    var newSession = session ?? Session(sid: sessionId, peer: node);
    RTCPeerConnection pc = await createPeerConnection({
      ...{'sdpSemantics': sdpSemantics}
    }, _config);
    if (media != 'data') {
      switch (sdpSemantics) {
        case 'plan-b':
          pc.onAddStream = (MediaStream stream) {
            newSession.remoteStreams.add(stream);
            onAddRemoteStream?.call(newSession, stream);
            log.fine("on onTrack1");
          };
          break;
        case 'unified-plan':
          // Unified-Plan
          pc.onTrack = (event) {
            if (event.track.kind == 'video') {
              newSession.remoteStreams.add(event.streams[0]);
              onAddRemoteStream?.call(newSession, event.streams[0]);
              log.fine("on onTrack2 from ${newSession.peer.address}");
            }
          };
          break;
      }
    }

    pc.onIceCandidate = (candidate) async {
      // This delay is needed to allow enough time to try an ICE candidate
      // before skipping to the next one. 1 second is just an heuristic value
      // and should be thoroughly tested in your own environment.
      await Future.delayed(
          const Duration(seconds: 1),
          () => _send(peerId, 'candidate', {
                'candidate': candidate.toMap(),
                'session_id': sessionId,
              }));
    };

    pc.onIceConnectionState = (state) {};

    pc.onRemoveStream = (stream) {
      onRemoveRemoteStream?.call(newSession, stream);
      newSession.remoteStreams.removeWhere((it) {
        return (it.id == stream.id);
      });
    };

    pc.onDataChannel = (channel) {
      _addDataChannel(newSession, channel);
    };

    newSession.pc = pc;
    newSession.startPinger(pingPeer, bye);
    return newSession;
  }

  void _addDataChannel(Session session, RTCDataChannel channel) {
    channel.onDataChannelState = (e) {};
    channel.onMessage = (RTCDataChannelMessage data) {
      onDataChannelMessage?.call(session, channel, data);
    };
    session.dc = channel;
    onDataChannel?.call(session, channel);
  }

  // Future<void> _createDataChannel(Session session,
  //     {label = 'fileTransfer'}) async {
  //   RTCDataChannelInit dataChannelDict = RTCDataChannelInit()
  //     ..maxRetransmits = 30;
  //   RTCDataChannel channel =
  //       await session.pc!.createDataChannel(label, dataChannelDict);
  //   _addDataChannel(session, channel);
  // }

  Future<void> _createOffer(Session session, String media) async {
    try {
      RTCSessionDescription s =
          await session.pc!.createOffer(media == 'data' ? _dcConstraints : {});
      await session.pc!.setLocalDescription(_fixSdp(s));
      log.fine("sent offer to: ${session.peer.address}");
      _send(session.peer.address, 'offer', {
        'description': {'sdp': s.sdp, 'type': s.type},
        'session_id': session.sid,
        'media': media,
        'video_source': _videoSource!.name,
      });
    } catch (e) {
      log.severe(e.toString());
    }
  }

  RTCSessionDescription _fixSdp(RTCSessionDescription s) {
    var sdp = s.sdp;
    s.sdp =
        sdp!.replaceAll('profile-level-id=640c1f', 'profile-level-id=42e032');
    return s;
  }

  Future<void> _createAnswer(Session session, String media) async {
    try {
      RTCSessionDescription s =
          await session.pc!.createAnswer(media == 'data' ? _dcConstraints : {});
      await session.pc!.setLocalDescription(_fixSdp(s));
      log.fine("sent answer to: ${session.peer.address}");
      _send(session.peer.address, 'answer', {
        'description': {'sdp': s.sdp, 'type': s.type},
        'session_id': session.sid,
      });
    } catch (e) {
      log.severe(e.toString());
    }
  }

  PendingResponse _makePendingResponse(to, event, data) {
    var completer = Completer<Map<String, dynamic>>();
    var result =
        PendingResponse(eventId: lastEventId++, future: completer.future);
    pendingResponse[result.eventId] = completer;
    _send(to, event, data, eventId: result.eventId);
    return result;
  }

  _send(to, event, data, {eventId}) {
    Map<String, dynamic> request = {};
    if (eventId != null) {
      request["eventId"] = eventId;
    }
    request["type"] = event;
    request["data"] = data;
    if (to != null) {
      request["to"] = to;
      request["from"] = _selfId;
    }
    if (to != null && to == request["from"]) {
      onMessage(request);
    } else {
      _socket?.send(_encoder.convert(request));
    }
  }

  Future<void> _cleanSessions() async {
    if (_localStream != null) {
      _localStream!.getTracks().forEach((element) async {
        await element.stop();
      });
      await _localStream!.dispose();
      _localStream = null;
    }
    _videoSource = null;
    _sessions.forEach((key, Session sess) async {
      await sess.pc?.close();
      sess.pc = null;
      await sess.dc?.close();
    });
    _sessions.clear();
  }

  void _closeSessionByPeerId(String peerId) {
    var session;
    _sessions.removeWhere((String key, Session sess) {
      var ids = key.split('-');
      bool result = peerId == ids[0] || peerId == ids[1];
      if (result) {
        session = sess;
      }
      return result;
    });
    if (session != null) {
      _closeSession(session);
    }
  }

  Future<void> _closeSession(Session session) async {
    _sessions.remove(session.sid);
    await session.pc?.close();
    session.pc = null;
    await session.dc?.close();
    if (_sessions.isEmpty) {
      _localStream?.getTracks().forEach((element) async {
        await element.stop();
      });
      await _localStream?.dispose();
      _localStream = null;
      _videoSource = null;
    }
    onCallStateChange?.call(session, CallState.CallStateBye);
  }
}
