import 'dart:core';

class Node {
  Node({
    required this.key,
    required this.name,
    required this.email,
    required this.address,
    required this.avatar,
  });

  String key;
  String? name;
  String? email;
  String address;
  String? avatar;

  Map<String, dynamic> toJson() => {
        "name": name,
        "email": email,
        "address": address,
        "key": key,
        "avatar": avatar,
      };

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
