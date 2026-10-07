import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../../app/router/app_router.dart';
import '../models/kanban_filter.dart';
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
  }) : assert(boardId != '');
  final KanbanViewModel viewModel;
  final String projectId;
  final String boardId;
  final String projectName;
  @override
  State<KanbanBoardScreen> createState() => _KanbanBoardScreenState();
}

class _KanbanBoardScreenState extends State<KanbanBoardScreen>
    with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  final _pages = PageController(viewportFraction: .9);
  final _boardKey = GlobalKey();
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
  int _pageIndex = 0;
  int _edgeDirection = 0;
  bool _pageAnimating = false;
  bool _showSearch = false;
  @override
  void initState() {
    super.initState();
    _settleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
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
    for (final controller in _listControllers) {
      controller.dispose();
    }
    _pages.dispose();
    super.dispose();
  }

  void _startTaskDrag(KanbanTask task, Rect origin) {
    _edgeTimer?.cancel();
    _verticalTimer?.cancel();
    _dragSnapshot = task;
    _dragOriginRect = origin;
    _dropRect = null;
    HapticFeedback.lightImpact();
    setState(() {
      _draggedTaskId = task.id;
      _draggedCardHeight = origin.height;
      _hoverStatus = null;
      _hoverIndex = null;
    });
  }

  void _updateTaskDrag(Offset position) {
    _dragPosition = position;
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
      if (MediaQuery.disableAnimationsOf(context)) {
        _pages.jumpToPage(target);
      } else {
        await _pages.animateToPage(
          target,
          duration: const Duration(milliseconds: 290),
          curve: Curves.easeInOutCubic,
        );
      }
      if (!mounted) return;
      _pageIndex = target;
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
    if (!mounted || _draggedTaskId == null) return;
    setState(() {
      _draggedTaskId = null;
      _draggedCardHeight = null;
      _hoverStatus = null;
      _hoverIndex = null;
      _edgeDirection = 0;
    });
  }

  Widget _edgeGuide(BuildContext context, int direction) {
    final target = _pageIndex + direction;
    if (_draggedTaskId == null ||
        target < 0 ||
        target >= KanbanStatus.values.length) {
      return const SizedBox.shrink();
    }
    final color = Theme.of(context).colorScheme.primary;
    final active = _edgeDirection == direction;
    return Positioned(
      key: Key(direction < 0 ? 'drag-edge-left' : 'drag-edge-right'),
      top: 0,
      bottom: 0,
      left: direction < 0 ? 0 : null,
      right: direction > 0 ? 0 : null,
      width: 68,
      child: IgnorePointer(
        child: AnimatedContainer(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: direction < 0
                  ? [
                      color.withValues(alpha: active ? .24 : .13),
                      Colors.transparent,
                    ]
                  : [
                      Colors.transparent,
                      color.withValues(alpha: active ? .24 : .13),
                    ],
            ),
          ),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: color.withValues(alpha: active ? .8 : .35),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    direction < 0 ? Icons.chevron_left : Icons.chevron_right,
                    color: color,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    KanbanStatus.values[target].label,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _finishTaskDrag(DraggableDetails details) {
    if (!mounted) return;
    final task = _dragSnapshot;
    final origin = _dragOriginRect;
    final destination = details.wasAccepted ? _dropRect : origin;
    _endTaskDrag();
    _dragSnapshot = null;
    _dragOriginRect = null;
    _dropRect = null;
    if (task == null ||
        origin == null ||
        MediaQuery.disableAnimationsOf(context)) {
      return;
    }
    _settleController.stop();
    _settleEntry?.remove();
    _settleEntry?.dispose();
    _settleController.reset();
    final start = details.offset - Offset(origin.width / 2, origin.height / 2);
    final target = destination?.topLeft ?? start;
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
            width: origin.width,
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
    final previous = widget.viewModel.allTasks
        .where((task) => task.id == id)
        .firstOrNull
        ?.status;
    _endTaskDrag();
    HapticFeedback.selectionClick();
    _accentTasks({id});
    final moved = await widget.viewModel.moveTask(id, status, newIndex: index);
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
  }

  Future<void> _openDetails(KanbanTask task) async {
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
  }

  Future<void> _openArchivedTasks() async {
    await AppRouter.archivedTasks(
      context,
      BoardRouteArgs(
        projectId: widget.projectId,
        boardId: widget.boardId,
        projectName: widget.projectName,
      ),
    );
    if (mounted) await _refreshWithEntrance();
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

  void _showSheet(Widget sheet) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(heightFactor: .76, child: sheet),
  );

  void _showProgress() => showModalBottomSheet<void>(
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Archive task?'),
        content: const Text('This task will be removed from the active board.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _removeWithMotion(
        task,
        () => widget.viewModel.archiveTask(task.id),
        optimistic: true,
      );
    }
  }

  Future<void> _confirmDelete(KanbanTask task) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete task permanently?'),
        content: const Text(
          'The task and its related data cannot be recovered.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _removeWithMotion(
        task,
        () => widget.viewModel.deleteTask(task.id),
        optimistic: false,
      );
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Archive board?'),
        content: const Text('This board will be hidden from active projects.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirm == true) await widget.viewModel.archiveBoard();
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
                        style: Theme.of(context).textTheme.labelSmall,
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
              onSelected: _overflow,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'filter', child: Text('Filter tasks')),
                PopupMenuItem(value: 'sort', child: Text('Sort tasks')),
                PopupMenuItem(value: 'tags', child: Text('Manage tags')),
                PopupMenuItem(value: 'archived', child: Text('Archived Tasks')),
                PopupMenuItem(value: 'archive', child: Text('Archive board')),
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
                        onTap: _showProgress,
                      ),
                      if (model.hasActiveFilters)
                        _filterChips(model.activeFilter),
                      Expanded(
                        child: Stack(
                          key: _overviewKey,
                          fit: StackFit.expand,
                          children: [
                            AnimatedScale(
                              key: const Key('drag-overview-scale'),
                              scale:
                                  _draggedTaskId != null &&
                                      !MediaQuery.disableAnimationsOf(context)
                                  ? .90
                                  : 1,
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              child: IgnorePointer(
                                ignoring: noResults,
                                child: PageView.builder(
                                  key: _boardKey,
                                  controller: _pages,
                                  physics: _draggedTaskId == null
                                      ? const PageScrollPhysics()
                                      : const NeverScrollableScrollPhysics(),
                                  onPageChanged: (index) {
                                    _pageIndex = index;
                                    if (_draggedTaskId != null) setState(() {});
                                  },
                                  itemCount: KanbanStatus.values.length,
                                  itemBuilder: (context, index) {
                                    final status = KanbanStatus.values[index];
                                    return KanbanStatusColumn(
                                      key: ValueKey(status),
                                      status: status,
                                      tasks: _columnTasks(status),
                                      scrollController: _listControllers[index],
                                      viewportKey: _listKeys[index],
                                      draggedTaskId: _draggedTaskId,
                                      draggedCardHeight: _draggedCardHeight,
                                      accentTaskIds: _accentTaskIds,
                                      departingTaskId: _departureStarted
                                          ? _departingTask?.id
                                          : null,
                                      dragPosition: _dragPosition,
                                      hoverStatus: _hoverStatus,
                                      hoverIndex: _hoverIndex,
                                      onTaskTap: _openDetails,
                                      onTaskAction: _taskAction,
                                      onDragStart: _startTaskDrag,
                                      onDragUpdate: _updateTaskDrag,
                                      onDragEnd: _finishTaskDrag,
                                      onHover: _hoverTask,
                                      onLeave: _leaveTask,
                                      onDrop: _dropTask,
                                    );
                                  },
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
                                      MediaQuery.disableAnimationsOf(context)
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
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('new-task-button'),
          onPressed: () => _openForm(),
          icon: const Icon(Icons.add),
          label: const Text('New Task'),
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
    if (await widget.viewModel.signIn(_email.text, _password.text) && mounted) {
      Navigator.pop(context);
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
