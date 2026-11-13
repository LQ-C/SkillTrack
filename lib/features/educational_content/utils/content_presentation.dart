import 'package:flutter/material.dart';

IconData kindIcon(String kind) => switch (kind) {
  'Video' => Icons.play_circle_outline,
  'Guide' => Icons.format_list_numbered,
  _ => Icons.menu_book_outlined,
};
String statusLabel(String value) => switch (value) {
  'published' => 'Published',
  'archived' => 'Archived',
  _ => 'Draft',
};
