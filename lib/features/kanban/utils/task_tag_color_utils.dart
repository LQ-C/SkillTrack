import 'package:flutter/material.dart';

import '../models/task_tag.dart';

const predefinedTagColors = [
  '#5C6BC0',
  '#3949AB',
  '#1E88E5',
  '#039BE5',
  '#00897B',
  '#43A047',
  '#7CB342',
  '#C0CA33',
  '#F9A825',
  '#FB8C00',
  '#F4511E',
  '#E53935',
  '#D81B60',
  '#8E24AA',
  '#6D4C41',
  '#546E7A',
];

const predefinedTagColorNames = [
  'Indigo',
  'Dark Indigo',
  'Blue',
  'Light Blue',
  'Teal',
  'Green',
  'Light Green',
  'Lime',
  'Yellow',
  'Orange',
  'Deep Orange',
  'Red',
  'Pink',
  'Purple',
  'Brown',
  'Blue Grey',
];

class TaskTagColorUtils {
  static String normalize(String input) =>
      TaskTag.normalizeHex(input) ?? TaskTag.defaultColorHex;

  static bool isValid(String input) => TaskTag.isValidHex(input);

  static Color base(String colorHex) {
    final normalized = normalize(colorHex);
    return Color(int.parse('FF${normalized.substring(1)}', radix: 16));
  }

  static Color background(String colorHex, {bool selected = false}) =>
      Color.alphaBlend(
        base(colorHex).withValues(alpha: selected ? .23 : .12),
        Colors.white,
      );

  static Color foreground(String colorHex, {bool selected = false}) =>
      background(colorHex, selected: selected).computeLuminance() > .45
      ? const Color(0xFF171923)
      : Colors.white;

  static Color border(String colorHex, {bool selected = false}) {
    final color = base(colorHex);
    if (color.computeLuminance() > .75) {
      return const Color(0xFF7B808B);
    }
    return color.withValues(alpha: selected ? 1 : .7);
  }

  static Color mark(String colorHex) => base(colorHex).computeLuminance() > .55
      ? const Color(0xFF171923)
      : Colors.white;
}
