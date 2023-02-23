import 'dart:async';
import 'dart:core';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/material.dart';

import '../widgets/screen_select_dialog.dart';
import '../utils/stats_report.dart';
import '../call_sample/signaling.dart';
import '../types.dart';
import '../common.dart';

typedef Peer = Map<String, dynamic>;

class CallSample extends StatefulWidget {
  static String tag = 'call_sample';
  final Node hostNode;
  CallSample({required this.hostNode});

  @override
  _CallSampleState createState() => _CallSampleState();
}

class _CallSampleState extends State<CallSample> {
  String get _selfId => signaling.riv.selfNode.address;
  RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _inCalling = false;
  Session? _session;
  StatsReportUtil _stats = StatsReportUtil();
  bool _isShowStats = false;
  bool _isMute = false;
  //DesktopCapturerSource? selected_source_;
  bool _waitAccept = false;

  // ignore: unused_element
  _CallSampleState();

  @override
  initState() {
    super.initState();
    initRenderers();
    _connect(context);
  }

  initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  @override
  deactivate() {
    signaling.checkOut();
//    signaling.close();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.deactivate();
  }

  void _connect(BuildContext context) async {
    signaling.createStream = (s) => _createStream(s, context);

    signaling.onCallStateChange = (Session session, CallState state) async {
      switch (state) {
        case CallState.CallStateNew:
          setState(() {
            _session = session;
            _startStats();
          });
          break;
        case CallState.CallStateRinging:
          session.videoSource = await _showAcceptDialog();
          if (session.videoSource != null) {
            setState(() {
              _inCalling = true;
            });
          }
          break;
        case CallState.CallStateBye:
          if (_waitAccept) {
            print('peer reject');
            _waitAccept = false;
            Navigator.of(context).pop(false);
          }
          setState(() {
            _localRenderer.srcObject = null;
            _remoteRenderer.srcObject = null;
            _inCalling = false;
            _session = null;
          });
          break;
        case CallState.CallStateInvite:
          _waitAccept = true;
          _showInviteDialog();
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
        print(e.toString());
      }
    });

    signaling.onLocalStream = ((stream) {
      _localRenderer.srcObject = stream;
      setState(() {});
    });

    signaling.onAddRemoteStream = ((_, stream) {
      _remoteRenderer.srcObject = stream;
      setState(() {});
    });

    signaling.onRemoveRemoteStream = ((_, stream) {
      _remoteRenderer.srcObject = null;
    });
    signaling.checkIn(widget.hostNode.address);
  }

  Future<VideoSource?> _showAcceptDialog() {
    return showDialog<VideoSource?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Incoming call"),
          content: Text(
              "${_session?.pid} invites to a video meeting. He offers his ${_session?.videoSource?.toString().split('.').last} source. Accept it?"),
          actions: <Widget>[
            MaterialButton(
              child: Text(
                'Reject',
                style: TextStyle(color: Colors.red),
              ),
              onPressed: () => Navigator.of(context).pop(null),
            ),
            MaterialButton(
              child: Text(
                'Camera',
                style: TextStyle(color: Colors.green),
              ),
              onPressed: () => Navigator.of(context).pop(VideoSource.Camera),
            ),
            MaterialButton(
              child: Text(
                'Screen',
                style: TextStyle(color: Colors.green),
              ),
              onPressed: () => Navigator.of(context).pop(VideoSource.Screen),
            ),
            MaterialButton(
              child: Text(
                'Audio',
                style: TextStyle(color: Colors.green),
              ),
              onPressed: () => Navigator.of(context).pop(VideoSource.AudioOnly),
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _showInviteDialog() {
    return showDialog<bool?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Outgoing call"),
          content: Text("The invite sent to " +
              _session!.pid +
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
    if (_session != null) {
      signaling.bye(_session!);
    }
  }

  _switchCamera() {
    signaling.switchCamera();
  }

  Future<MediaStream?> _createStream(
      VideoSource videoSource, BuildContext context) async {
    MediaStream? stream;
    try {
      switch (videoSource) {
        case VideoSource.Screen:
          if (WebRTC.platformIsDesktop) {
            final source = await showDialog<DesktopCapturerSource>(
              context: context,
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
      print("Get media error: " + e.toString());
    }
    return stream;
  }

  Future<void> switchToScreenSharing(BuildContext context) async {
    MediaStream? screenStream =
        await _createStream(VideoSource.Screen, context);
    if (screenStream != null) signaling.switchScreenSharing(screenStream);
  }

  _muteMic() {
    signaling.muteMic(_isMute);
  }

  _startStats() {
    Timer.periodic(
        const Duration(milliseconds: StatsReportUtil.STATS_INTERVAL_MS),
        (timer) async {
      try {
        _stats.updateStatsReport(await _session!.pc!.getStats());
        setState(() {});
      } catch (e) {
        print('Stats stop $e');
        timer.cancel();
      }
    });
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
            width: 120.0,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
            'P2P Video Call. Room owner: ${isSelfNode(widget.hostNode) ? "you" : (widget.hostNode.name ?? widget.hostNode.address)}' +
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
                      onPressed: _switchCamera,
                    ),
                    FloatingActionButton(
                      child: const Icon(Icons.desktop_mac),
                      tooltip: 'Screen Sharing',
                      onPressed: () => switchToScreenSharing(context),
                    ),
                    FloatingActionButton(
                      onPressed: _hangUp,
                      tooltip: 'Hangup',
                      child: Icon(Icons.call_end),
                      backgroundColor: Colors.pink,
                    ),
                    FloatingActionButton(
                      child: const Icon(Icons.info),
                      tooltip: 'Connection Info',
                      onPressed: () {
                        _isShowStats = !_isShowStats;
                        setState(() {});
                      },
                      backgroundColor: Colors.purple,
                    ),
                    FloatingActionButton(
                      child: _isMute
                          ? const Icon(Icons.mic_off)
                          : const Icon(Icons.mic),
                      tooltip: 'Mute Mic',
                      onPressed: () {
                        _isMute = !_isMute;
                        setState(() {});
                        _muteMic();
                      },
                    )
                  ]))
          : null,
      body: _inCalling
          ? OrientationBuilder(builder: (context, orientation) {
              return Container(
                child: Stack(children: <Widget>[
                  Positioned(
                      left: 0.0,
                      right: 0.0,
                      top: 0.0,
                      bottom: 0.0,
                      child: Container(
                        margin: EdgeInsets.fromLTRB(0.0, 0.0, 0.0, 0.0),
                        width: MediaQuery.of(context).size.width,
                        height: MediaQuery.of(context).size.height,
                        child: RTCVideoView(_remoteRenderer),
                        decoration: BoxDecoration(color: Colors.black54),
                      )),
                  Positioned(
                      left: 20.0,
                      top: 20.0,
                      child: Container(
                        width:
                            orientation == Orientation.portrait ? 90.0 : 120.0,
                        height:
                            orientation == Orientation.portrait ? 120.0 : 90.0,
                        child: RTCVideoView(_localRenderer, mirror: true),
                        decoration: BoxDecoration(color: Colors.black54),
                      )),
                  Positioned(
                    left: 20.0,
                    top: 200.0,
                    child: Container(
                        width: 300.0,
                        height: 200.0,
                        child: Visibility(
                            child: Text(_stats.value), visible: _isShowStats)),
                  ),
                ]),
              );
            })
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
