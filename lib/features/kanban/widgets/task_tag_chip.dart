import 'package:flutter/material.dart';

import '../models/task_tag.dart';
import '../utils/task_tag_color_utils.dart';

class TaskTagChip extends StatelessWidget {
  const TaskTagChip({
    super.key,
    required this.tag,
    this.selected = false,
    this.onPressed,
    this.onDeleted,
    this.compact = false,
    this.enabled = true,
  });

  final TaskTag tag;
  final bool selected;
  final VoidCallback? onPressed;
  final VoidCallback? onDeleted;
  final bool compact;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final background = TaskTagColorUtils.background(
      tag.colorHex,
      selected: selected,
    );
    final foreground = TaskTagColorUtils.foreground(
      tag.colorHex,
      selected: selected,
    );
    final outline = TaskTagColorUtils.border(tag.colorHex, selected: selected);
    final radius = BorderRadius.circular(20);
    return Semantics(
      label: tag.name,
      selected: selected,
      button: onPressed != null,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : .55,
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeInOutCubic,
          decoration: BoxDecoration(
            color: background,
            borderRadius: radius,
            border: Border.all(color: outline, width: selected ? 2 : 1),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('tag-chip-${tag.id}'),
              borderRadius: radius,
              onTap: enabled ? onPressed : null,
              child: Container(
                constraints: BoxConstraints(
                  minHeight: onPressed != null || onDeleted != null
                      ? 44
                      : compact
                      ? 28
                      : 36,
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 8 : 10,
                  vertical: onDeleted != null
                      ? 0
                      : compact
                      ? 3
                      : 5,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: compact ? 9 : 11,
                      height: compact ? 9 : 11,
                      decoration: BoxDecoration(
                        color: TaskTagColorUtils.base(tag.colorHex),
                        shape: BoxShape.circle,
                        border: Border.all(color: outline),
                      ),
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.sizeOf(context).width * .55,
                      ),
                      child: Text(
                        tag.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontSize: compact ? 11 : null,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                    AnimatedSwitcher(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      child: selected
                          ? Padding(
                              key: const ValueKey('selected'),
                              padding: const EdgeInsets.only(left: 5),
                              child: Icon(
                                Icons.check,
                                size: compact ? 14 : 18,
                                color: foreground,
                              ),
                            )
                          : const SizedBox(key: ValueKey('unselected')),
                    ),
                    if (onDeleted != null)
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: IconButton(
                          tooltip: 'Remove ${tag.name}',
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          onPressed: enabled ? onDeleted : null,
                          icon: Icon(Icons.close, color: foreground),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
