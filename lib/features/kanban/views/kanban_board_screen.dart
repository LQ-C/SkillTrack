import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../../app/router/app_router.dart';
import '../../ai_task_generation/view_models/append_task_generation_view_model.dart';
import '../utils/kanban_colors.dart';
import '../models/kanban_filter.dart';
import '../models/kanban_sort.dart';
import '../models/kanban_status.dart';
import '../models/kanban_task.dart';
import '../viewmodels/kanban_view_model.dart';
import '../widgets/board_empty_state.dart';
import '../widgets/board_error_view.dart';
import '../widgets/board_loading_view.dart';
import '../widgets/filter_sheet.dart';
import '../widgets/kanban_status_column.dart';
import '../widgets/kanban_task_card.dart';
import '../widgets/project_progress_card.dart';
import '../widgets/sort_sheet.dart';
import '../widgets/tag_management_sheet.dart';
import '../widgets/task_tag_chip.dart';

class KanbanBoardScreen extends StatefulWidget {
  const KanbanBoardScreen({
    super.key,
    required this.viewModel,
    required this.projectId,
    required this.boardId,
    required this.projectName,
    this.projectStatus = 'active',
    this.appendViewModel,
  }) : assert(boardId != '');
  final KanbanViewModel viewModel;
  final String projectId;
  final String boardId;
  final String projectName;
  final String projectStatus;
  final AppendTaskGenerationViewModel? appendViewModel;
  @override
  State<KanbanBoardScreen> createState() => _KanbanBoardScreenState();
}

class _KanbanBoardScreenState extends State<KanbanBoardScreen>
    with TickerProviderStateMixin {
  static const _columnGap = 12.0;
  final _search = TextEditingController();
  final _overviewKey = GlobalKey();
  final _listKeys = List.generate(
    KanbanStatus.values.length,
    (_) => GlobalKey(),
  );
  final _listControllers = List.generate(
    KanbanStatus.values.length,
    (_) => ScrollController(),
  );
  late final AnimationController _settleController;
  late final AnimationController _boardController;
  Animation<double> _boardScale = const AlwaysStoppedAnimation(1);
  Animation<double> _boardFocus = const AlwaysStoppedAnimation(0);
  double _swipeDistance = 0;
  OverlayEntry? _settleEntry;
  KanbanTask? _dragSnapshot;
  Rect? _dragOriginRect;
  Rect? _dropRect;
  Timer? _edgeTimer;
  Timer? _verticalTimer;
  Timer? _accentTimer;
  Timer? _departureTimer;
  Set<String> _accentTaskIds = {};
  KanbanTask? _departingTask;
  bool _departureStarted = false;
  String? _draggedTaskId;
  double? _draggedCardHeight;
  KanbanStatus? _hoverStatus;
  int? _hoverIndex;
  Offset? _dragPosition;
  final ValueNotifier<Offset?> _dragPointer = ValueNotifier(null);
  int _pageIndex = 0;
  int _dragStartIndex = 0;
  int _edgeDirection = 0;
  bool _pageAnimating = false;
  bool _showSearch = false;
  String? _openingRouteId;
  bool _isShowingOverlay = false;
  bool get _navigationBusy => _openingRouteId != null || _isShowingOverlay;
  @override
  void initState() {
    super.initState();
    _settleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _boardController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 290),
    );
    widget.viewModel.addListener(_onModelChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.viewModel.initialize(widget.boardId);
    });
  }

  @override
  void dispose() {
    widget.viewModel.removeListener(_onModelChanged);
    _search.dispose();
    _dragPointer.dispose();
    _edgeTimer?.cancel();
    _verticalTimer?.cancel();
    _accentTimer?.cancel();
    _departureTimer?.cancel();
    _settleController.stop();
    final settleEntry = _settleEntry;
    _settleEntry = null;
    settleEntry?.remove();
    settleEntry?.dispose();
    _settleController.dispose();
    _boardController.dispose();
    for (final controller in _listControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _animateBoard(int index, double scale) async {
    if (!mounted) return;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final currentScale = _boardScale.value;
    final currentFocus = _boardFocus.value;
    _boardController.stop();
    if (reduced) {
      _boardScale = AlwaysStoppedAnimation(scale);
      _boardFocus = AlwaysStoppedAnimation(index.toDouble());
      setState(() {});
      return;
    }
    final curve = _boardController.drive(
      CurveTween(curve: Curves.easeInOutCubic),
    );
    _boardScale = Tween(begin: currentScale, end: scale).animate(curve);
    _boardFocus = Tween(
      begin: currentFocus,
      end: index.toDouble(),
    ).animate(curve);
    try {
      await _boardController.forward(from: 0).orCancel;
    } on TickerCanceled {
      // A newer drag or page selection superseded this transition.
    }
  }

  void _onSwipeEnd(DragEndDetails details) {
    if (_draggedTaskId != null) return;
    final velocity = details.primaryVelocity ?? 0;
    final direction = velocity.abs() > 300
        ? (velocity < 0 ? 1 : -1)
        : _swipeDistance.abs() > 60
        ? (_swipeDistance < 0 ? 1 : -1)
        : 0;
    _swipeDistance = 0;
    final target = (_pageIndex + direction).clamp(
      0,
      KanbanStatus.values.length - 1,
    );
    if (target == _pageIndex) return;
    setState(() => _pageIndex = target);
    _animateBoard(target, 1);
  }

  void _startTaskDrag(KanbanTask task, Rect origin) {
    _edgeTimer?.cancel();
    _verticalTimer?.cancel();
    _dragSnapshot = task;
    _dragOriginRect = origin;
    _dropRect = null;
    _dragStartIndex = _pageIndex;
    _dragPosition = origin.center;
    _dragPointer.value = origin.center;
    HapticFeedback.lightImpact();
    setState(() {
      _draggedTaskId = task.id;
      _draggedCardHeight = origin.height;
      _hoverStatus = null;
      _hoverIndex = null;
    });
    _animateBoard(_pageIndex, .90);
  }

  void _updateTaskDrag(Offset position) {
    _dragPosition = position;
    _dragPointer.value = position;
    _checkEdge();
    _updateVerticalScroll();
  }

  void _checkEdge() {
    if (_draggedTaskId == null || _pageAnimating || _dragPosition == null) {
      _edgeTimer?.cancel();
      return;
    }
    final box = _overviewKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(_dragPosition!);
    final direction = local.dx < 68
        ? -1
        : local.dx > box.size.width - 68
        ? 1
        : 0;
    final allowed =
        local.dy >= 0 &&
        local.dy <= box.size.height &&
        _pageIndex + direction >= 0 &&
        _pageIndex + direction < KanbanStatus.values.length;
    final next = allowed ? direction : 0;
    if (next == _edgeDirection && (_edgeTimer?.isActive ?? false)) return;
    _edgeTimer?.cancel();
    if (_edgeDirection != next) {
      setState(() => _edgeDirection = next);
    }
    if (next == 0) return;
    _edgeTimer = Timer(const Duration(milliseconds: 420), () async {
      if (!mounted || _draggedTaskId == null || _pageAnimating) return;
      final target = _pageIndex + next;
      if (target < 0 || target >= KanbanStatus.values.length) return;
      _pageAnimating = true;
      setState(() => _edgeDirection = 0);
      setState(() => _pageIndex = target);
      await _animateBoard(target, .90);
      if (!mounted) return;
      _pageAnimating = false;
      if (_draggedTaskId != null) {
        final status = KanbanStatus.values[target];
        _hoverTask(status, widget.viewModel.visibleTasks(status).length);
        _checkEdge();
      }
    });
  }

  void _updateVerticalScroll() {
    if (_draggedTaskId == null || _dragPosition == null) return;
    if (_edgeDirection != 0) {
      _verticalTimer?.cancel();
      _verticalTimer = null;
      return;
    }
    final box = _listKeys[_pageIndex].currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(_dragPosition!);
    final inZone =
        local.dx >= 0 &&
        local.dx <= box.size.width &&
        (local.dy < 56 || local.dy > box.size.height - 56);
    if (!inZone) {
      _verticalTimer?.cancel();
      _verticalTimer = null;
    } else {
      _verticalTimer ??= Timer.periodic(
        const Duration(milliseconds: 32),
        (_) => _autoScrollVertical(),
      );
    }
  }

  void _autoScrollVertical() {
    if (_draggedTaskId == null || _dragPosition == null) return;
    final key = _listKeys[_pageIndex];
    final box = key.currentContext?.findRenderObject();
    final controller = _listControllers[_pageIndex];
    if (box is! RenderBox || !box.hasSize || !controller.hasClients) return;
    final local = box.globalToLocal(_dragPosition!);
    if (local.dx < 0 || local.dx > box.size.width) return;
    final delta = local.dy < 56
        ? -(3 + (56 - local.dy).clamp(0, 56) * .16)
        : local.dy > box.size.height - 56
        ? 3 + (local.dy - (box.size.height - 56)).clamp(0, 56) * .16
        : 0.0;
    if (delta == 0) return;
    final next = (controller.offset + delta).clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );
    if (next != controller.offset) controller.jumpTo(next);
  }

  void _hoverTask(KanbanStatus status, int index) {
    if (_draggedTaskId == null ||
        (_hoverStatus == status && _hoverIndex == index)) {
      return;
    }
    setState(() {
      _hoverStatus = status;
      _hoverIndex = index;
    });
  }

  void _leaveTask(KanbanStatus status) {
    if (_hoverStatus != status) return;
    setState(() {
      _hoverStatus = null;
      _hoverIndex = null;
    });
  }

  void _endTaskDrag() {
    _edgeTimer?.cancel();
    _verticalTimer?.cancel();
    _dragPosition = null;
    _dragPointer.value = null;
    if (!mounted || _draggedTaskId == null) return;
    setState(() {
      _draggedTaskId = null;
      _draggedCardHeight = null;
      _hoverStatus = null;
      _hoverIndex = null;
      _edgeDirection = 0;
    });
    _animateBoard(_pageIndex, 1);
  }

  Widget _edgeGuide(BuildContext context, int direction) {
    final target = _pageIndex + direction;
    if (_draggedTaskId == null) {
      return const SizedBox.shrink();
    }
    final available = target >= 0 && target < KanbanStatus.values.length;
    final color = available
        ? KanbanColors.status(KanbanStatus.values[target])
        : Theme.of(context).disabledColor;
    final active = _edgeDirection == direction;
    return Positioned(
      key: Key(direction < 0 ? 'drag-edge-left' : 'drag-edge-right'),
      top: 0,
      bottom: 0,
      left: direction < 0 ? 4 : null,
      right: direction > 0 ? 4 : null,
      width: 64,
      child: IgnorePointer(
        child: Center(
          child: Semantics(
            label: available
                ? '${KanbanStatus.values[target].label}, drop target'
                : 'No ${direction < 0 ? 'previous' : 'next'} status available',
            child: Opacity(
              opacity: available ? 1 : .38,
              child: SizedBox(
                key: Key(
                  direction < 0 ? 'drag-arrow-left' : 'drag-arrow-right',
                ),
                width: 64,
                height: 72,
                child: AnimatedContainer(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surface.withValues(alpha: .94),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: color.withValues(alpha: active ? 1 : .55),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: .08),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Icon(
                        direction < 0
                            ? Icons.chevron_left
                            : Icons.chevron_right,
                        size: 22,
                        color: color,
                      ),
                      const SizedBox(height: 3),
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            available ? KanbanStatus.values[target].label : '—',
                            maxLines: 1,
                            softWrap: false,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: color,
                                  fontWeight: FontWeight.w700,
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
  }

  Widget _boardTrack(double columnWidth) => SizedBox(
    key: const Key('kanban-board-track'),
    width:
        columnWidth * KanbanStatus.values.length +
        _columnGap * (KanbanStatus.values.length - 1),
    child: ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Row(
        children: [
          for (var index = 0; index < KanbanStatus.values.length; index++) ...[
            if (index > 0)
              SizedBox(key: Key('column-gap-${index - 1}'), width: _columnGap),
            SizedBox(
              width: columnWidth,
              child: KanbanStatusColumn(
                dragEnabled:
                    widget.viewModel.activeSort == KanbanSort.custom &&
                    !widget.viewModel.isSaving,
                key: ValueKey(KanbanStatus.values[index]),
                status: KanbanStatus.values[index],
                tasks: _columnTasks(KanbanStatus.values[index]),
                scrollController: _listControllers[index],
                viewportKey: _listKeys[index],
                boardViewportKey: _overviewKey,
                draggedTaskId: _draggedTaskId,
                draggedCardHeight: _draggedCardHeight,
                accentTaskIds: _accentTaskIds,
                departingTaskId: _departureStarted ? _departingTask?.id : null,
                dragPointer: _dragPointer,
                hoverStatus: _hoverStatus,
                hoverIndex: _hoverIndex,
                onTaskTap: _navigationBusy ? null : _openDetails,
                onTaskAction: _navigationBusy || widget.viewModel.isSaving
                    ? null
                    : _taskAction,
                onDragStart: _startTaskDrag,
                onDragUpdate: _updateTaskDrag,
                onDragEnd: _finishTaskDrag,
                onHover: _hoverTask,
                onLeave: _leaveTask,
                onDrop: _dropTask,
              ),
            ),
          ],
        ],
      ),
    ),
  );

  void _finishTaskDrag(DraggableDetails details) {
    if (!mounted) return;
    final task = _dragSnapshot;
    final origin = _dragOriginRect;
    final destination = details.wasAccepted ? _dropRect : origin;
    final pointer = _dragPosition ?? details.offset;
    if (!details.wasAccepted) _pageIndex = _dragStartIndex;
    _endTaskDrag();
    _dragSnapshot = null;
    _dragOriginRect = null;
    _dropRect = null;
    if (task == null || origin == null) return;
    _animateTaskSettlement(
      task,
      origin,
      pointer,
      destination?.center ?? pointer,
    );
  }

  void _animateTaskSettlement(
    KanbanTask task,
    Rect origin,
    Offset fromCenter,
    Offset toCenter,
  ) {
    if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
    _settleController.stop();
    _settleEntry?.remove();
    _settleEntry?.dispose();
    _settleController.reset();
    final screen = MediaQuery.sizeOf(context);
    final width = origin.width.clamp(0, screen.width - 144).toDouble();
    final board = _overviewKey.currentContext?.findRenderObject();
    final boardRect = board is RenderBox && board.hasSize
        ? board.localToGlobal(Offset.zero) & board.size
        : Rect.fromLTWH(0, 0, screen.width, screen.height);
    Offset positionFor(Offset center) => Offset(
      (center.dx - width / 2).clamp(8, screen.width - width - 8),
      (center.dy - origin.height / 2).clamp(
        boardRect.top,
        boardRect.bottom - origin.height,
      ),
    );
    final start = positionFor(fromCenter);
    final target = positionFor(toCenter);
    final entry = OverlayEntry(
      builder: (overlayContext) => AnimatedBuilder(
        animation: _settleController,
        builder: (overlayContext, child) {
          final progress = Curves.easeInOutCubic.transform(
            _settleController.value,
          );
          final position = Offset.lerp(start, target, progress)!;
          return Positioned(
            key: const Key('drag-settle-overlay'),
            left: position.dx,
            top: position.dy,
            width: width,
            child: IgnorePointer(
              child: Opacity(
                opacity: 1 - progress,
                child: Transform.scale(
                  scale: 1.03 - .03 * progress,
                  child: Material(
                    color: Colors.transparent,
                    elevation: 8 * (1 - progress),
                    shadowColor: Colors.black38,
                    child: KanbanTaskCard(
                      task: task,
                      onTap: () {},
                      onAction: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    _settleEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
    _settleController.forward().whenComplete(() {
      if (_settleEntry == entry) {
        entry.remove();
        entry.dispose();
        _settleEntry = null;
      }
    });
  }

  Future<void> _dropTask(
    String id,
    KanbanStatus status,
    int index,
    Rect? target,
  ) async {
    if (_draggedTaskId != id) return;
    _dropRect = target;
    final draggedTask = _dragSnapshot;
    final origin = _dragOriginRect;
    final failedFrom = target?.center ?? _dragPosition;
    final previous = widget.viewModel.allTasks
        .where((task) => task.id == id)
        .firstOrNull
        ?.status;
    setState(() => _pageIndex = status.index);
    _endTaskDrag();
    HapticFeedback.selectionClick();
    _accentTasks({id});
    final visible = widget.viewModel
        .visibleTasks(status)
        .where((task) => task.id != id)
        .toList();
    final ordered = widget.viewModel
        .tasks(status)
        .where((task) => task.id != id)
        .toList();
    final slot = index.clamp(0, visible.length);
    final anchor = slot < visible.length ? visible[slot].id : null;
    final insertion = anchor != null
        ? ordered.indexWhere((task) => task.id == anchor)
        : visible.isEmpty
        ? ordered.length
        : ordered.indexWhere((task) => task.id == visible.last.id) + 1;
    final moved = await widget.viewModel.moveTask(
      id,
      status,
      newIndex: insertion,
    );
    if (!moved && mounted) {
      setState(() => _pageIndex = _dragStartIndex);
      _animateBoard(_pageIndex, 1);
      if (draggedTask != null && origin != null && failedFrom != null) {
        _animateTaskSettlement(draggedTask, origin, failedFrom, origin.center);
      }
    }
    if (moved && mounted && previous != status) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Task moved to ${status.label}.',
        TextDirection.ltr,
      );
    }
  }

  void _onModelChanged() {
    final feedback = widget.viewModel.feedbackMessage;
    final error = widget.viewModel.errorMessage;
    if (feedback == null &&
        (error == null || widget.viewModel.allTasks.isEmpty)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (feedback != null) {
        final undo =
            feedback == 'Task archived' ||
            feedback == 'Task marked as completed' ||
            feedback == 'Task moved' ||
            feedback == 'Task reopened' ||
            feedback == 'Board archived';
        messenger.showSnackBar(
          SnackBar(
            content: Semantics(liveRegion: true, child: Text(feedback)),
            action: undo
                ? SnackBarAction(
                    label: 'Undo',
                    onPressed: feedback == 'Board archived'
                        ? widget.viewModel.restoreArchivedBoard
                        : widget.viewModel.undoLastAction,
                  )
                : null,
          ),
        );
        widget.viewModel.clearFeedbackMessage();
      } else if (error != null) {
        messenger.showSnackBar(SnackBar(content: Text(error)));
        widget.viewModel.clearError();
      }
    });
  }

  Future<void> _openForm([KanbanTask? task]) async {
    if (_navigationBusy) return;
    setState(() => _openingRouteId = task?.id ?? 'create');
    try {
      final changed = await AppRouter.createTask(
        context,
        CreateTaskRouteArgs(
          projectId: widget.projectId,
          boardId: widget.boardId,
          projectName: widget.projectName,
          taskId: task?.id,
        ),
      );
      if (changed == true && mounted) await _refreshWithEntrance();
    } finally {
      if (mounted) setState(() => _openingRouteId = null);
    }
  }

  Future<void> _openDetails(KanbanTask task) async {
    if (_navigationBusy) return;
    setState(() => _openingRouteId = task.id);
    try {
      await AppRouter.taskDetails(
        context,
        TaskDetailsRouteArgs(
          projectId: widget.projectId,
          boardId: widget.boardId,
          projectName: widget.projectName,
          taskId: task.id,
        ),
      );
      if (mounted) await widget.viewModel.refresh(showLoading: false);
    } finally {
      if (mounted) setState(() => _openingRouteId = null);
    }
  }

  Future<void> _openArchivedTasks() async {
    if (_navigationBusy) return;
    setState(() => _openingRouteId = 'archived');
    try {
      await AppRouter.archivedTasks(
        context,
        BoardRouteArgs(
          projectId: widget.projectId,
          boardId: widget.boardId,
          projectName: widget.projectName,
        ),
      );
      if (mounted) await _refreshWithEntrance();
    } finally {
      if (mounted) setState(() => _openingRouteId = null);
    }
  }

  Future<void> _generateMoreTasks() async {
    if (_navigationBusy) return;
    setState(() => _openingRouteId = 'generate');
    try {
      final append = widget.appendViewModel;
      if (append == null || append.isGeneratingTasks) return;
      FocusScope.of(context).unfocus();
      final request = append.generateMoreTasks();
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: Center(
            child: Card(
              margin: const EdgeInsets.all(28),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Text(
                      'Generating additional tasks…',
                      style: Theme.of(dialogContext).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final drafts = await request;
      if (!mounted) return;
      // This context belongs to the board beneath the busy dialog.
      Navigator.of(context).pop();
      if (drafts == null) {
        final message = append.errorMessage;
        if (message != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
        return;
      }
      final added = await AppRouter.additionalTaskPreview(context, append);
      if (!mounted || added != true) return;
      await _refreshWithEntrance();
      if (!mounted) return;
      final feedback = append.feedbackMessage;
      if (feedback != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(feedback)));
        append.clearFeedback();
      }
    } finally {
      if (mounted) setState(() => _openingRouteId = null);
    }
  }

  Future<void> _refreshWithEntrance() async {
    final known = {for (final task in widget.viewModel.allTasks) task.id};
    await widget.viewModel.refresh(showLoading: false);
    if (!mounted) return;
    final added = widget.viewModel.allTasks
        .where((task) => !known.contains(task.id))
        .map((task) => task.id)
        .toSet();
    if (added.isNotEmpty) _accentTasks(added);
  }

  void _accentTasks(Set<String> ids) {
    _accentTimer?.cancel();
    setState(() => _accentTaskIds = ids);
    _accentTimer = Timer(
      MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 650),
      () {
        if (mounted) setState(() => _accentTaskIds = {});
      },
    );
  }

  Future<void> _showSheet(Widget sheet) async {
    if (_navigationBusy) return;
    setState(() => _isShowingOverlay = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => FractionallySizedBox(heightFactor: .76, child: sheet),
      );
    } finally {
      if (mounted) setState(() => _isShowingOverlay = false);
    }
  }

  Future<void> _showProgress() async {
    if (_navigationBusy) return;
    setState(() => _isShowingOverlay = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        builder: (context) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Project summary',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                _metric('Total tasks', widget.viewModel.totalTaskCount),
                _metric('Completed tasks', widget.viewModel.completedTaskCount),
                _metric('In progress', widget.viewModel.inProgressTaskCount),
                _metric('Overdue tasks', widget.viewModel.overdueTaskCount),
                _metric('Due soon', widget.viewModel.dueSoonTaskCount),
              ],
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isShowingOverlay = false);
    }
  }

  Widget _metric(String label, int value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text('$value'),
      ],
    ),
  );

  Future<void> _confirmArchive(KanbanTask task) async {
    if (_navigationBusy || widget.viewModel.isSaving) return;
    setState(() => _isShowingOverlay = true);
    try {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Archive task?'),
          content: const Text(
            'This task will be removed from the active board.',
          ),
          actions: [
            TextButton(
              onPressed: () => AppRouter.back(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => AppRouter.back(dialogContext, true),
              child: const Text('Archive'),
            ),
          ],
        ),
      );
      if (confirm == true && mounted) {
        await _removeWithMotion(
          task,
          () => widget.viewModel.archiveTask(task.id),
          optimistic: true,
        );
      }
    } finally {
      if (mounted) setState(() => _isShowingOverlay = false);
    }
  }

  Future<void> _confirmDelete(KanbanTask task) async {
    if (_navigationBusy || widget.viewModel.isSaving) return;
    setState(() => _isShowingOverlay = true);
    try {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete task permanently?'),
          content: const Text(
            'The task and its related data cannot be recovered.',
          ),
          actions: [
            TextButton(
              onPressed: () => AppRouter.back(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => AppRouter.back(dialogContext, true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('Delete permanently'),
            ),
          ],
        ),
      );
      if (confirm == true && mounted) {
        await _removeWithMotion(
          task,
          () => widget.viewModel.deleteTask(task.id),
          optimistic: false,
        );
      }
    } finally {
      if (mounted) setState(() => _isShowingOverlay = false);
    }
  }

  Future<void> _removeWithMotion(
    KanbanTask task,
    Future<bool> Function() operation, {
    required bool optimistic,
  }) async {
    setState(() {
      _departingTask = task;
      _departureStarted = optimistic;
    });
    final ok = await operation();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _departingTask = null;
        _departureStarted = false;
      });
      return;
    }
    setState(() => _departureStarted = true);
    _departureTimer?.cancel();
    _departureTimer = Timer(
      MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      () {
        if (mounted) {
          setState(() {
            _departingTask = null;
            _departureStarted = false;
          });
        }
      },
    );
  }

  Future<void> _confirmArchiveBoard() async {
    if (_navigationBusy || widget.viewModel.isSaving) return;
    setState(() => _isShowingOverlay = true);
    try {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Archive board?'),
          content: const Text(
            'This board will be hidden from active projects.',
          ),
          actions: [
            TextButton(
              onPressed: () => AppRouter.back(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => AppRouter.back(dialogContext, true),
              child: const Text('Archive'),
            ),
          ],
        ),
      );
      if (confirm == true && mounted) await widget.viewModel.archiveBoard();
    } finally {
      if (mounted) setState(() => _isShowingOverlay = false);
    }
  }

  Future<void> _moveFromMenu(String taskId, KanbanStatus status) async {
    _accentTasks({taskId});
    final moved = await widget.viewModel.moveTask(taskId, status);
    if (moved && mounted) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Task moved to ${status.label}.',
        TextDirection.ltr,
      );
    }
  }

  void _taskAction(KanbanTask task, TaskCardAction action) {
    if (_navigationBusy || widget.viewModel.isSaving) return;
    switch (action) {
      case TaskCardAction.details:
        _openDetails(task);
        return;
      case TaskCardAction.edit:
        _openForm(task);
        return;
      case TaskCardAction.todo:
        _moveFromMenu(task.id, KanbanStatus.todo);
        return;
      case TaskCardAction.inProgress:
        _moveFromMenu(task.id, KanbanStatus.inProgress);
        return;
      case TaskCardAction.completed:
        _moveFromMenu(task.id, KanbanStatus.completed);
        return;
      case TaskCardAction.duplicate:
        widget.viewModel.duplicateTask(task);
        return;
      case TaskCardAction.archive:
        _confirmArchive(task);
        return;
      case TaskCardAction.delete:
        _confirmDelete(task);
        return;
    }
  }

  void _overflow(String value) {
    if (_navigationBusy) return;
    switch (value) {
      case 'filter':
        _showSheet(FilterSheet(viewModel: widget.viewModel));
        return;
      case 'sort':
        _showSheet(SortSheet(viewModel: widget.viewModel));
        return;
      case 'tags':
        _showSheet(TagManagementSheet(viewModel: widget.viewModel));
        return;
      case 'archived':
        _openArchivedTasks();
        return;
      case 'generate-more':
        _generateMoreTasks();
        return;
      case 'archive':
        _confirmArchiveBoard();
        return;
      default:
        return;
    }
  }

  void _removeFilter(String kind, Object value) {
    final filter = widget.viewModel.activeFilter;
    widget.viewModel.applyFilter(switch (kind) {
      'status' => filter.copyWith(
        statuses: {...filter.statuses}..remove(value),
      ),
      'priority' => filter.copyWith(
        priorities: {...filter.priorities}..remove(value),
      ),
      'tag' => filter.copyWith(tagIds: {...filter.tagIds}..remove(value)),
      'overdue' => filter.copyWith(overdueOnly: false),
      'completed' => filter.copyWith(completedOnly: false),
      'start' => filter.copyWith(clearDeadlineStart: true),
      _ => filter.copyWith(clearDeadlineEnd: true),
    });
  }

  Widget _filterChips(KanbanFilter filter) {
    final chips = <Widget>[
      for (final status in filter.statuses)
        InputChip(
          label: Text(status.label),
          onDeleted: () => _removeFilter('status', status),
        ),
      for (final priority in filter.priorities)
        InputChip(
          label: Text(priority.label),
          onDeleted: () => _removeFilter('priority', priority),
        ),
      for (final tagId in filter.tagIds) _tagFilterChip(tagId),
      if (filter.overdueOnly)
        InputChip(
          label: const Text('Overdue'),
          onDeleted: () => _removeFilter('overdue', true),
        ),
      if (filter.completedOnly)
        InputChip(
          label: const Text('Completed'),
          onDeleted: () => _removeFilter('completed', true),
        ),
      if (filter.deadlineStart != null)
        InputChip(
          label: const Text('From date'),
          onDeleted: () => _removeFilter('start', true),
        ),
      if (filter.deadlineEnd != null)
        InputChip(
          label: const Text('To date'),
          onDeleted: () => _removeFilter('end', true),
        ),
    ];
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final chip in chips)
            Padding(padding: const EdgeInsets.only(right: 6), child: chip),
          TextButton(
            onPressed: widget.viewModel.clearFilters,
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }

  Widget _tagFilterChip(String tagId) {
    final tag = widget.viewModel.availableTags
        .where((item) => item.id == tagId)
        .firstOrNull;
    return tag == null
        ? InputChip(
            label: const Text('Tag'),
            onDeleted: () => _removeFilter('tag', tagId),
          )
        : TaskTagChip(
            tag: tag,
            selected: true,
            onDeleted: () => _removeFilter('tag', tagId),
          );
  }

  List<KanbanTask> _columnTasks(KanbanStatus status) {
    final visible = widget.viewModel.visibleTasks(status);
    final departing = _departingTask;
    if (departing == null ||
        departing.status != status ||
        visible.any((task) => task.id == departing.id)) {
      return visible;
    }
    return [...visible]
      ..insert(departing.sortOrder.clamp(0, visible.length), departing);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, child) {
      final model = widget.viewModel;
      final empty = model.isBoardEmpty;
      final noResults = !empty && model.isResultEmpty && _departingTask == null;
      final append = widget.appendViewModel;
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.arrow_back),
          ),
          title: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 200),
            child: _showSearch
                ? TextField(
                    key: const ValueKey('search'),
                    controller: _search,
                    autofocus: true,
                    onChanged: model.setSearchQuery,
                    decoration: const InputDecoration(
                      hintText: 'Search tasks',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  )
                : Column(
                    key: const ValueKey('title'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.projectName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Kanban Board',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
          ),
          actions: [
            if (_showSearch && _search.text.isNotEmpty)
              IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _search.clear();
                  model.setSearchQuery('');
                },
              ),
            IconButton(
              tooltip: _showSearch ? 'Close search' : 'Search tasks',
              icon: Icon(_showSearch ? Icons.close : Icons.search),
              onPressed: () {
                setState(() => _showSearch = !_showSearch);
                if (!_showSearch) {
                  _search.clear();
                  model.setSearchQuery('');
                }
              },
            ),
            PopupMenuButton<String>(
              tooltip: 'Board menu',
              enabled: !_navigationBusy,
              onSelected: _overflow,
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'filter',
                  child: Text('Filter tasks'),
                ),
                const PopupMenuItem(value: 'sort', child: Text('Sort tasks')),
                const PopupMenuItem(value: 'tags', child: Text('Manage tags')),
                const PopupMenuItem(
                  value: 'archived',
                  child: Text('Archived Tasks'),
                ),
                if (append != null &&
                    widget.projectStatus != 'archived' &&
                    model.boardId != null &&
                    !model.isBoardArchived)
                  const PopupMenuItem(
                    value: 'generate-more',
                    child: Text('Generate More Tasks'),
                  ),
                const PopupMenuItem(
                  value: 'archive',
                  child: Text('Archive board'),
                ),
              ],
            ),
          ],
        ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 200),
            child: model.isLoading
                ? const BoardLoadingView(key: ValueKey('loading'))
                : model.errorMessage != null && model.allTasks.isEmpty
                ? BoardErrorView(
                    key: const ValueKey('error'),
                    message: model.errorMessage!,
                    actionLabel: model.isBoardArchived
                        ? 'Restore board'
                        : model.isSignedIn
                        ? 'Retry'
                        : 'Sign in',
                    description: model.isBoardArchived
                        ? 'Restore it to continue working on these tasks.'
                        : model.isSignedIn
                        ? 'Please check your connection and try again.'
                        : 'Sign in to open your project board.',
                    onRetry: model.isBoardArchived
                        ? model.restoreArchivedBoard
                        : model.isSignedIn
                        ? model.retry
                        : () => _showSheet(_SignInSheet(viewModel: model)),
                  )
                : Column(
                    key: const ValueKey('board'),
                    children: [
                      ProjectProgressCard(
                        progress: model.projectProgress,
                        completed: model.completedTaskCount,
                        total: model.totalTaskCount,
                        onTap: _navigationBusy ? null : _showProgress,
                      ),
                      if (model.hasActiveFilters)
                        _filterChips(model.activeFilter),
                      if (model.activeSort != KanbanSort.custom)
                        TextButton.icon(
                          onPressed: () => model.setSort(KanbanSort.custom),
                          icon: const Icon(Icons.drag_indicator),
                          label: const Text('Use Custom order to drag tasks'),
                        ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final viewportWidth = constraints.maxWidth;
                            final largeText =
                                MediaQuery.textScalerOf(context).scale(1) > 1.6;
                            final columnWidth = largeText
                                ? viewportWidth * .9
                                : (viewportWidth - 96).clamp(
                                    220.0,
                                    viewportWidth,
                                  );
                            final trackWidth =
                                columnWidth * KanbanStatus.values.length +
                                _columnGap * (KanbanStatus.values.length - 1);
                            return Stack(
                              key: _overviewKey,
                              fit: StackFit.expand,
                              children: [
                                ClipRect(
                                  child: IgnorePointer(
                                    ignoring: noResults,
                                    child: GestureDetector(
                                      key: const Key('board-swipe-area'),
                                      behavior: HitTestBehavior.translucent,
                                      onHorizontalDragStart:
                                          _draggedTaskId == null
                                          ? (_) => _swipeDistance = 0
                                          : null,
                                      onHorizontalDragUpdate:
                                          _draggedTaskId == null
                                          ? (details) => _swipeDistance +=
                                                details.primaryDelta ?? 0
                                          : null,
                                      onHorizontalDragEnd:
                                          _draggedTaskId == null
                                          ? _onSwipeEnd
                                          : null,
                                      child: AnimatedBuilder(
                                        animation: _boardController,
                                        child: _boardTrack(columnWidth),
                                        builder: (context, child) {
                                          final scale = _boardScale.value;
                                          final selectedCenter =
                                              _boardFocus.value *
                                                  (columnWidth + _columnGap) +
                                              columnWidth / 2;
                                          final offset =
                                              viewportWidth / 2 -
                                              selectedCenter * scale;
                                          return Stack(
                                            fit: StackFit.expand,
                                            clipBehavior: Clip.none,
                                            children: [
                                              Positioned(
                                                left: 0,
                                                top: 0,
                                                width: trackWidth,
                                                height:
                                                    constraints.maxHeight /
                                                    scale,
                                                child: Transform.translate(
                                                  key: const Key(
                                                    'board-track-offset',
                                                  ),
                                                  offset: Offset(offset, 0),
                                                  child: Transform.scale(
                                                    key: const Key(
                                                      'drag-overview-scale',
                                                    ),
                                                    scale: scale,
                                                    alignment:
                                                        Alignment.topLeft,
                                                    child: child,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                                _edgeGuide(context, -1),
                                _edgeGuide(context, 1),
                                Positioned.fill(
                                  child: IgnorePointer(
                                    ignoring: !noResults,
                                    child: AnimatedSwitcher(
                                      duration:
                                          MediaQuery.disableAnimationsOf(
                                            context,
                                          )
                                          ? Duration.zero
                                          : const Duration(milliseconds: 200),
                                      switchInCurve: Curves.easeOutCubic,
                                      switchOutCurve: Curves.easeInCubic,
                                      child: noResults
                                          ? ColoredBox(
                                              key: const ValueKey('no-results'),
                                              color: Theme.of(
                                                context,
                                              ).scaffoldBackgroundColor,
                                              child: BoardEmptyState(
                                                onAction: () {
                                                  model.clearFilters();
                                                  _search.clear();
                                                  model.setSearchQuery('');
                                                },
                                              ),
                                            )
                                          : const SizedBox.shrink(
                                              key: ValueKey('results-visible'),
                                            ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        floatingActionButton: IgnorePointer(
          ignoring: _draggedTaskId != null,
          child: AnimatedOpacity(
            opacity: _draggedTaskId == null ? 1 : 0,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 150),
            child: FloatingActionButton.extended(
              key: const Key('new-task-button'),
              onPressed: _navigationBusy ? null : () => _openForm(),
              icon: const Icon(Icons.add),
              label: const Text('New Task'),
            ),
          ),
        ),
      );
    },
  );
}

class _SignInSheet extends StatefulWidget {
  const _SignInSheet({required this.viewModel});
  final KanbanViewModel viewModel;
  @override
  State<_SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends State<_SignInSheet> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (widget.viewModel.isSaving) return;
    if (await widget.viewModel.signIn(_email.text, _password.text) && mounted) {
      AppRouter.back(context);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      16,
      0,
      16,
      MediaQuery.viewInsetsOf(context).bottom + 16,
    ),
    child: SafeArea(
      top: false,
      child: ListView(
        shrinkWrap: true,
        children: [
          Text(
            'Sign in to SkillTrack',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: widget.viewModel,
            builder: (context, child) => Column(
              children: [
                if (widget.viewModel.errorMessage != null)
                  Text(
                    widget.viewModel.errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: widget.viewModel.isSaving ? null : _signIn,
                  child: widget.viewModel.isSaving
                      ? const CircularProgressIndicator()
                      : const Text('Sign in'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
