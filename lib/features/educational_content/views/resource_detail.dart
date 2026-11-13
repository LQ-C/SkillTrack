import '../utils/youtube_url.dart';
import 'package:skilltrack/app/router/app_router.dart';
import '../viewmodels/resource_detail_view_model.dart';
import 'package:flutter/material.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/educational_content/repositories/content_repository.dart';
import 'package:skilltrack/features/educational_content/widgets/content_notice.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:skilltrack/features/educational_content/utils/content_validation.dart';
import 'package:skilltrack/features/educational_content/utils/content_presentation.dart';
import 'package:skilltrack/features/educational_content/views/resource_editor.dart';
import 'package:skilltrack/features/educational_content/widgets/report_dialog.dart';
import 'package:skilltrack/features/educational_content/widgets/inline_youtube_video.dart';

class ResourceDetail extends StatefulWidget {
  const ResourceDetail({
    super.key,
    required this.repository,
    required this.id,
    required this.bookmarked,
    required this.canPublish,
  });
  final ContentRepository repository;
  final String id;
  final bool bookmarked, canPublish;
  @override
  State<ResourceDetail> createState() => _ResourceDetailState();
}

class _ResourceDetailState extends State<ResourceDetail> {
  late final viewModel = ResourceDetailViewModel(
    widget.repository,
    widget.id,
    bookmarked: widget.bookmarked,
  );
  LearningResource? get resource => viewModel.resource;
  bool get loading => viewModel.loading;
  bool get busy => viewModel.busy;
  bool get bookmarked => viewModel.bookmarked;
  set bookmarked(bool value) => viewModel.bookmarked = value;
  String? get error => viewModel.error;
  set error(String? value) => viewModel.error = value;
  String? get success => viewModel.success;
  set success(String? value) => viewModel.success = value;
  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    viewModel.addListener(refresh);
    load();
  }

  @override
  void dispose() {
    viewModel.dispose();
    super.dispose();
  }

  Future<void> load() => viewModel.load();
  Future<void> action(Future<void> Function() work) => viewModel.action(work);

  @override
  Widget build(BuildContext context) {
    final r = resource;
    final own = r?.authorId == widget.repository.userId;
    return Scaffold(
      appBar: AppBar(title: const Text('Learning resource')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (error != null) ContentNotice(error!, error: true),
              if (success != null) ContentNotice(success!),
              if (loading) const Center(child: CircularProgressIndicator()),
              if (!loading && r == null) ...[
                const Text(
                  'This resource may be private, withdrawn, or require mentor material access. Open Explore to choose a mentor and use their material checkout. Access is checked again when you retry.',
                ),
                OutlinedButton(onPressed: load, child: const Text('Retry')),
                TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).pushNamed<void>('/marketplace/explore'),
                  child: const Text('Explore mentors and material access'),
                ),
              ],
              if (!loading && r != null) ...[
                Icon(kindIcon(r.kind), size: 48),
                const SizedBox(height: 20),
                SelectableText(
                  r.title,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text('By ${r.authorName}'),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(label: Text(r.category)),
                    Chip(label: Text(r.level)),
                    Chip(label: Text(r.kind)),
                    ...r.tags.map((t) => Chip(label: Text('#$t'))),
                  ],
                ),
                const SizedBox(height: 16),
                SelectableText(
                  r.summary,
                  style: const TextStyle(fontSize: 17, height: 1.5),
                ),
                if (r.hidden)
                  const ContentNotice(
                    'Hidden by moderation. This resource is not visible to learners.',
                  ),
                if (own)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(statusLabel(r.status)),
                  ),
                if (r.kind == 'Video' &&
                    r.attachmentPath == null &&
                    youtubeVideoId(r.link) != null) ...[
                  const SizedBox(height: 20),
                  InlineYoutubeVideo(key: ValueKey(r.link), url: r.link),
                ],
                if (r.attachmentPath != null ||
                    (r.link.contains('/storage/v1/object/') &&
                        widget.repository is ResourceOpeningRepository)) ...[
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => action(() async {
                            final repository = widget.repository;
                            final url = repository is ResourceOpeningRepository
                                ? await (repository
                                          as ResourceOpeningRepository)
                                      .primaryFileUrl(r)
                                : await (repository as ResourceFileRepository)
                                      .resourceFileUrl(r.attachmentPath!);
                            if (!await launchUrl(
                              Uri.parse(url),
                              mode: LaunchMode.externalApplication,
                            )) {
                              throw const FormatException(
                                'No app could open this file.',
                              );
                            }
                          }),
                    icon: Icon(
                      r.kind == 'Video'
                          ? Icons.play_circle_outline
                          : Icons.description_outlined,
                    ),
                    label: Text(
                      r.kind == 'Video' ? 'Watch video' : 'Open reading file',
                    ),
                  ),
                ],
                if (r.link.isNotEmpty &&
                    youtubeVideoId(r.link) == null &&
                    !r.link.contains('/storage/v1/object/') &&
                    r.attachmentPath == null) ...[
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            // Revalidate stored URLs before handing them to another application.
                            if (contentLink(r.link) != null) {
                              setState(
                                () => error =
                                    'This resource has an invalid link.',
                              );
                              return;
                            }
                            try {
                              if (!await launchUrl(
                                Uri.parse(r.link),
                                mode: LaunchMode.externalApplication,
                              )) {
                                if (mounted) {
                                  setState(
                                    () =>
                                        error = 'No app could open this link.',
                                  );
                                }
                              }
                            } catch (_) {
                              if (mounted) {
                                setState(
                                  () => error =
                                      'Could not open the link. Try again later.',
                                );
                              }
                            }
                          },
                    icon: const Icon(Icons.open_in_new),
                    label: Text(
                      r.kind == 'Video' ? 'Watch video' : 'Open resource',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Opens an external website: ${Uri.tryParse(r.link)?.host ?? ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
                if (r.body.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  Text(
                    r.kind == 'Guide' ? 'Step-by-step guide' : 'Learning notes',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    r.body,
                    style: const TextStyle(fontSize: 16, height: 1.7),
                  ),
                ],
                const SizedBox(height: 28),
                OutlinedButton.icon(
                  onPressed: busy ? null : viewModel.toggleBookmark,
                  icon: Icon(
                    bookmarked ? Icons.bookmark : Icons.bookmark_border,
                  ),
                  label: Text(
                    bookmarked ? 'Remove bookmark' : 'Bookmark resource',
                  ),
                ),
                if (own) ...[
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () async {
                            final saved = await Navigator.push<bool>(
                              context,
                              AppRouter.featureRoute(
                                builder: (_) => ResourceEditor(
                                  repository: widget.repository,
                                  resource: r,
                                  canPublish: widget.canPublish,
                                ),
                              ),
                            );
                            if (saved == true && mounted) load();
                          },
                    child: const Text('Edit resource'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Delete resource?'),
                                content: const Text(
                                  'This permanently deletes the resource and its bookmarks and reports.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true && mounted) {
                              action(() async {
                                await widget.repository.delete(r.id);
                                if (context.mounted) Navigator.pop(context);
                              });
                            }
                          },
                    child: const Text(
                      'Delete resource',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ] else
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            final report =
                                await showDialog<
                                  ({String reason, String details})
                                >(
                                  context: context,
                                  builder: (_) => const ReportDialog(),
                                );
                            if (report != null && mounted) {
                              viewModel.report(report.reason, report.details);
                            }
                          },
                    child: const Text('Report this resource'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
