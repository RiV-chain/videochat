import 'package:flutter/material.dart';
import 'dart:core';

typedef void RouteCallback(BuildContext context);

class RouteItem {
  RouteItem({
    required this.key,
    required this.name,
    required this.email,
    required this.address,
    required this.avatar,
  });

  final String key;
  final String name;
  final String email;
  final String address;
  final String avatar;

  factory RouteItem.fromJson(Map<String, dynamic> json) {
    return RouteItem(
      key: json['key'],
      name: json['name'],
      email: json['email'],
      address: json['address'],
      avatar: json['avatar'],
    );
  }
}
