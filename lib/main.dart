import 'dart:core';
import 'package:flutter/material.dart';

import 'package:coriv/call_sample/call_sample.dart';
import 'package:coriv/types.dart';
import 'package:coriv/common.dart';
import 'package:coriv/call_sample/signaling.dart';
import 'package:logging/logging.dart';

void main() => runApp(new MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => new _MyAppState();
}

enum DialogDemoAction {
  cancel,
  connect,
}

class _MyAppState extends State<MyApp> {
  List<Node> items = [];
  Set peerKeys = {};
  String itemsQuery = '';
  bool _allowFindPeers = false;

  @override
  initState() {
    super.initState();
    Logger.root.level = Level.ALL; // defaults to Level.INFO
    Logger.root.onRecord.listen((record) {
      print(
          '${record.time}: ${record.level.name}: ${record.loggerName}: ${record.message}');
    });

    signaling.connect();
    signaling.onSignalingStateChange = (SignalingState state) async {
      switch (state) {
        case SignalingState.ConnectionClosed:
        case SignalingState.ConnectionError:
          break;
        case SignalingState.ConnectionOpen:
          _allowFindPeers = true;
          fetchItems(itemsQuery);
          break;
      }
    };
    signaling.createStream = SessionUi.createStream;
    signaling.showAcceptDialog = SessionUi.showAcceptDialog;
    signaling.onCallStateChange = _onCallStateChange;
  }

  _onCallStateChange(Session session, CallState state) async {
    if (state == CallState.CallStateRinging) {
//      if (session.videoSource != null) {
      _enterRoot(SessionUi.context, signaling.riv.selfNode, session);
//      }
    }
  }

  _enterRoot(context, Node item, [Session? session]) async {
    _allowFindPeers = false;
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (BuildContext context) =>
                CallSample(hostNode: item, session: session)));
    SessionUi.context = context;
    signaling.onCallStateChange = _onCallStateChange;
  }

  _buildRow(context, Node item) {
    return ListBody(children: <Widget>[
      ListTile(
        leading: CircleAvatar(
          backgroundImage:
              item.avatar != null ? NetworkImage(item.avatar!) : null,
          backgroundColor: Colors.brown.shade800,
          child: Text((item.label).substring(0, 2)),
        ),
        title: Text('${item.label}${isSelfNode(item) ? " [This node]" : ""}'),
        subtitle: Text('Key: ${item.key}'),
        onTap: () => _enterRoot(context, item),
        trailing: Icon(Icons.arrow_right),
      ),
      Divider()
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
          appBar: AppBar(title: Text('Video chat')),
          body: LayoutBuilder(builder:
              (BuildContext context, BoxConstraints viewportConstraints) {
            SessionUi.context = context;
            return SingleChildScrollView(
                child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: viewportConstraints.maxHeight,
                    ),
                    child: Column(
                        mainAxisSize: MainAxisSize.max,
                        mainAxisAlignment: MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(height: 10),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 15.0),
                            child: TextField(
                              // controller:
                              //     TextEditingController(text: itemsQuery),
                              onChanged: (value) {
                                setState(() {
                                  itemsQuery = value;
                                  items.clear();
                                  peerKeys.clear();
                                  fetchItems(value);
                                });
                              },
                              decoration: InputDecoration(
                                  labelText: 'Search',
                                  suffixIcon: Icon(Icons.search)),
                            ),
                          ),
                          SizedBox(height: 10),
                          ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.all(0.0),
                              itemCount: items.length,
                              itemBuilder: (context, i) {
                                return _buildRow(context, items[i]);
                              })
                        ])));
          })),
    );
  }

  fetchItems(String query, [List apeers = const []]) async {
    if (!_allowFindPeers) return;
    if (items.isEmpty) {
      items.add(signaling.riv.selfNode);
      setState(() {});
    }
    if (itemsQuery == query) {
      var fpeers = [];
      try {
        await signaling.riv.findPeers({
          'query': query,
          'peers': apeers,
        }, (node) async {
          if (!_allowFindPeers) throw Break();
          if (items.where((n) {
            return node.key == n.key;
          }).isEmpty) {
            if (await signaling.pingPeer(node.address)) {
              items.add(node);
              setState(() {});
            }
          }
        }, (peers, query) async {
          if (!_allowFindPeers) throw Break();
          fpeers.addAll(peers.where((peer) => !peerKeys.contains(peer)));
          peerKeys.addAll(fpeers);
        });
      } on Break {
        return;
      }
      if (fpeers.isNotEmpty) {
        await fetchItems(query, fpeers);
      }
    }
  }
}
