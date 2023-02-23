//Hold app level singleton objects
import 'call_sample/signaling.dart';
import 'types.dart';

var signaling = Signaling();

bool isSelfNode(Node node) {
  return signaling.riv.selfNode.address == node.address;
}
