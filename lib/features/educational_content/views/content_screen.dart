import '../../../app/widgets/category_dropdown.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:skilltrack/app/widgets/notification_bell.dart';
import 'package:skilltrack/features/educational_content/viewmodels/content_library_view_model.dart';
import 'package:flutter/material.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/educational_content/repositories/content_repository.dart';
import 'package:skilltrack/features/educational_content/widgets/content_notice.dart';
import 'package:skilltrack/core/constants/content_options.dart';
import 'package:skilltrack/features/educational_content/utils/content_presentation.dart';
import 'package:skilltrack/features/educational_content/views/resource_editor.dart';
import 'package:skilltrack/features/educational_content/views/resource_detail.dart';

class ContentScreen extends StatefulWidget {
  const ContentScreen({
    super.key,
    required this.repository,
    this.initialCategory,
  });
  final ContentRepository repository;
  final String? initialCategory;
  @override
  State<ContentScreen> createState() => _ContentScreenState();
}

class _ContentScreenState extends State<ContentScreen> {
  final search = TextEditingController();
  late final viewModel = ContentLibraryViewModel(widget.repository);
  List<LearningResource> get resources => viewModel.resources;
  set resources(List<LearningResource> value) => viewModel.resources = value;
  Set<String> get bookmarks => viewModel.bookmarks;
  set bookmarks(Set<String> value) => viewModel.bookmarks = value;
  String? get category => viewModel.category;
  set category(String? value) => viewModel.category = value;
  String? get level => viewModel.level;
  set level(String? value) => viewModel.level = value;
  String? get kind => viewModel.kind;
  set kind(String? value) => viewModel.kind = value;
  String? get error => viewModel.error;
  set error(String? value) => viewModel.error = value;
  bool get mine => viewModel.mine;
  set mine(bool value) => viewModel.mine = value;
  bool get loading => viewModel.loading;
  set loading(bool value) => viewModel.loading = value;
  bool get more => viewModel.more;
  set more(bool value) => viewModel.more = value;
  bool get mentor => viewModel.mentor;
  set mentor(bool value) => viewModel.mentor = value;
  bool get publisher => viewModel.publisher;
  set publisher(bool value) => viewModel.publisher = value;
  bool get accessLoaded => viewModel.accessLoaded;
  set accessLoaded(bool value) => viewModel.accessLoaded = value;
  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    viewModel.addListener(refresh);
    category = contentCategories.contains(widget.initialCategory)
        ? widget.initialCategory
        : null;
    load();
  }

  @override
  void dispose() {
    search.dispose();
    viewModel.dispose();
    super.dispose();
  }

  Future<void> load({bool append = false, bool refreshMetadata = true}) {
    viewModel.search = search.text;
    return viewModel.load(append: append, refreshMetadata: refreshMetadata);
  }

  Future<void> edit([LearningResource? item]) async {
    if (!mentor) return;
    final saved = await Navigator.push<bool>(
      context,
      AppRouter.featureRoute(
        builder: (_) => ResourceEditor(
          repository: widget.repository,
          resource: item,
          canPublish: publisher,
        ),
      ),
    );
    if (saved == true && mounted) load();
  }

  Future<void> open(LearningResource resource) async {
    await Navigator.push<void>(
      context,
      AppRouter.featureRoute(
        builder: (_) => ResourceDetail(
          repository: widget.repository,
          id: resource.id,
          bookmarked: bookmarks.contains(resource.id),
          canPublish: publisher,
        ),
      ),
    );
    if (mounted) load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      actions: const [NotificationBell()],
      title: const Text('Learning library'),
    ),
    floatingActionButton: mentor && mine
        ? FloatingActionButton.extended(
            onPressed: loading ? null : () => edit(),
            icon: const Icon(Icons.add),
            label: const Text('Add resource'),
          )
        : null,
    body:
        accessLoaded &&
            !mentor &&
            !loading &&
            error == null &&
            !viewModel.hasAccessibleMaterials
        ? RefreshIndicator(
            onRefresh: () => load(),
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'You currently have no learning material available',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          )
        : RefreshIndicator(
            onRefresh: () => load(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
              children: [
                const Text(
                  'Learn something.\nPut it into practice.',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                Text(
                  mentor
                      ? 'Your private teaching library. Students can buy access to your published materials.'
                      : 'Buy access to a mentor’s learning materials in Explore.',
                ),
                const SizedBox(height: 22),
                if (mentor)
                  Text(
                    'My resources',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                const SizedBox(height: 18),
                TextField(
                  controller: search,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => load(refreshMetadata: false),
                  decoration: InputDecoration(
                    labelText: 'Search resource titles',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      tooltip: 'Search',
                      onPressed: () => load(refreshMetadata: false),
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      SizedBox(
                        width: constraints.maxWidth > 600
                            ? 190
                            : constraints.maxWidth,
                        child: filter(
                          'Category',
                          category,
                          contentCategories,
                          (v) => category = v,
                        ),
                      ),
                      SizedBox(
                        width: constraints.maxWidth > 600
                            ? 180
                            : (constraints.maxWidth - 10) / 2,
                        child: filter(
                          'Level',
                          level,
                          contentLevels,
                          (v) => level = v,
                        ),
                      ),
                      SizedBox(
                        width: constraints.maxWidth > 600
                            ? 150
                            : (constraints.maxWidth - 10) / 2,
                        child: filter(
                          'Type',
                          kind,
                          contentKinds,
                          (v) => kind = v,
                        ),
                      ),
                    ],
                  ),
                ),
                if (category != null ||
                    level != null ||
                    kind != null ||
                    search.text.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        category = null;
                        level = null;
                        kind = null;
                        search.clear();
                      });
                      load();
                    },
                    child: const Text('Clear filters'),
                  ),
                const SizedBox(height: 18),
                if (mine && accessLoaded && !mentor)
                  const ContentNotice(
                    'To create learning resources, change your account role to Mentor in your profile.',
                  ),
                if (mine && mentor && !publisher)
                  const ContentNotice(
                    'You can prepare drafts now. Publishing requires mentor approval from the platform administrator.',
                  ),
                if (error != null) ...[
                  ContentNotice(error!, error: true),
                  OutlinedButton(
                    onPressed: () => load(),
                    child: const Text('Retry'),
                  ),
                ],
                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(28),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (!loading && error == null && resources.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 35),
                    child: Column(
                      children: [
                        const Icon(Icons.auto_stories_outlined, size: 56),
                        const SizedBox(height: 12),
                        Text(
                          mine
                              ? 'Your resources will appear here.'
                              : 'No resources found.',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          mine
                              ? 'Prepare your first learning resource using Add resource.'
                              : 'Buy access to a mentor’s materials in Explore, or try changing the filters.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ...resources.map(
                  (r) => Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => open(r),
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(kindIcon(r.kind)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${r.kind} · ${r.level}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (bookmarks.contains(r.id))
                                  const Icon(
                                    Icons.bookmark,
                                    semanticLabel: 'Bookmarked',
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              r.title,
                              style: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              r.summary,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 12),
                            Text('${r.category} · By ${r.authorName}'),
                            if (mine)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  r.hidden
                                      ? 'Hidden by moderation'
                                      : statusLabel(r.status),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (more && !loading && error == null)
                  OutlinedButton(
                    onPressed: () => load(append: true),
                    child: const Text('Load more'),
                  ),
              ],
            ),
          ),
  );
  Widget filter(
    String label,
    String? value,
    List<String> options,
    void Function(String?) change,
  ) => label == 'Category'
      ? categoryDropdown(
          context: context,
          key: ValueKey('$label:$value'),
          label: label,
          value: value ?? '',
          options: options,
          includeAll: true,
          onChanged: loading
              ? null
              : (v) {
                  setState(() => change(v == '' ? null : v));
                  load(refreshMetadata: false);
                },
        )
      : DropdownButtonFormField<String>(
          key: ValueKey('$label:$value'),
          initialValue: value ?? '',
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [
            const DropdownMenuItem(value: '', child: Text('All')),
            ...options.map((v) => DropdownMenuItem(value: v, child: Text(v))),
          ],
          onChanged: loading
              ? null
              : (v) {
                  setState(() => change(v == '' ? null : v));
                  load(refreshMetadata: false);
                },
        );
}
