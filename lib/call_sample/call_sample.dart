import 'dart:core';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../widgets/screen_select_dialog.dart';
import '../utils/stats_report.dart';
import '../call_sample/signaling.dart';
import '../types.dart';
import '../common.dart';

typedef Peer = Map<String, dynamic>;

class SessionUi {
  static final log = Logger('SessionUi');
  static BuildContext? context;

  static Future<AcceptResult?> showAcceptDialog(
      Session _session, bool joinMode, VideoSource offeredSource) {
    return showDialog<AcceptResult?>(
      context: context!,
      builder: (context) {
        return joinMode
            ? AlertDialog(
                title: Text("Incoming call"),
                content: SizedBox(
                  height: 100.0,
                  child: Text(
                      "${_session.peer.label} invites to a video meeting. He offers his ${offeredSource.toString().split('.').last} source. Accept join to the conference?"),
                ),
                actions: <Widget>[
                  MaterialButton(
                    child: const Text(
                      'Reject',
                      style: TextStyle(color: Colors.red),
                    ),
                    onPressed: () => Navigator.of(context).pop(null),
                  ),
                  MaterialButton(
                    child: const Text(
                      'Accept',
                      style: TextStyle(color: Colors.green),
                    ),
                    onPressed: () => Navigator.of(context)
                        .pop(AcceptResult(true, offeredSource)),
                  ),
                ],
              )
            : AlertDialog(
                title: Text("Incoming call"),
                content: Text(
                    "${_session.peer.label} invites to a video meeting. He offers his ${offeredSource.toString().split('.').last} source. Accept it?"),
                actions: <Widget>[
                  MaterialButton(
                    child: const Text(
                      'Reject',
                      style: TextStyle(color: Colors.red),
                    ),
                    onPressed: () => Navigator.of(context).pop(null),
                  ),
                  MaterialButton(
                    child: const Text(
                      'Camera',
                      style: TextStyle(color: Colors.green),
                    ),
                    onPressed: () => Navigator.of(context)
                        .pop(AcceptResult(false, VideoSource.Camera)),
                  ),
                  MaterialButton(
                    child: const Text(
                      'Screen',
                      style: TextStyle(color: Colors.green),
                    ),
                    onPressed: () => Navigator.of(context)
                        .pop(AcceptResult(false, VideoSource.Screen)),
                  ),
                  MaterialButton(
                    child: const Text(
                      'Audio',
                      style: TextStyle(color: Colors.green),
                    ),
                    onPressed: () => Navigator.of(context)
                        .pop(AcceptResult(false, VideoSource.AudioOnly)),
                  ),
                ],
              );
      },
    );
  }

  static Future<MediaStream?> createStream(VideoSource videoSource) async {
    MediaStream? stream;
    try {
      switch (videoSource) {
        case VideoSource.Screen:
          if (WebRTC.platformIsDesktop) {
            final source = await showDialog<DesktopCapturerSource>(
              context: context!,
              builder: (context) => ScreenSelectDialog(),
            );
            stream =
                await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
              'video': source == null
                  ? true
                  : {
                      'deviceId': {'exact': source.id},
                      'mandatory': {'frameRate': 30.0}
                    }
            });
          } else {
            stream = await navigator.mediaDevices
                .getDisplayMedia({'video': true, 'audio': false});
          }
          break;
        case VideoSource.Camera:
          stream = await navigator.mediaDevices
              .getUserMedia({'video': true, 'audio': true});
          break;
        case VideoSource.AudioOnly:
          stream = await navigator.mediaDevices
              .getUserMedia({'video': false, 'audio': true});
          break;
      }
    } catch (e) {
      log.severe("Get media error: " + e.toString());
    }
    return stream;
  }
}

class UiSession {
  static final log = Logger('_UiSession');
  Session session;
  RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  StatsReportUtil stats = StatsReportUtil();
  UiSession._(this.session) {
    // Timer.periodic(
    //     const Duration(milliseconds: StatsReportUtil.STATS_INTERVAL_MS),
    //     (timer) async {
    //   try {
    //     stats.updateStatsReport(await session.pc!.getStats());
    //     setState(() {});
    //   } catch (e) {
    //     log.fine('Stats stop $e');
    //     timer.cancel();
    //   }
    // });
  }

  static Future<UiSession> create(Session session) async {
    var res = UiSession._(session);
    await res.remoteRenderer.initialize();
    return res;
  }
}

class CallSample extends StatefulWidget {
  static String tag = 'call_sample';
  final Node hostNode;
  final Session? session;
  CallSample({required this.hostNode, this.session});

  @override
  _CallSampleState createState() => _CallSampleState(session);
}

class _CallSampleState extends State<CallSample> {
  static final log = Logger('_CallSampleState');
  String get _selfId => signaling.riv.selfNode.address;
  RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  bool _isShowStats = false;
  List<UiSession> uiSessions = [];
  bool _inCalling;
  bool _isMute = false;
  //DesktopCapturerSource? selected_source_;
  bool _waitAccept = false;

  // ignore: unused_element
  _CallSampleState(Session? session) : _inCalling = session != null {
    if (session != null) {
      () async {
        uiSessions.add(await UiSession.create(session));
        if (session.remoteStreams.isNotEmpty) {
          uiSessions.last.remoteRenderer.srcObject =
              session.remoteStreams.first;
          log.fine("on addUISession ${session.remoteStreams.first}");
        }
      }();
    }
  }

  @override
  initState() {
    super.initState();
    _connect(context);
  }

  @override
  deactivate() {
    signaling.checkOut();
//    signaling.close();
    _localRenderer.dispose();
//    _remoteRenderer.dispose();
    super.deactivate();
  }

  void _connect(BuildContext context) async {
    await _localRenderer.initialize();
    SessionUi.context = context;

    signaling.onCallStateChange = (Session session, CallState state) async {
      switch (state) {
        case CallState.CallStateNew:
          uiSessions.add(await UiSession.create(session));
          if (session.remoteStreams.isNotEmpty) {
            signaling.onAddRemoteStream
                ?.call(session, session.remoteStreams.first);
          }
          setState(() {});
          break;
        case CallState.CallStateRinging:
//          if (session.videoSource != null) {
          setState(() {
            _inCalling = true;
          });
//          }
          break;
        case CallState.CallStateBye:
          uiSessions
              .removeWhere((element) => element.session.peer == session.peer);
          if (uiSessions.isEmpty) {
            _localRenderer.srcObject = null;
            _inCalling = false;
          }
          if (_waitAccept) {
            log.info('peer reject');
            _waitAccept = false;
            if (uiSessions.isEmpty) {
              Navigator.of(context).pop(false);
            }
          }
          setState(() {});
          break;
        case CallState.CallStateInvite:
          _waitAccept = true;
          _showInviteDialog(session);
          break;
        case CallState.CallStateConnected:
          if (_waitAccept) {
            _waitAccept = false;
            Navigator.of(context).pop(false);
          }
          setState(() {
            _inCalling = true;
          });

          break;
      }
    };

    signaling.onPeersUpdate = ((event) {
      try {
        setState(() {});
      } catch (e) {
        log.severe(e.toString());
      }
    });

    signaling.onLocalStream = ((stream) {
      _localRenderer.srcObject = stream;
      setState(() {});
    });

    signaling.onAddRemoteStream = ((session, stream) {
      var sess =
          uiSessions.where((element) => element.session.peer == session.peer);
      if (sess.isNotEmpty) {
        sess.first.remoteRenderer.srcObject = stream;
        setState(() {});
      }
    });

    signaling.onRemoveRemoteStream = ((session, stream) {
      var sess =
          uiSessions.where((element) => element.session.peer == session.peer);
      if (sess.isNotEmpty) {
        sess.first.remoteRenderer.srcObject = null;
      }
    });
    signaling.checkIn(widget.hostNode.address);
  }

  Future<bool?> _showInviteDialog(Session session) {
    return showDialog<bool?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Outgoing call"),
          content: Text("The invite sent to " +
              session.peer.label +
              ". Waiting for accept..."),
          actions: <Widget>[
            TextButton(
              child: Text("cancel"),
              onPressed: () {
                Navigator.of(context).pop(false);
                _hangUp();
              },
            ),
          ],
        );
      },
    );
  }

  _invitePeer(
      BuildContext context, String peerId, VideoSource videoSource) async {
    if (peerId != _selfId) {
      signaling.invite(peerId, 'video', videoSource);
    }
  }

  _hangUp() {
    while (uiSessions.isNotEmpty) {
      var sess = uiSessions.first.session;
      signaling.bye(sess);
      uiSessions.removeWhere((element) => element.session.peer == sess.peer);
    }
  }

  _switchCamera() {
    signaling.switchCamera();
  }

  Future<void> switchToScreenSharing(BuildContext context) async {
    MediaStream? screenStream =
        await SessionUi.createStream(VideoSource.Screen /*, context*/);
    if (screenStream != null) signaling.switchScreenSharing(screenStream);
  }

  _muteMic() {
    signaling.muteMic(_isMute);
  }

  _buildRow(context, peer) {
    var self = _selfId == peer['id'];
    var owner = widget.hostNode.address == peer['id'];
    return ListBody(children: <Widget>[
      ListTile(
        title: Text('${peer['name']}, ID: ${peer['id']}' +
            (self ? ' [Your self]' : '') +
            (owner ? ' [Room owner]' : '')),
        onTap: null,
        trailing: SizedBox(
            width: 144.0,
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: !(owner && !self)
                    ? <Widget>[]
                    : <Widget>[
                        IconButton(
                          icon: Icon(Icons.videocam, color: Colors.black),
                          onPressed: () => _invitePeer(
                              context, peer['id'], VideoSource.Camera),
                          tooltip: 'Video calling',
                        ),
                        IconButton(
                          icon: Icon(Icons.screen_share, color: Colors.black),
                          onPressed: () => _invitePeer(
                              context, peer['id'], VideoSource.Screen),
                          tooltip: 'Screen sharing',
                        ),
                        IconButton(
                          icon: Icon(Icons.headphones, color: Colors.black),
                          onPressed: () => _invitePeer(
                              context, peer['id'], VideoSource.AudioOnly),
                          tooltip: 'Audio calling',
                        ),
                      ])),
        subtitle: Text('[' + peer['user_agent'] + ']'),
      ),
      Divider()
    ]);
  }

  Widget getInCallingLayout(context, orientation) {
    Widget cell(r, m) {
      return RTCVideoView(r, mirror: m);
      // return Container(
      //   width: orientation == Orientation.portrait ? 90.0 : 120.0,
      //   height: orientation == Orientation.portrait ? 120.0 : 90.0,
      //   child: RTCVideoView(r, mirror: true),
      //   decoration: BoxDecoration(color: Colors.black54),
      // );
    }

    return GridView.count(
        crossAxisCount:
            orientation == Orientation.landscape || uiSessions.length > 1
                ? 2
                : 1,
        padding: const EdgeInsets.all(4),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        children: <Widget>[
          cell(_localRenderer, false),
          ...uiSessions.map((uiS) => cell(uiS.remoteRenderer, false))
        ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
            '${uiSessions.length} peers. Room owner: ${isSelfNode(widget.hostNode) ? "you" : widget.hostNode.label}' +
                " [Your ID ($_selfId)]"),
        actions: <Widget>[
          // IconButton(
          //   icon: const Icon(Icons.settings),
          //   onPressed: null,
          //   tooltip: 'setup',
          // ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _inCalling
          ? SizedBox(
              width: 320.0,
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    FloatingActionButton(
                      child: const Icon(Icons.switch_camera),
                      tooltip: 'Camera',
                      heroTag: null,
                      onPressed: _switchCamera,
                    ),
                    FloatingActionButton(
                      child: const Icon(Icons.desktop_mac),
                      tooltip: 'Screen Sharing',
                      heroTag: null,
                      onPressed: () => switchToScreenSharing(context),
                    ),
                    FloatingActionButton(
                      onPressed: _hangUp,
                      tooltip: 'Hangup',
                      heroTag: null,
                      child: Icon(Icons.call_end),
                      backgroundColor: Colors.pink,
                    ),
                    // FloatingActionButton(
                    //   child: const Icon(Icons.info),
                    //   tooltip: 'Connection Info',
                    //   heroTag: null,
                    //   onPressed: () {
                    //     _isShowStats = !_isShowStats;
                    //     setState(() {});
                    //   },
                    //   backgroundColor: Colors.purple,
                    // ),
                    FloatingActionButton(
                      child: _isMute
                          ? const Icon(Icons.mic_off)
                          : const Icon(Icons.mic),
                      tooltip: 'Mute Mic',
                      heroTag: null,
                      onPressed: () {
                        _isMute = !_isMute;
                        setState(() {});
                        _muteMic();
                      },
                    )
                  ]))
          : null,
      body: _inCalling
          ? OrientationBuilder(builder: getInCallingLayout)
          // (context, orientation) {
          //     return Container(
          //       child: Stack(children: <Widget>[
          //         Positioned(
          //             left: 0.0,
          //             right: 0.0,
          //             top: 0.0,
          //             bottom: 0.0,
          //             child: Container(
          //               margin: EdgeInsets.fromLTRB(0.0, 0.0, 0.0, 0.0),
          //               width: MediaQuery.of(context).size.width,
          //               height: MediaQuery.of(context).size.height,
          //               child: RTCVideoView(_remoteRenderer),
          //               decoration: BoxDecoration(color: Colors.black54),
          //             )),
          //         Positioned(
          //             left: 20.0,
          //             top: 20.0,
          //             child: Container(
          //               width:
          //                   orientation == Orientation.portrait ? 90.0 : 120.0,
          //               height:
          //                   orientation == Orientation.portrait ? 120.0 : 90.0,
          //               child: RTCVideoView(_localRenderer, mirror: true),
          //               decoration: BoxDecoration(color: Colors.black54),
          //             )),
          //         Positioned(
          //           left: 20.0,
          //           top: 200.0,
          //           child: Container(
          //               width: 300.0,
          //               height: 200.0,
          //               child: Visibility(
          //                   child: Text(_stats.value), visible: _isShowStats)),
          //         ),
          //       ]),
          //     );
          //   })
          : ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.all(0.0),
              itemCount: signaling.peers.length,
              itemBuilder: (context, i) {
                return _buildRow(context, signaling.peers[i]);
              }),
    );
  }
}
