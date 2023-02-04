import 'dart:core';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'src/call_sample/call_sample.dart';
import 'src/route_item.dart';
import 'package:http/http.dart' as http;

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
  List<RouteItem> items = [];
  Set peerKeys = {};
  String itemsQuery = '';
  String _server = '';

  @override
  initState() {
    super.initState();
    fetchItems("");
  }

  _buildRow(context, RouteItem item) {
    return ListBody(children: <Widget>[
      ListTile(
        leading: CircleAvatar(
          backgroundImage:
              item.avatar.isNotEmpty ? NetworkImage(item.avatar) : null,
          backgroundColor: Colors.brown.shade800,
          child: Text(item.name.length >= 2
              ? item.name.substring(0, 2)
              : item.key.substring(0, 2)),
        ),
        title: Text('${item.name} (${item.email})'),
        subtitle: Text('Key: ${item.key}'),
        onTap: () {
          _server = item.name.contains(".") ? item.name : item.address;
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (BuildContext context) =>
                      CallSample(host: _server)));
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
          body: Column(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 15.0),
                  child: TextField(
                    onChanged: (value) {
                      setState(() {
                        itemsQuery = value;
                        items.clear();
                        peerKeys.clear();
                        fetchItems(value);
                      });
                    },
                    decoration: InputDecoration(
                        labelText: 'Search', suffixIcon: Icon(Icons.search)),
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
              ])),
    );
  }

  fetchItems(String query, [List peers = const []]) async {
    final response =
        await http.post(Uri.parse('https://sl.rivchain.org:8086/api/contacts'),
            headers: <String, String>{
              'Content-Type': 'application/json; charset=UTF-8',
            },
            body: jsonEncode({'query': query, 'peers': peers}));

    if (response.statusCode == 200) {
      if (itemsQuery == query) {
        var matches = jsonDecode(response.body)['matches'] as List;

        matches
            .map((item) => RouteItem.fromJson(item))
            .toList()
            .forEach((node) {
          if (!peerKeys.contains(node.key)) {
            items.add(node);
            peerKeys.add(node.key);
          }
        });

        setState(() {});

        var peers = (jsonDecode(response.body)['peers'] as List)
            .where((peer) => peer.contains(peer))
            .toList();
        if (peers.isNotEmpty) {
          fetchItems(query, peers);
        }
      }
    } else {
      throw Exception('Failed to load shows');
    }
  }
}
