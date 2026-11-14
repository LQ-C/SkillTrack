import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/utils/date_formatter.dart';
import '../../projects/models/project_with_progress.dart';

class ProjectCarousel extends StatefulWidget {
  const ProjectCarousel({
    super.key,
    required this.projects,
    required this.onOpen,
  });
  final List<ProjectWithProgress> projects;
  final ValueChanged<ProjectWithProgress>? onOpen;
  @override
  State<ProjectCarousel> createState() => _ProjectCarouselState();
}

class _ProjectCarouselState extends State<ProjectCarousel>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  late PageController controller = PageController();
  String? selected;
  int get index {
    final found = widget.projects.indexWhere((p) => p.project.id == selected);
    return found < 0 ? 0 : found;
  }

  @override
  void initState() {
    super.initState();
    selected = widget.projects.firstOrNull?.project.id;
  }

  @override
  void didUpdateWidget(ProjectCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.projects.map((p) => p.project.id).join(',');
    final newIds = widget.projects.map((p) => p.project.id).join(',');
    if (oldIds != newIds) {
      final target = index;
      selected = widget.projects.isEmpty
          ? null
          : widget.projects[target].project.id;
      controller.dispose();
      controller = PageController(initialPage: target);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.projects.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium!;
    List<({String text, TextStyle style})> lines(ProjectWithProgress p) => [
      (text: p.project.name, style: theme.textTheme.titleMedium!),
      (
        text:
            '${(p.progress * 100).round()}% complete · ${p.completedTaskCount} of ${p.totalTaskCount} tasks',
        style: body,
      ),
      if (p.project.endDate != null)
        (
          text: 'Due ${DateFormatter.calendarDate(p.project.endDate!)}',
          style: body,
        ),
      if (p.stalledTaskCount > 0)
        (
          text: '${p.stalledTaskCount} stalled tasks',
          style: body.copyWith(color: theme.colorScheme.error),
        ),
      if (p.boardId == null)
        (
          text: 'Board unavailable. Open Project to manage this project.',
          style: body,
        ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        // PageView needs a bounded height. Measure the same text styles and scale
        // used below, so titles and accessibility text can wrap without clipping.
        double height(ProjectWithProgress p) {
          double h = 44; // Card margins, padding and progress track.
          for (final line in lines(p)) {
            final painter = TextPainter(
              text: TextSpan(text: line.text, style: line.style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(maxWidth: math.max(1, constraints.maxWidth - 40));
            h += painter.height.ceil() + 8;
            painter.dispose();
          }
          return h + 8;
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: widget.projects.map(height).reduce(math.max),
              child: PageView.builder(
                key: ValueKey(controller),
                controller: controller,
                itemCount: widget.projects.length,
                onPageChanged: (i) =>
                    setState(() => selected = widget.projects[i].project.id),
                itemBuilder: (context, i) {
                  final p = widget.projects[i];
                  final content = lines(p);
                  return Card(
                    margin: const EdgeInsets.all(4),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: widget.onOpen == null || p.boardId == null
                          ? null
                          : () => widget.onOpen!(p),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var n = 0; n < content.length; n++) ...[
                              Text(content[n].text, style: content[n].style),
                              const SizedBox(height: 8),
                              if (n == 1) ...[
                                LinearProgressIndicator(
                                  value: p.progress,
                                  minHeight: 4,
                                ),
                                const SizedBox(height: 8),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (widget.projects.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Project ${index + 1} of ${widget.projects.length}',
                  style: theme.textTheme.labelSmall,
                ),
              ),
          ],
        );
      },
    );
  }
}
