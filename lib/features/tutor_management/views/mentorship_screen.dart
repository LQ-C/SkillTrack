import '../../educational_content/repositories/content_repository.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:flutter/material.dart';
import 'mentor_payments_screen.dart';
import 'package:skilltrack/app/widgets/notice.dart';
import '../models/tutor_models.dart';
import '../repositories/tutor_repository.dart';
import '../viewmodels/tutor_view_model.dart';
import '../widgets/tutor_forms.dart';
import 'mentor_detail_screen.dart';

class MentorshipScreen extends StatefulWidget {
  const MentorshipScreen({super.key, required this.repository, this.content});
  final ContentRepository? content;
  final TutorRepository repository;
  @override
  State<MentorshipScreen> createState() => _MentorshipScreenState();
}

class _MentorshipScreenState extends State<MentorshipScreen> {
  late final vm = TutorViewModel(widget.repository);
  @override
  void initState() {
    super.initState();
    vm.addListener(refresh);
    vm.load();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    vm.dispose();
    super.dispose();
  }

  Future<void> editProfile() async {
    final saved = await Navigator.push<bool>(
      context,
      AppRouter.featureRoute(
        builder: (_) => TutorProfileEditor(
          repository: widget.repository,
          profile: vm.profile!,
        ),
      ),
    );
    if (saved == true && mounted) vm.load();
  }

  Future<void> editSlot([MentorSlot? slot]) async {
    final value = await showDialog<({DateTime start, DateTime end})>(
      context: context,
      builder: (_) => SlotDialog(slot: slot),
    );
    if (value != null && mounted) {
      await vm.action(
        () => widget.repository.saveSlot(value.start, value.end, id: slot?.id),
        'Availability saved.',
      );
    }
  }

  Future<void> deleteSlot(MentorSlot slot) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete availability?'),
        content: const Text(
          'Slots with session requests are kept for your session history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await vm.action(
        () => widget.repository.deleteSlot(slot.id),
        'Availability deleted.',
      );
    }
  }

  Widget panel(List<Widget> children) => RefreshIndicator(
    onRefresh: vm.load,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      children: [
        if (vm.error != null) ...[
          Notice(vm.error!, error: true),
          OutlinedButton(
            onPressed: vm.busy ? null : vm.load,
            child: const Text('Retry'),
          ),
        ],
        if (vm.success != null) Notice(vm.success!),
        if (vm.loading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          ),
        ...children,
      ],
    ),
  );
  Widget heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 12),
    child: Text(
      text,
      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
    ),
  );
  Widget ownMentoring() {
    final p = vm.profile;
    if (p == null) {
      return panel([
        heading('Share what you know'),
        const Text(
          'Create your mentor profile to offer sessions and share your skills.',
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: vm.busy || vm.loading || vm.error != null
              ? null
              : () => vm.action(
                  widget.repository.enable,
                  'Mentor profile enabled. You can now offer sessions.',
                ),
          child: const Text('Create mentor profile'),
        ),
      ]);
    }
    final approved = vm.role == 'mentor';
    final count = vm.feedback.length;
    final average = count == 0
        ? null
        : vm.feedback.fold<int>(0, (sum, f) => sum + f.rating) / count;
    return panel([
      heading('Your mentor workspace'),
      OutlinedButton.icon(
        onPressed: vm.busy || vm.loading
            ? null
            : () => Navigator.push<void>(
                context,
                AppRouter.featureRoute(
                  builder: (_) =>
                      MentorPaymentsScreen(repository: widget.repository),
                ),
              ),
        icon: const Icon(Icons.payments_outlined),
        label: const Text('Materials price & payments'),
      ),
      const SizedBox(height: 12),
      Text(
        p.headline.isEmpty ? 'Complete your mentor profile' : p.headline,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      if (p.expertise.isNotEmpty) Text(p.expertise),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: vm.busy || vm.loading ? null : editProfile,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Edit mentor profile'),
      ),
      heading('Availability'),
      const Text(
        'Add dated teaching slots. Times are shown in your device’s local time zone.',
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: approved && !vm.busy && !vm.loading
            ? () => editSlot()
            : null,
        icon: const Icon(Icons.add),
        label: const Text('Add availability'),
      ),
      if (!approved)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Switch to Mentor in your account profile to offer sessions.',
          ),
        ),
      for (final slot in vm.slots)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sessionTime(context, slot.start),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text('Ends ${sessionTime(context, slot.end)}'),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed:
                          !approved ||
                              vm.busy ||
                              vm.loading ||
                              !slot.start.isAfter(DateTime.now())
                          ? null
                          : () => editSlot(slot),
                      child: const Text('Edit'),
                    ),
                    TextButton(
                      onPressed: vm.busy || vm.loading
                          ? null
                          : () => deleteSlot(slot),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      heading('Your performance'),
      Text(
        average == null
            ? 'No reviews yet.'
            : '${average.toStringAsFixed(1)} / 5 · $count ${count == 1 ? 'review' : 'reviews'}',
      ),
      for (final f in vm.feedback)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Text('${f.rating} / 5 stars'), Text(f.review)],
            ),
          ),
        ),
    ]);
  }

  Future<void> review(MentorshipSession session) async {
    final value = await showDialog<({String text, int rating})>(
      context: context,
      builder: (_) => const MentorshipMessageDialog(review: true),
    );
    if (value != null && mounted) {
      await vm.action(
        () => widget.repository.review(session.id, value.rating, value.text),
        'Thank you. Your feedback has been saved.',
      );
    }
  }

  Widget sessions() => panel([
    heading('My sessions'),
    const Text('Manage your session requests and confirmed sessions here.'),
    OutlinedButton.icon(
      onPressed: vm.busy || vm.loading
          ? null
          : () => Navigator.push<void>(
              context,
              AppRouter.featureRoute(
                builder: (_) =>
                    MentorPaymentsScreen(repository: widget.repository),
              ),
            ),
      icon: const Icon(Icons.receipt_long_outlined),
      label: const Text('Payment history'),
    ),
    if (!vm.loading && vm.sessions.isEmpty)
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text('No session requests yet.'),
      ),
    for (final s in vm.sessions) sessionCard(s),
  ]);
  Widget sessionCard(MentorshipSession s) {
    final own = s.mentorId == widget.repository.userId;
    final future = s.start.isAfter(DateTime.now());
    Widget action(String label, String status) => TextButton(
      onPressed: vm.busy || vm.loading
          ? null
          : () => vm.action(
              () => widget.repository.respond(s.id, status),
              'Session updated.',
            ),
      child: Text(label),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              own ? 'Learner: ${s.learnerName}' : 'Mentor: ${s.mentorName}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text(sessionTime(context, s.start)),
            Text('Ends ${sessionTime(context, s.end)}'),
            Chip(label: Text(s.status == 'accepted' ? 'Confirmed' : s.status)),
            Text(s.message),
            if (!own && s.status == 'completed' && !s.reviewed)
              const Text(
                'How was your session? Share feedback about your mentor.',
              ),
            Wrap(
              spacing: 8,
              children: [
                if (future && ['pending', 'accepted'].contains(s.status))
                  action('Cancel session', 'cancelled'),
                if (own &&
                    s.status == 'accepted' &&
                    !s.end.isAfter(DateTime.now()))
                  action('Mark completed', 'completed'),
                if (!own && s.status == 'completed' && !s.reviewed)
                  TextButton(
                    onPressed: vm.busy || vm.loading ? null : () => review(s),
                    child: const Text('Rate this mentor'),
                  ),
                if (!own && s.reviewed) const Text('Feedback submitted'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget directory() => panel([
    heading('Learn with a mentor'),
    const Text(
      'Find a mentor, explore their expertise and request an available session.',
    ),
    if (!vm.loading && vm.mentors.isEmpty)
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text('No mentors are available yet.'),
      ),
    for (final m in vm.mentors)
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.verified, color: Colors.teal),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      m.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              Text(m.headline),
              const SizedBox(height: 8),
              Text(m.expertise),
              const SizedBox(height: 8),
              Text(
                m.rating == null
                    ? 'No reviews yet'
                    : '${m.rating!.toStringAsFixed(1)} / 5 · ${m.reviewCount} reviews',
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: vm.busy
                    ? null
                    : () async {
                        await Navigator.push<void>(
                          context,
                          AppRouter.featureRoute(
                            builder: (_) => MentorDetailScreen(
                              content: widget.content,
                              repository: widget.repository,
                              mentor: m,
                            ),
                          ),
                        );
                        if (mounted) vm.load();
                      },
                child: const Text('View mentor'),
              ),
            ],
          ),
        ),
      ),
  ]);
  @override
  Widget build(BuildContext context) {
    if (vm.role == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Mentorship')),
        body: panel([]),
      );
    }
    final student = vm.role == 'student';
    return DefaultTabController(
      key: ValueKey(vm.role),
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mentorship'),
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              if (student)
                const Tab(text: 'Find mentors')
              else
                const Tab(text: 'My mentoring'),
              const Tab(text: 'My sessions'),
            ],
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: TabBarView(
              children: [
                if (student) directory() else ownMentoring(),
                sessions(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
