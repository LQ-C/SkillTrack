import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../utils/kanban_colors.dart';
import '../models/kanban_status.dart';
import '../models/kanban_task.dart';
import 'kanban_task_card.dart';

class KanbanStatusColumn extends StatefulWidget {
  const KanbanStatusColumn({
    super.key,
    required this.status,
    required this.tasks,
    required this.scrollController,
    required this.viewportKey,
    required this.boardViewportKey,
    required this.draggedTaskId,
    required this.draggedCardHeight,
    required this.accentTaskIds,
    required this.departingTaskId,
    required this.dragPointer,
    required this.hoverStatus,
    required this.hoverIndex,
    required this.onTaskTap,
    required this.onTaskAction,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onHover,
    required this.onLeave,
    required this.onDrop,
    this.dragEnabled = true,
  });

  final KanbanStatus status;
  final bool dragEnabled;
  final List<KanbanTask> tasks;
  final ScrollController scrollController;
  final GlobalKey viewportKey;
  final GlobalKey boardViewportKey;
  final String? draggedTaskId;
  final double? draggedCardHeight;
  final Set<String> accentTaskIds;
  final String? departingTaskId;
  final ValueListenable<Offset?> dragPointer;
  final KanbanStatus? hoverStatus;
  final int? hoverIndex;
  final ValueChanged<KanbanTask>? onTaskTap;
  final void Function(KanbanTask, TaskCardAction)? onTaskAction;
  final void Function(KanbanTask, Rect) onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final ValueChanged<DraggableDetails> onDragEnd;
  final void Function(KanbanStatus, int) onHover;
  final ValueChanged<KanbanStatus> onLeave;
  final void Function(String, KanbanStatus, int, Rect?) onDrop;

  @override
  State<KanbanStatusColumn> createState() => _KanbanStatusColumnState();
}

class _KanbanStatusColumnState extends State<KanbanStatusColumn>
    with AutomaticKeepAliveClientMixin {
  final Map<String, GlobalKey> _cardKeys = {};
  final _placeholderKey = GlobalKey();
  final ValueNotifier<Offset> _feedbackPointer = ValueNotifier(Offset.zero);

  @override
  void dispose() {
    _feedbackPointer.dispose();
    super.dispose();
  }

  Rect? _placeholderRect() {
    final box = _placeholderKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  bool get wantKeepAlive => true;

  int _insertionIndex(Offset globalPosition) {
    final viewport = widget.viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return 0;
    final pointerY = viewport.globalToLocal(globalPosition).dy;
    final sourceColumn = widget.tasks.any(
      (task) => task.id == widget.draggedTaskId,
    );
    var index = 0;
    var lastVisibleIndex = -1;
    for (final task in widget.tasks) {
      if (task.id == widget.draggedTaskId) continue;
      final box = _cardKeys[task.id]?.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        var midpoint = viewport
            .globalToLocal(box.localToGlobal(Offset(0, box.size.height / 2)))
            .dy;
        if (sourceColumn &&
            widget.hoverStatus == widget.status &&
            widget.hoverIndex != null &&
            widget.hoverIndex! <= index) {
          midpoint -= (widget.draggedCardHeight ?? 76) + 12;
        }
        if (pointerY < midpoint) return index;
        lastVisibleIndex = index;
      }
      index++;
    }
    return lastVisibleIndex < 0 ? 0 : lastVisibleIndex + 1;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final hovering =
        widget.draggedTaskId != null && widget.hoverStatus == widget.status;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final destinationHint = hovering
        ? Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Move to ${widget.status.label}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: KanbanColors.status(widget.status),
              ),
            ),
          )
        : const SizedBox(width: double.infinity);
    final items = <Widget Function()>[];
    var insertionIndex = 0;
    void addSlot() {
      final slotIndex = insertionIndex;
      items.add(() {
        final active = hovering && widget.hoverIndex == slotIndex;
        final child = active
            ? _placeholder()
            : const SizedBox(width: double.infinity);
        final key = ValueKey('slot-${widget.status.value}-$slotIndex');
        return reduced
            ? KeyedSubtree(key: key, child: child)
            : AnimatedSize(
                key: key,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOutCubic,
                alignment: Alignment.topCenter,
                child: child,
              );
      });
    }

    addSlot();
    for (final task in widget.tasks) {
      items.add(
        () => KeyedSubtree(
          key: _cardKeys.putIfAbsent(task.id, GlobalKey.new),
          child: TweenAnimationBuilder<double>(
            tween: Tween(
              begin: 1,
              end: widget.departingTaskId == task.id ? 0 : 1,
            ),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 260),
            curve: Curves.easeInCubic,
            builder: (context, value, child) => ClipRect(
              child: Align(
                heightFactor: value,
                child: Opacity(opacity: value, child: child),
              ),
            ),
            child: IgnorePointer(
              ignoring: widget.departingTaskId == task.id,
              child: LayoutBuilder(
                builder: (context, constraints) => Listener(
                  onPointerDown: (event) =>
                      _feedbackPointer.value = event.position,
                  child: LongPressDraggable<String>(
                    data: task.id,
                    maxSimultaneousDrags: widget.dragEnabled ? 1 : 0,
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    onDragStarted: () {
                      final box = _cardKeys[task.id]?.currentContext
                          ?.findRenderObject();
                      final origin = box is RenderBox
                          ? box.localToGlobal(Offset.zero) & box.size
                          : Rect.fromLTWH(0, 0, constraints.maxWidth, 76);
                      widget.onDragStart(task, origin);
                    },
                    onDragUpdate: (details) {
                      _feedbackPointer.value = details.globalPosition;
                      widget.onDragUpdate(details.globalPosition);
                    },
                    onDragEnd: widget.onDragEnd,
                    feedback: Builder(
                      builder: (context) {
                        final source = _cardKeys[task.id]?.currentContext
                            ?.findRenderObject();
                        final height = source is RenderBox
                            ? source.size.height
                            : 80.0;
                        final screen = MediaQuery.sizeOf(context);
                        final safe = MediaQuery.paddingOf(context);
                        final width = constraints.maxWidth
                            .clamp(0, screen.width - 144)
                            .toDouble();
                        final board = widget.boardViewportKey.currentContext
                            ?.findRenderObject();
                        final boardRect = board is RenderBox && board.hasSize
                            ? board.localToGlobal(Offset.zero) & board.size
                            : Rect.fromLTWH(
                                0,
                                safe.top,
                                screen.width,
                                screen.height - safe.top - safe.bottom,
                              );
                        final minTop = boardRect.top.clamp(
                          safe.top + 8,
                          screen.height,
                        );
                        final maxTop = (boardRect.bottom - height).clamp(
                          minTop,
                          screen.height - safe.bottom - height,
                        );
                        return ValueListenableBuilder<Offset>(
                          valueListenable: _feedbackPointer,
                          child: Semantics(
                            label: 'Dragging ${task.title}',
                            child: Material(
                              color: Colors.transparent,
                              elevation: 12,
                              shadowColor: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: .24),
                              borderRadius: BorderRadius.circular(16),
                              child: SizedBox(
                                key: Key('drag-feedback-${task.id}'),
                                width: width,
                                child: TweenAnimationBuilder<double>(
                                  tween: Tween(begin: 1, end: 1.03),
                                  duration:
                                      MediaQuery.disableAnimationsOf(context)
                                      ? Duration.zero
                                      : const Duration(milliseconds: 140),
                                  curve: Curves.easeOutCubic,
                                  builder: (context, scale, child) =>
                                      Transform.rotate(
                                        angle:
                                            MediaQuery.disableAnimationsOf(
                                              context,
                                            )
                                            ? 0
                                            : .012 * (scale - 1) / .03,
                                        child: Transform.scale(
                                          scale: scale,
                                          child: child,
                                        ),
                                      ),
                                  child: KanbanTaskCard(
                                    task: task,
                                    onTap: () {},
                                    onAction: (_) {},
                                  ),
                                ),
                              ),
                            ),
                          ),
                          builder: (context, pointer, child) {
                            final left = (pointer.dx - width / 2).clamp(
                              8.0,
                              screen.width - width - 8.0,
                            );
                            final top = (pointer.dy - height / 2).clamp(
                              minTop,
                              maxTop,
                            );
                            return Transform.translate(
                              offset: Offset(
                                left - pointer.dx,
                                top - pointer.dy,
                              ),
                              child: child,
                            );
                          },
                        );
                      },
                    ),
                    child: Stack(
                      children: [
                        AnimatedOpacity(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 180),
                          opacity: widget.draggedTaskId == task.id ? .22 : 1,
                          child: _CardMotion(
                            active: widget.accentTaskIds.contains(task.id),
                            completed: task.status == KanbanStatus.completed,
                            child: KanbanTaskCard(
                              task: task,
                              onTap: widget.onTaskTap == null
                                  ? null
                                  : () => widget.onTaskTap!(task),
                              onAction: widget.onTaskAction == null
                                  ? null
                                  : (action) =>
                                        widget.onTaskAction!(task, action),
                            ),
                          ),
                        ),
                        if (widget.draggedTaskId == task.id)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: Container(
                                key: Key('drag-origin-${task.id}'),
                                margin: const EdgeInsets.only(bottom: 12),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: KanbanColors.status(
                                    widget.status,
                                  ).withValues(alpha: .06),
                                  border: Border.all(
                                    color: KanbanColors.status(
                                      widget.status,
                                    ).withValues(alpha: .55),
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text(
                                  'Moving ${task.title}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (task.id != widget.draggedTaskId) {
        insertionIndex++;
        addSlot();
      }
    }

    return DragTarget<String>(
      onMove: (details) =>
          widget.onHover(widget.status, _insertionIndex(details.offset)),
      onLeave: (_) => widget.onLeave(widget.status),
      onAcceptWithDetails: (details) => widget.onDrop(
        details.data,
        widget.status,
        widget.hoverStatus == widget.status && widget.hoverIndex != null
            ? widget.hoverIndex!
            : _insertionIndex(details.offset),
        _placeholderRect(),
      ),
      builder: (context, candidates, rejected) => AnimatedContainer(
        key: Key('column-${widget.status.value}'),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
        curve: Curves.easeInOutCubic,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            KanbanColors.status(
              widget.status,
            ).withValues(alpha: hovering ? .13 : .07),
            Theme.of(context).colorScheme.surface,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: KanbanColors.status(
              widget.status,
            ).withValues(alpha: hovering ? .65 : .22),
            width: hovering ? 1.5 : 1,
          ),
          boxShadow: hovering
              ? [
                  BoxShadow(
                    color: KanbanColors.status(
                      widget.status,
                    ).withValues(alpha: .10),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 7,
                  height: 28,
                  decoration: BoxDecoration(
                    color: KanbanColors.status(widget.status),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    style: Theme.of(context).textTheme.titleLarge!.copyWith(
                      fontWeight: hovering ? FontWeight.w700 : FontWeight.w600,
                      color: hovering
                          ? KanbanColors.status(widget.status)
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                    child: Text(widget.status.label),
                  ),
                ),
                AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 200),
                  child: Badge(
                    key: ValueKey(widget.tasks.length),
                    backgroundColor: KanbanColors.status(
                      widget.status,
                    ).withValues(alpha: .13),
                    textColor: Theme.of(context).colorScheme.onSurface,
                    label: Text('${widget.tasks.length}'),
                    child: const SizedBox(width: 24, height: 24),
                  ),
                ),
              ],
            ),
            reduced
                ? destinationHint
                : AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOutCubic,
                    child: destinationHint,
                  ),
            const SizedBox(height: 14),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        final pointer = widget.dragPointer.value;
                        if (hovering && pointer != null) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            final currentPointer = widget.dragPointer.value;
                            if (mounted && currentPointer != null) {
                              widget.onHover(
                                widget.status,
                                _insertionIndex(currentPointer),
                              );
                            }
                          });
                        }
                        return false;
                      },
                      child: ListView.builder(
                        key: widget.viewportKey,
                        controller: widget.scrollController,
                        padding: const EdgeInsets.only(bottom: 96),
                        itemCount: widget.tasks.isEmpty ? 1 : items.length,
                        itemBuilder: (context, index) => widget.tasks.isEmpty
                            ? SizedBox(
                                height: hovering
                                    ? (constraints.maxHeight - 96).clamp(
                                        160,
                                        double.infinity,
                                      )
                                    : 160,
                                child: Center(
                                  child: hovering
                                      ? _placeholder()
                                      : Text(
                                          'No ${widget.status.label.toLowerCase()} tasks',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                ),
                              )
                            : items[index](),
                      ),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() => KeyedSubtree(
    key: _placeholderKey,
    child: Container(
      key: Key('drop-placeholder-${widget.status.value}'),
      height: ((widget.draggedCardHeight ?? 76) - 12).clamp(
        64,
        double.infinity,
      ),
      margin: const EdgeInsets.only(bottom: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: KanbanColors.status(widget.status).withValues(alpha: .12),
        border: Border.all(color: KanbanColors.status(widget.status), width: 2),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        widget.tasks.isEmpty
            ? 'Drop task here'
            : 'Move to ${widget.status.label}',
      ),
    ),
  );
}

class _CardMotion extends StatefulWidget {
  const _CardMotion({
    required this.active,
    required this.completed,
    required this.child,
  });

  final bool active;
  final bool completed;
  final Widget child;

  @override
  State<_CardMotion> createState() => _CardMotionState();
}

class _CardMotionState extends State<_CardMotion> {
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    if (widget.active) _enter();
  }

  @override
  void didUpdateWidget(covariant _CardMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _enter();
  }

  void _enter() {
    _visible = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);
    return AnimatedSlide(
      duration: duration,
      curve: Curves.easeOutCubic,
      offset: _visible ? Offset.zero : const Offset(0, .06),
      child: AnimatedOpacity(
        duration: duration,
        curve: Curves.easeOutCubic,
        opacity: _visible ? 1 : 0,
        child: AnimatedScale(
          duration: duration,
          curve: Curves.easeOutBack,
          scale: _visible ? 1 : .985,
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: widget.active && widget.completed
                    ? KanbanColors.status(KanbanStatus.completed)
                    : Colors.transparent,
                width: 2,
              ),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                widget.child,
                if (widget.active && widget.completed)
                  Positioned(
                    top: -8,
                    right: 8,
                    child: IgnorePointer(
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: 1),
                        duration: duration,
                        curve: Curves.easeOutBack,
                        builder: (context, value, child) => Opacity(
                          opacity: value.clamp(0, 1),
                          child: Transform.scale(scale: value, child: child),
                        ),
                        child: CircleAvatar(
                          radius: 13,
                          backgroundColor: KanbanColors.status(
                            KanbanStatus.completed,
                          ),
                          child: const Icon(
                            Icons.check,
                            size: 17,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
