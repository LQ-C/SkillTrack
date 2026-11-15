import '../../profile/repositories/profile_repository.dart';
import '../viewmodels/explore_mentors_view_model.dart';
import '../../educational_content/repositories/content_repository.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:skilltrack/app/widgets/notification_bell.dart';
import 'package:flutter/material.dart';
import 'package:skilltrack/app/app_colors.dart';
import '../models/tutor_models.dart';
import '../repositories/tutor_repository.dart';
import '../viewmodels/tutor_view_model.dart';
import 'mentor_detail_screen.dart';
import '../widgets/tutor_forms.dart';
import 'mentor_payments_screen.dart';

class ExploreMentorsScreen extends StatefulWidget {
  const ExploreMentorsScreen({
    super.key,
    required this.repository,
    this.content,
    this.profiles,
  });
  final TutorRepository repository;
  final ProfileChangeSource? profiles;
  final ContentRepository? content;

  @override
  State<ExploreMentorsScreen> createState() => _ExploreMentorsScreenState();
}

class _ExploreMentorsScreenState extends State<ExploreMentorsScreen> {
  late final model = ExploreMentorsViewModel(
    widget.repository,
    profiles: widget.profiles,
  );
  List<Mentor> get mentors => model.mentors;
  TutorProfile? get ownProfile => model.ownProfile;
  bool get loading => model.loading;
  String? get role => model.role;
  String? get error => model.error;
  set error(String? value) => model.error = value;
  bool editing = false;
  final searchController = TextEditingController();
  @override
  void initState() {
    super.initState();
    model.addListener(changed);
    load();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    searchController.dispose();
    model.dispose();
    super.dispose();
  }

  Future<void> load() => model.load();

  Future<void> publishProfile() async {
    if (editing || loading || role != 'mentor') return;
    setState(() {
      editing = true;
      error = null;
    });
    try {
      final profile = await model.prepareProfileEditor();
      if (!mounted || !model.current || profile == null) return;
      await Navigator.of(context).push<bool>(
        AppRouter.featureRoute(
          builder: (_) => TutorProfileEditor(
            repository: widget.repository,
            profile: profile,
          ),
        ),
      );
      if (mounted) await load();
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => editing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final matches = model.matches;
    return Scaffold(
      appBar: AppBar(
        actions: const [NotificationBell()],
        title: const Text('Explore'),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        role == 'mentor'
                            ? 'Share your teaching profile.'
                            : 'Find your next mentor.',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        role == 'mentor'
                            ? 'Publish your skills and teaching details so students can choose you and request a session.'
                            : 'Explore mentors, compare their skills and reviews, then choose a session that suits you.',
                      ),
                      const SizedBox(height: 20),
                      if (loading && !model.hasLoaded)
                        const Center(child: CircularProgressIndicator()),
                      if (loading && model.hasLoaded)
                        const LinearProgressIndicator(minHeight: 2),
                      if (error != null) ...[
                        Text(error!),
                        TextButton(
                          onPressed: loading ? null : load,
                          child: const Text('Try again'),
                        ),
                      ],
                      if (model.hasLoaded && role == 'mentor') ...[
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Icon(Icons.school_outlined, size: 40),
                                const SizedBox(height: 16),
                                Text(
                                  ownProfile?.isListed == true
                                      ? 'Your profile is published'
                                      : 'Create your Explore profile',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  ownProfile?.isListed == true
                                      ? 'Students can find you in Explore. Keep your skills and availability up to date.'
                                      : 'Choose a teaching category and add the skills you teach. Only mentors can publish profiles.',
                                ),
                                if (ownProfile?.expertise.isNotEmpty ==
                                    true) ...[
                                  const SizedBox(height: 12),
                                  Text(ownProfile!.expertise),
                                ],
                                const SizedBox(height: 20),
                                OutlinedButton.icon(
                                  onPressed: editing
                                      ? null
                                      : () => Navigator.push<void>(
                                          context,
                                          AppRouter.featureRoute(
                                            builder: (_) =>
                                                MentorPaymentsScreen(
                                                  repository: widget.repository,
                                                ),
                                          ),
                                        ),
                                  icon: const Icon(Icons.payments_outlined),
                                  label: const Text(
                                    'Set materials price & view payments',
                                  ),
                                ),
                                FilledButton.icon(
                                  onPressed: editing ? null : publishProfile,
                                  icon: const Icon(Icons.edit_outlined),
                                  label: Text(
                                    editing
                                        ? 'Opening…'
                                        : ownProfile?.isListed == true
                                        ? 'Edit published profile'
                                        : 'Publish my mentor profile',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ] else if (model.hasLoaded && role != 'student')
                        const Text(
                          'Mentor discovery is available to student accounts.',
                        )
                      else if (model.hasLoaded) ...[
                        TextField(
                          controller: searchController,
                          onChanged: model.search,
                          decoration: const InputDecoration(
                            labelText: 'Search names or skills',
                            prefixIcon: Icon(Icons.search),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '${matches.length} ${matches.length == 1 ? 'mentor' : 'mentors'}',
                          style: const TextStyle(color: muted),
                        ),
                        const SizedBox(height: 12),
                        if (matches.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 40),
                            child: Center(
                              child: Text(
                                mentors.isEmpty
                                    ? 'No mentors yet. Check back soon.'
                                    : 'No mentors match your search. Try another name or skill.',
                              ),
                            ),
                          ),
                        LayoutBuilder(
                          builder: (context, layout) {
                            final columns = layout.maxWidth >= 950
                                ? 3
                                : layout.maxWidth >= 620
                                ? 2
                                : 1;
                            final width =
                                (layout.maxWidth - (columns - 1) * 16) /
                                columns;
                            return Wrap(
                              spacing: 16,
                              runSpacing: 16,
                              children: [
                                for (final mentor in matches)
                                  SizedBox(
                                    width: width,
                                    child: _MentorCard(
                                      mentor: mentor,
                                      onOpen: () =>
                                          Navigator.of(context).push<void>(
                                            AppRouter.featureRoute(
                                              builder: (_) =>
                                                  MentorDetailScreen(
                                                    content: widget.content,
                                                    repository:
                                                        widget.repository,
                                                    mentor: mentor,
                                                  ),
                                            ),
                                          ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MentorCard extends StatelessWidget {
  const _MentorCard({required this.mentor, required this.onOpen});
  final Mentor mentor;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: forest,
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: Colors.white,
                foregroundColor: forest,
                child: Text(
                  mentor.name.trim().isEmpty
                      ? '?'
                      : mentor.name.trim().characters.first.toUpperCase(),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Mentor', style: TextStyle(color: Colors.white)),
              ),
              const Icon(Icons.school_outlined, color: Colors.white, size: 20),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mentor.name,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              if (mentor.headline.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(mentor.headline),
              ],
              const SizedBox(height: 16),
              const Text(
                'Skills',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(mentor.expertise),
              const SizedBox(height: 16),
              Text(
                mentor.rating == null
                    ? 'No reviews yet'
                    : '★ ${mentor.rating!.toStringAsFixed(1)} · ${mentor.reviewCount} reviews',
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onOpen,
                  child: const Text('View profile & sessions'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
