import 'dart:typed_data';
import 'dart:convert';
import '../call_sample/signaling.dart';
import 'package:logging/logging.dart';
import 'package:convert/convert.dart';
import '../types.dart';

String? addrForKey(String key) {
  String toString(Uint8List bytes) {
    // ---------------------------
    // Find longest span of zeroes
    // ---------------------------
//    final bytes = this.toImmutableBytes();

    // Longest seen span
    int? longestStart;
    int longestLength = 0;

    // Current span
    int? start;
    int length = 0;

    // Iterate
    for (var i = 0; i < 16; i++) {
      if (bytes[i] == 0) {
        // Zero byte
        if (start == null) {
          if (i % 2 == 0) {
            // First byte of a span
            start = i;
            length = 1;
          }
        } else {
          length++;
        }
      } else if (start != null) {
        // End of a span
        if (length > longestLength) {
          // Longest so far
          longestStart = start;
          longestLength = length;
        }
        start = null;
      }
    }
    if (start != null && length > longestLength) {
      // End of the longest span
      longestStart = start;
      longestLength = length;
    }

    // Longest length must be a whole group
    longestLength -= longestLength % 2;

    // Ignore longest zero span if it's less than 4 bytes.
    if (longestLength < 4) {
      longestStart = null;
    }

    // ----
    // Print
    // -----
    final sb = StringBuffer();
    var colon = false;
    for (var i = 0; i < 16; i++) {
      if (i == longestStart) {
        sb.write("::");
        i += longestLength - 1;
        colon = false;
        continue;
      }
      final byte = bytes[i];
      if (i % 2 == 0) {
        //
        // First byte of a group
        //
        if (colon) {
          sb.write(":");
        } else {
          colon = true;
        }
        if (byte != 0) {
          sb.write(byte.toRadixString(16));
        }
      } else {
        //
        // Second byte of a group
        //
        // If this is a single-digit number and the previous byte was non-zero,
        // we must add zero
        if (byte < 16 && bytes[i - 1] != 0) {
          sb.write("0");
        }
        sb.write(byte.toRadixString(16));
      }
    }
    return sb.toString();
  }

  final publicKey = hex.decode(key);

  final publicKeySize = 32;
  if (publicKey.length != publicKeySize) {
    return null;
  }

  final buf = Uint8List(publicKeySize);
  for (var i = 0; i < publicKeySize; i++) {
    buf[i] = ~publicKey[i];
  }

  final addr = Uint8List(16);
  final temp = <int>[];
  var done = false;
  var ones = 0;
  var bits = 0;
  var nBits = 0;

  for (var i = 0; i < 8 * buf.length; i++) {
    final bit = ((buf[i ~/ 8] & (0x80 >> (i % 8))) >> (7 - (i % 8))).toInt();
    if (!done && bit != 0) {
      ones++;
      continue;
    }
    if (!done && bit == 0) {
      done = true;
      continue;
    }
    bits = (bits << 1) | bit;
    nBits++;
    if (nBits == 8) {
      nBits = 0;
      temp.add(bits);
    }
  }
  final prefix = Uint8List.fromList([0xfc]);
  addr.setRange(0, prefix.length, prefix);
  addr[prefix.length] = ones;
  addr.setRange(prefix.length + 1, addr.length, temp);
  return toString(addr);
}

class RivApiClient {
  String? endpoint;
  final Signaling signaling;
  Node? _selfNode;
  RivApiClient({required this.signaling});

  connect(String endpoint) async {
    this.endpoint = endpoint;
    while (_selfNode == null) {
      _selfNode = await _getSelfNode();
    }
  }

  Node get selfNode {
    return _selfNode!;
  }

  static final log = Logger("RivApiClient");

  Future<void> findPeers(req, Future<void> Function(Node) onMatch,
      Future<void> Function(List<String> peers, String query) onPeers) async {
    var query = req['query'];
    Future<bool> match(Node node) async {
      var filterMatch = (node.email ?? "").contains(query) ||
          (node.name ?? "").contains(query);
      return filterMatch;
    }

    //Query by Key
    Node? node;
    if (query != '') {
      node = await getRemoteNodeinfo(query);
    }
    if (node != null) {
      await onMatch(node);
    } else if (req["peers"].isEmpty) {
      node = selfNode;

      if (await match(node)) {
        await onMatch(node);
      }
      await onPeers(await getPeers(), query);
    } else {
      for (var p in req["peers"]) {
        node = await getRemoteNodeinfo(p);

        if (node != null && await match(node)) {
          await onMatch(node);
        }
        await onPeers(await getRemotePeers(p), query);
      }
    }
  }

  Future<Node?> _getSelfNode() async {
    final response = await signaling.httpGet("$endpoint/api/self");
    if (response.statusCode != 200) {
      log.warning('GET /api/self failed: ${response.reasonPhrase}');
      return null;
    }
    final Map<String, dynamic> self = jsonDecode(response.body);
    return getRemoteNodeinfo(self["key"]);
  }

  Future<Node?> getRemoteNodeinfo(String key) async {
    final response =
        await signaling.httpGet("$endpoint/api/remote/nodeinfo/$key");
    if (response.statusCode != 200) {
      if (response.statusCode != 502) {
        log.warning(
            'GET /api/remote/nodeinfo/$key failed: ${response.reasonPhrase}');
      }
      return null;
    }
    final Map<String, dynamic> ns = jsonDecode(response.body);
    final n = Node.fromJson(ns[key]);
    n.key = key;
    var addrBytes = addrForKey(key);
    if (addrBytes != null) {
      // n.address = InternetAddress.fromRawAddress(addrBytes,
      //         type: InternetAddressType.IPv6)
      //     .address;
      n.address = addrBytes;
    }
    return n;
  }

  Future<List<String>> getRemotePeers(String key) async {
    final response = await signaling.httpGet("$endpoint/api/remote/peers/$key");
    if (response.statusCode != 200) {
      if (response.statusCode != 502) {
        log.warning(
            'GET /api/remote/peers/$key failed: ${response.reasonPhrase}');
      }
      return [];
    }
    final Map<String, dynamic> m = jsonDecode(response.body);
    List<String> result =
        (m.values.first["keys"] as List).map((item) => item as String).toList();
    return result;
  }

  Future<List<String>> getPeers() async {
    var p = <String>[];
    var response = await signaling.httpGet("$endpoint/api/peers");
    if (response.statusCode != 200) {
      log.warning('GET /api/peers failed: ${response.reasonPhrase}');
    }
    var peers = List<Map<String, dynamic>>.from(json.decode(response.body));
    for (var peer in peers) {
      p.add(peer['key']);
    }
    return p;
  }
}
