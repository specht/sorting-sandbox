import 'package:flutter/material.dart';

Color parseHexColor(String value) {
  final hex = value.replaceFirst('#', '');
  final normalized = hex.length == 6 ? 'FF$hex' : hex;
  final number = int.tryParse(normalized, radix: 16);
  return number == null ? Colors.blueGrey : Color(number);
}
