import 'dart:core';
import 'package:flutter/material.dart';

import 'package:coriv/call_sample/call_sample.dart';
import 'package:coriv/types.dart';
import 'package:coriv/common.dart';
import 'package:coriv/call_sample/signaling.dart';

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
  String itemsQuery = 'rivchain.org';
  bool _allowFindPeers = false;

  @override
  initState() {
    super.initState();

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
  }

  _buildRow(context, Node item) {
    return ListBody(children: <Widget>[
      ListTile(
        leading: CircleAvatar(
          backgroundImage:
              item.avatar != null ? NetworkImage(item.avatar!) : null,
          backgroundColor: Colors.brown.shade800,
          child: Text((item.name ?? item.address).substring(0, 2)),
        ),
        title: Text(
            '${item.name ?? item.address}${isSelfNode(item) ? " [This node]" : ""}'),
        subtitle: Text('Key: ${item.key}'),
        onTap: () {
          _allowFindPeers = false;
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (BuildContext context) =>
                      CallSample(hostNode: item)));
        },
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
                              controller:
                                  TextEditingController(text: itemsQuery),
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
    // apeers = [
    //   '25be80af538c1673028ff3f1099464b4d6a060a96c7ef096acbbd971af14848f',
    //   '112e5229a0a4ee3afebbcc0e92655f63cf8b54906340bbd74beed965bd36b463'
    // ];
    if (!_allowFindPeers) return;
    if (itemsQuery == query) {
      try {
        await signaling.riv.findPeers({
          'query': query,
          'peers': apeers,
        }, (node) async {
          if (!_allowFindPeers) throw Break();
          if (!peerKeys.contains(node.key)) {
            peerKeys.add(node.key);
            if (await signaling.pingPeer(node.address)) {
              items.add(node);
              setState(() {});
            }
          }
        }, (peers, query) async {
          if (!_allowFindPeers) throw Break();
          var fpeers = peers.where((peer) => !peerKeys.contains(peer)).toList();
          if (fpeers.isNotEmpty) {
            await fetchItems(query, fpeers);
          }
        });
      } on Break {
        return;
      }
    }
  }
}
