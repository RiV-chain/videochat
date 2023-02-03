import 'dart:core';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/call_sample/call_sample.dart';
import 'src/route_item.dart';
import 'package:http/http.dart' as http;

void main() => runApp(new MyApp());

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => new _MyAppState();
}

/*
class _MyAppState2 extends State<MyApp> {
  String _server = '';
  late SharedPreferences _prefs;

  @override
  initState() {
    super.initState();
    () async {
      _prefs = await SharedPreferences.getInstance();
      setState(() {
        _server = _prefs.getString('server') ?? 'sl.rivchain.org';
      });
    }();
  }

  @override
  Widget build(BuildContext _) {
    return MaterialApp(
        home: Scaffold(
            appBar: AppBar(
              title: Text('Flutter-WebRTC example'),
            ),
            body: AlertDialog(
                title: const Text('Enter server address:'),
                content: TextField(
                  onChanged: (String text) {
                    setState(() {
                      _server = text;
                    });
                  },
                  decoration: InputDecoration(
                    hintText: _server,
                  ),
                  textAlign: TextAlign.center,
                ),
                actions: <Widget>[
                  Builder(
                      builder: (context) => TextButton(
                          child: const Text('CONNECT'),
                          onPressed: () {
                            _prefs.setString('server', _server);
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (BuildContext context) =>
                                        CallSample(host: _server)));
                          }))
                ])));
  }
}
*/
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
          _showAddressDialog(context);
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

  void showDemoDialog<T>(
      {required BuildContext context, required Widget child}) {
    showDialog<T>(
      context: context,
      builder: (BuildContext context) => child,
    ).then<void>((T? value) {
      // The value passed to Navigator.pop() or null.
      if (value != null) {
        if (value == DialogDemoAction.connect) {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (BuildContext context) =>
                      CallSample(host: _server)));
        }
      }
    });
  }

  _showAddressDialog(context) {
    showDemoDialog<DialogDemoAction>(
        context: context,
        child: AlertDialog(
            title: const Text('Enter server address:'),
            content: TextField(
              onChanged: (String text) {
                setState(() {
                  _server = text;
                });
              },
              decoration: InputDecoration(
                hintText: _server,
              ),
              textAlign: TextAlign.center,
            ),
            actions: <Widget>[
              TextButton(
                  child: const Text('CANCEL'),
                  onPressed: () {
                    Navigator.pop(context, DialogDemoAction.cancel);
                  }),
              TextButton(
                  child: const Text('CONNECT'),
                  onPressed: () {
                    Navigator.pop(context, DialogDemoAction.connect);
                  })
            ]));
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
/*
//https://github.com/rebelchris/flutter/blob/feature/list-search/lib/main.dart

void main1() async {
  runApp(AnimeApp());
}

class AnimeApp extends StatefulWidget {
  AnimeApp({Key? key}) : super(key: key);

  @override
  _AnimeAppState createState() => _AnimeAppState();
}

class _AnimeAppState extends State<AnimeApp> {
  late Future<List<Show>> fshows;
  List<Show> shows = List.empty(growable: true);

  @override
  void initState() {
    super.initState();
    fshows = fetchShows("");
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video chat',
      debugShowCheckedModeBanner: false,
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
                    fshows = fetchShows(value);
                  });
                },
                decoration: InputDecoration(
                    labelText: 'Search', suffixIcon: Icon(Icons.search)),
              ),
            ),
            SizedBox(height: 10),
            Expanded(
              child: FutureBuilder(
                builder: (context, AsyncSnapshot<List<Show>> snapshot) {
                  if (snapshot.hasData) {
                    return Center(
                      child: ListView.separated(
                        padding: const EdgeInsets.all(8),
                        itemCount: snapshot.data!.length,
                        itemBuilder: (BuildContext context, int index) {
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundImage: NetworkImage(
                                  '${snapshot.data?[index].avatar}'),
                            ),
                            title: Text('${snapshot.data?[index].email}'),
                            subtitle: Text('Key: ${snapshot.data?[index].key}'),
                          );
                        },
                        separatorBuilder: (BuildContext context, int index) {
                          return Divider();
                        },
                      ),
                    );
                  } else if (snapshot.hasError) {
                    return Center(child: Text('Something went wrong :('));
                  }
                  return CircularProgressIndicator();
                },
                future: fshows,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Show {
  final String key;
  final String email;
  final String address;
  final String avatar;

  Show({
    required this.key,
    required this.email,
    required this.address,
    required this.avatar,
  });

  factory Show.fromJson(Map<String, dynamic> json) {
    return Show(
      key: json['key'],
      email: json['email'],
      address: json['address'],
      avatar: json['avatar'],
    );
  }
}

Future<List<Show>> fetchShows(String query) async {
  final response =
      await http.post(Uri.parse('https://sl.rivchain.org:8086/api/contacts'),
          headers: <String, String>{
            'Content-Type': 'application/json; charset=UTF-8',
          },
          body: jsonEncode({'query': query, 'peers': []}));

  if (response.statusCode == 200) {
    var topShowsJson = jsonDecode(response.body)['matches'] as List;
    return topShowsJson.map((show) => Show.fromJson(show)).toList();
  } else {
    throw Exception('Failed to load shows');
  }
}
*/