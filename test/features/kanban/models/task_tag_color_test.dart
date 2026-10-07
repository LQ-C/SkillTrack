import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/kanban/models/task_tag.dart';
import 'package:skilltrack/features/kanban/utils/task_tag_color_utils.dart';

void main() {
  test('normalizes exactly six hex digits', () {
    expect(TaskTag.normalizeHex('5c6bc0'), '#5C6BC0');
    expect(TaskTag.normalizeHex('#5c6bc0'), '#5C6BC0');
    expect(TaskTag.normalizeHex(' #5C6BC0 '), '#5C6BC0');
    expect(TaskTag.isValidHex('#5C6BC0'), true);
    for (final invalid in [
      '#FFF',
      '12345',
      '1234567',
      'red',
      '#GG0000',
      '#FF5C6BC0',
    ]) {
      expect(TaskTag.normalizeHex(invalid), isNull, reason: invalid);
    }
  });

  test(
    'invalid stored colors use the default without Flutter in the model',
    () {
      final tag = TaskTag.fromMap({
        'id': '1',
        'owner_id': 'user-1',
        'name': 'Old',
        'color_hex': 'invalid',
      });
      expect(tag.colorHex, TaskTag.defaultColorHex);
      expect(
        TaskTagColorUtils.base('invalid'),
        TaskTagColorUtils.base(TaskTag.defaultColorHex),
      );
      expect(predefinedTagColors.length, 16);
      expect(predefinedTagColorNames.length, 16);
    },
  );

  test('light, dark and saturated tags retain visible text and borders', () {
    for (final hex in ['#FFFFFF', '#000000', '#E53935', '#F9A825']) {
      final background = TaskTagColorUtils.background(hex);
      final foreground = TaskTagColorUtils.foreground(hex);
      final bright = background.computeLuminance();
      final dark = foreground.computeLuminance();
      final ratio = (bright > dark)
          ? (bright + .05) / (dark + .05)
          : (dark + .05) / (bright + .05);
      expect(ratio, greaterThanOrEqualTo(4.5), reason: hex);
      expect(TaskTagColorUtils.border(hex), isNot(Colors.transparent));
    }
  });
}
