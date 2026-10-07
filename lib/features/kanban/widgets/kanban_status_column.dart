import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
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
    required this.draggedTaskId,
    required this.draggedCardHeight,
    required this.accentTaskIds,
    required this.departingTaskId,
    required this.dragPosition,
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
  });

  final KanbanStatus status;
  final List<KanbanTask> tasks;
  final ScrollController scrollController;
  final GlobalKey viewportKey;
  final String? draggedTaskId;
  final double? draggedCardHeight;
  final Set<String> accentTaskIds;
  final String? departingTaskId;
  final Offset? dragPosition;
  final KanbanStatus? hoverStatus;
  final int? hoverIndex;
  final ValueChanged<KanbanTask> onTaskTap;
  final void Function(KanbanTask, TaskCardAction) onTaskAction;
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

  Rect? _placeholderRect() {
    final box = _placeholderKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  bool get wantKeepAlive => true;

  int _insertionIndex(Offset globalPosition) {
    var index = 0;
    for (final task in widget.tasks) {
      if (task.id == widget.draggedTaskId) continue;
      final box = _cardKeys[task.id]?.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        var midpoint = box.localToGlobal(Offset(0, box.size.height / 2)).dy;
        if (widget.hoverStatus == widget.status &&
            widget.hoverIndex != null &&
            widget.hoverIndex! <= index) {
          midpoint -= (widget.draggedCardHeight ?? 76) + 12;
        }
        if (globalPosition.dy < midpoint) return index;
      }
      index++;
    }
    return index;
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
                color: AppColors.status(widget.status),
              ),
            ),
          )
        : const SizedBox(width: double.infinity);
    final items = <Widget Function()>[];
    var insertionIndex = 0;
    void addSlot() {
      final slotIndex = insertionIndex;
      items.add(() {
        final child = hovering && widget.hoverIndex == slotIndex
            ? _placeholder()
            : const SizedBox(width: double.infinity);
        final key = ValueKey('slot-${widget.status.value}-$slotIndex');
        return reduced
            ? KeyedSubtree(key: key, child: child)
            : AnimatedSize(
                key: key,
                duration: const Duration(milliseconds: 260),
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
                builder: (context, constraints) => LongPressDraggable<String>(
                  data: task.id,
                  dragAnchorStrategy: pointerDragAnchorStrategy,
                  onDragStarted: () {
                    final box = _cardKeys[task.id]?.currentContext
                        ?.findRenderObject();
                    widget.onDragStart(
                      task,
                      box is RenderBox
                          ? box.localToGlobal(Offset.zero) & box.size
                          : Rect.fromLTWH(0, 0, constraints.maxWidth, 76),
                    );
                  },
                  onDragUpdate: (details) =>
                      widget.onDragUpdate(details.globalPosition),
                  onDragEnd: widget.onDragEnd,
                  feedback: Builder(
                    builder: (context) {
                      final source = _cardKeys[task.id]?.currentContext
                          ?.findRenderObject();
                      final height = source is RenderBox
                          ? source.size.height
                          : 80.0;
                      return Transform.translate(
                        offset: Offset(-constraints.maxWidth / 2, -height / 2),
                        child: Material(
                          color: Colors.transparent,
                          elevation: 12,
                          shadowColor: Colors.black45,
                          borderRadius: BorderRadius.circular(16),
                          child: SizedBox(
                            key: Key('drag-feedback-${task.id}'),
                            width: constraints.maxWidth,
                            child: TweenAnimationBuilder<double>(
                              tween: Tween(begin: 1, end: 1.03),
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 140),
                              curve: Curves.easeOutCubic,
                              builder: (context, scale, child) =>
                                  Transform.rotate(
                                    angle:
                                        MediaQuery.disableAnimationsOf(context)
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
                            onTap: () => widget.onTaskTap(task),
                            onAction: (action) =>
                                widget.onTaskAction(task, action),
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
                                color: AppColors.status(
                                  widget.status,
                                ).withValues(alpha: .06),
                                border: Border.all(
                                  color: AppColors.status(
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
      );
      if (task.id != widget.draggedTaskId) {
        insertionIndex++;
        addSlot();
      }
    }

    return DragTarget<String>(
      onMove: (details) => widget.onHover(
        widget.status,
        _insertionIndex(widget.dragPosition ?? details.offset),
      ),
      onLeave: (_) => widget.onLeave(widget.status),
      onAcceptWithDetails: (details) => widget.onDrop(
        details.data,
        widget.status,
        _insertionIndex(widget.dragPosition ?? details.offset),
        _placeholderRect(),
      ),
      builder: (context, candidates, rejected) => AnimatedContainer(
        key: Key('column-${widget.status.value}'),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
        curve: Curves.easeInOutCubic,
        margin: const EdgeInsets.only(left: 16, right: 4, bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        decoration: BoxDecoration(
          color: hovering
              ? AppColors.status(widget.status).withValues(alpha: .12)
              : const Color(0xFFF0F2F7),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: hovering
                ? AppColors.status(widget.status)
                : const Color(0xFFE3E6EE),
            width: hovering ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 7,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppColors.status(widget.status),
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
                      fontWeight: hovering ? FontWeight.w800 : FontWeight.w700,
                      color: hovering
                          ? AppColors.status(widget.status)
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
              child: ListView.builder(
                key: widget.viewportKey,
                controller: widget.scrollController,
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: widget.tasks.isEmpty && !hovering ? 1 : items.length,
                itemBuilder: (context, index) =>
                    widget.tasks.isEmpty && !hovering
                    ? SizedBox(
                        height: 160,
                        child: Center(
                          child: Text(
                            'No ${widget.status.label.toLowerCase()} tasks',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : items[index](),
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
      height: widget.draggedCardHeight ?? 76,
      margin: const EdgeInsets.only(bottom: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.status(widget.status).withValues(alpha: .12),
        border: Border.all(color: AppColors.status(widget.status), width: 2),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text('Move to ${widget.status.label}'),
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
                    ? AppColors.status(KanbanStatus.completed)
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
                          backgroundColor: AppColors.status(
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
