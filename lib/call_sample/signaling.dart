import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../utils/device_info.dart'
    if (dart.library.js) '../utils/device_info_web.dart';
import '../utils/websocket_loop.dart'
    if (dart.library.js) '../utils/websocket_web.dart';
import '../utils/rivutil.dart';

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
  Session({required this.sid, required this.pid, this.videoSource});
  String pid;
  String sid;
  VideoSource? videoSource;
  RTCPeerConnection? pc;
  RTCDataChannel? dc;
}

class Signaling {
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
  List<MediaStream> _remoteStreams = <MediaStream>[];
  List<RTCRtpSender> _senders = <RTCRtpSender>[];
  VideoSource _videoSource = VideoSource.Camera;
  late RivApiClient riv;
  Function(SignalingState state)? onSignalingStateChange;
  Future<MediaStream?> Function(VideoSource source)? createStream;
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
    createStream = null;
    onCallStateChange = null;
    onLocalStream = null;
    onAddRemoteStream = null;
    onRemoveRemoteStream = null;
    onPeersUpdate = null;
    onDataChannelMessage = null;
    onDataChannel = null;
    _peers.where((peer) => peer['id'] != _selfId).forEach((peer) {
      _send(peer['id'], 'leave', _selfId);
    });
    _peers.removeWhere((peer) => peer['id'] != _selfId);
  }

  void switchCamera() {
    if (_localStream != null) {
      if (_videoSource != VideoSource.Camera) {
        _senders.forEach((sender) {
          if (sender.track!.kind == 'video') {
            sender.replaceTrack(_localStream!.getVideoTracks()[0]);
          }
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
      _senders.forEach((sender) {
        if (sender.track!.kind == 'video') {
          sender.replaceTrack(stream.getVideoTracks()[0]);
        }
      });
      onLocalStream?.call(stream);
      _videoSource = VideoSource.Screen;
    }
  }

  void switchAudio() {
    if (_localStream != null) {
      _senders.forEach((sender) {
        if (sender.track!.kind == 'video') {
          sender.replaceTrack(null);
        }
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

  void invite(String peerId, String media, VideoSource videoSource) async {
    var sessionId = _selfId + '-' + peerId;
    Session session = await _createSession(
      null,
      peerId: peerId,
      sessionId: sessionId,
      media: media,
      videoSource: videoSource,
    );
    await _createLocalStream(session);
    if (_localStream != null) {
      _sessions[sessionId] = session;
      _createOffer(session, media);
      onCallStateChange?.call(session, CallState.CallStateNew);
      onCallStateChange?.call(session, CallState.CallStateInvite);
    }
  }

  void bye(Session session) {
    _send(session.pid, 'bye', {
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
    return (await r.future)['online'];
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

    switch (mapData['type']) {
      case 'new':
        {
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
          _peers = data;
          if (onPeersUpdate != null) {
            onPeersUpdate?.call(null);
          }
        }
        break;
      case 'offer':
        {
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
            print(e);
          }
          var session = _sessions[sessionId];
          var newSession = await _createSession(session,
              peerId: peerId,
              sessionId: sessionId,
              media: media,
              videoSource: offeredVideoSource);
          _sessions[sessionId] = newSession;
          await newSession.pc?.setRemoteDescription(
              RTCSessionDescription(description['sdp'], description['type']));
          onCallStateChange?.call(newSession, CallState.CallStateNew);
          await onCallStateChange?.call(newSession, CallState.CallStateRinging);
          if (onCallStateChange != null && newSession.videoSource != null) {
            await _createLocalStream(newSession);
            accept(newSession.sid);
          } else {
            reject(newSession.sid);
          }
        }
        break;
      case 'answer':
        {
          var description = data['description'];
          var sessionId = data['session_id'];
          var session = _sessions[sessionId];
          session?.pc?.setRemoteDescription(
              RTCSessionDescription(description['sdp'], description['type']));
          onCallStateChange?.call(session!, CallState.CallStateConnected);
        }
        break;
      case 'leave': //leave host's room
        {
          var peerId = data as String;
          _closeSessionByPeerId(peerId);
          _peers.removeWhere((peer) => peer['id'] == peerId);
        }
        break;
      case 'bye': //hangup correspondent's connection
        {
          var sessionId = data['session_id'];
          print('bye: ' + sessionId);
          var session = _sessions.remove(sessionId);
          if (session != null) {
            onCallStateChange?.call(session, CallState.CallStateBye);
            _closeSession(session);
          }
        }
        break;
      case 'ping':
        _send(mapData['from'], 'success', {'online': true},
            eventId: mapData['eventId']);
        break;
      case 'error':
        print('ERROR: $mapData');
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
            print("$e: $mapData");
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

    print('connect to $url');

    _socket?.onOpen = () async {
//      print('onOpen');
      await riv.connect();
      onSignalingStateChange?.call(SignalingState.ConnectionOpen);
      if (_peers.isEmpty) {
        _peers.add({
          'name': DeviceInfo.label,
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
      print('Closed by server [$code => $reason]!');
      onSignalingStateChange?.call(SignalingState.ConnectionClosed);
    };

    await _socket?.connect();
  }

  Future<void> checkIn(host) async {
    _send(host, 'new', {
      'name': DeviceInfo.label,
      'id': _selfId,
      'user_agent': DeviceInfo.userAgent,
    });
  }

  _createLocalStream(Session session) async {
    if (createStream != null) {
      _localStream = await createStream!(session.videoSource!);
      onLocalStream?.call(_localStream);
      if (_localStream != null) {
        switch (sdpSemantics) {
          case 'plan-b':
            await session.pc!.addStream(_localStream!);
            break;
          case 'unified-plan':
            _localStream!.getTracks().forEach((track) async {
              _senders.add(await session.pc!.addTrack(track, _localStream!));
            });
            break;
        }
      }
    }
  }

  Future<Session> _createSession(
    Session? session, {
    required String peerId,
    required String sessionId,
    required String media,
    required VideoSource videoSource,
  }) async {
    var newSession = session ??
        Session(sid: sessionId, pid: peerId, videoSource: videoSource);
    RTCPeerConnection pc = await createPeerConnection({
      ...{'sdpSemantics': sdpSemantics}
    }, _config);
    if (media != 'data') {
      switch (sdpSemantics) {
        case 'plan-b':
          pc.onAddStream = (MediaStream stream) {
            onAddRemoteStream?.call(newSession, stream);
            _remoteStreams.add(stream);
          };
          break;
        case 'unified-plan':
          // Unified-Plan
          pc.onTrack = (event) {
            if (event.track.kind == 'video') {
              onAddRemoteStream?.call(newSession, event.streams[0]);
            }
          };
          break;
      }
    }
    pc.onIceCandidate = (candidate) async {};

    pc.onIceConnectionState = (state) {};

    pc.onRemoveStream = (stream) {
      onRemoveRemoteStream?.call(newSession, stream);
      _remoteStreams.removeWhere((it) {
        return (it.id == stream.id);
      });
    };

    pc.onDataChannel = (channel) {
      _addDataChannel(newSession, channel);
    };

    newSession.pc = pc;
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
      _send(session.pid, 'offer', {
        'description': {'sdp': s.sdp, 'type': s.type},
        'session_id': session.sid,
        'media': media,
        'video_source': session.videoSource!.name
      });
    } catch (e) {
      print(e.toString());
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
      _send(session.pid, 'answer', {
        'description': {'sdp': s.sdp, 'type': s.type},
        'session_id': session.sid,
      });
    } catch (e) {
      print(e.toString());
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
    _sessions.forEach((key, Session sess) async {
      await sess.pc?.close();
      await sess.dc?.close();
    });
    _sessions.clear();
  }

  void _closeSessionByPeerId(String peerId) {
    var session;
    _sessions.removeWhere((String key, Session sess) {
      var ids = key.split('-');
      session = sess;
      return peerId == ids[0] || peerId == ids[1];
    });
    if (session != null) {
      _closeSession(session);
      onCallStateChange?.call(session, CallState.CallStateBye);
    }
  }

  Future<void> _closeSession(Session session) async {
    _localStream?.getTracks().forEach((element) async {
      await element.stop();
    });
    await _localStream?.dispose();
    _localStream = null;

    await session.pc?.close();
    await session.dc?.close();
    _senders.clear();
    _videoSource = VideoSource.Camera;
  }
}
