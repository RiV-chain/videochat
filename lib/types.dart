import 'dart:core';

class Node {
  Node({
    required this.key,
    this.name,
    this.email,
    required this.address,
    this.avatar,
  });

  String key;
  String? name;
  String? email;
  String address;
  String? avatar;

  String get label => name ?? address;

  Map<String, dynamic> toJson() => {
        "name": name,
        "email": email,
        "address": address,
        "key": key,
        "avatar": avatar,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Node &&
          runtimeType == other.runtimeType &&
          address == other.address;

  @override
  int get hashCode => address.hashCode;

  factory Node.fromJson(Map<String, dynamic> json) {
    return Node(
      key: json['key'] ?? "",
      name: json['name'],
      email: json['email'],
      address: json['address'] ?? "",
      avatar: json['avatar'],
    );
  }
}

class Break {}

class Continue {}
