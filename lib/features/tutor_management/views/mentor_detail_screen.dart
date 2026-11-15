import '../../educational_content/widgets/uploaded_video_player.dart';
import '../../educational_content/repositories/content_repository.dart';
import '../../educational_content/models/learning_resource.dart';
import '../viewmodels/mentor_detail_view_model.dart';
import 'package:skilltrack/app/router/app_router.dart';
import 'package:flutter/material.dart';
import 'package:skilltrack/app/widgets/notice.dart';
import '../models/tutor_models.dart';
import '../repositories/tutor_repository.dart';
import '../viewmodels/tutor_view_model.dart';
import '../widgets/session_booking_dialog.dart';
import '../models/mentor_payment.dart';
import 'mentor_payments_screen.dart';
import 'demo_checkout_screen.dart';

List<List<MentorSlot>> nearestWeekdayOptions(List<MentorSlot> sessions) => [
  for (final first in earliestSessionPerWeekday(sessions))
    (sessions
        .where((s) => DateUtils.isSameDay(s.scheduleStart, first.scheduleStart))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start))),
];

List<MentorSlot> earliestSessionPerWeekday(List<MentorSlot> sessions) {
  final earliest = <int, MentorSlot>{};
  for (final session in sessions) {
    final day = session.scheduleStart.weekday;
    final previous = earliest[day];
    if (previous == null || session.start.isBefore(previous.start)) {
      earliest[day] = session;
    }
  }
  return [
    for (var day = 1; day <= 7; day++)
      if (earliest[day] != null) earliest[day]!,
  ];
}

String weekdaySessionTime(
  BuildContext context,
  MentorSlot slot, {
  MentorSlot? last,
}) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  final localizations = MaterialLocalizations.of(context);
  String time(DateTime value, int? minutes) => localizations.formatTimeOfDay(
    minutes == null
        ? TimeOfDay.fromDateTime(value)
        : TimeOfDay(hour: (minutes ~/ 60) % 24, minute: minutes % 60),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  final start = time(slot.scheduleStart, slot.windowStartMinutes);
  final end = time((last ?? slot).scheduleEnd, slot.windowEndMinutes);
  return '${weekdays[slot.scheduleStart.weekday - 1]} · $start–$end';
}

class MentorDetailScreen extends StatefulWidget {
  const MentorDetailScreen({
    super.key,
    required this.repository,
    required this.mentor,
    this.content,
  });
  final TutorRepository repository;
  final Mentor mentor;
  final ContentRepository? content;
  @override
  State<MentorDetailScreen> createState() => _MentorDetailScreenState();
}

class _MentorDetailScreenState extends State<MentorDetailScreen> {
  String? _playingVideoId;
  int _playbackVersion = 0;
  late final vm = MentorDetailViewModel(
    widget.repository,
    widget.mentor.id,
    widget.content,
  );
  List<MentorSlot> get slots => vm.slots;
  bool get loading => vm.loading;
  bool get busy => vm.busy;
  set busy(bool value) => vm.busy = value;
  String? get error => vm.error;
  set error(String? value) => vm.error = value;
  String? get success => vm.success;
  set success(String? value) => vm.success = value;
  MentorPaymentOffer? get offer => vm.offer;
  MentorPaymentAccess get access => vm.access;
  set access(MentorPaymentAccess value) => vm.access = value;
  String? get accountRole => vm.accountRole;
  bool get current => mounted && vm.current;
  int tab = 0;
  final tabScroll = [ScrollController(), ScrollController()];
  @override
  void initState() {
    super.initState();
    vm.addListener(changed);
    load();
  }

  void changed() {
    if (vm.playbackVersion != _playbackVersion || !vm.unlocked) {
      _playbackVersion = vm.playbackVersion;
      _playingVideoId = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final controller in tabScroll) {
      controller.dispose();
    }
    vm.dispose();
    super.dispose();
  }

  Future<void> load() => vm.load();

  Future<void> refreshPayment() async {
    if (!current || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repository.refreshPayments();
      if (current) await load();
    } catch (e) {
      if (current) setState(() => error = tutorError(e));
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> cancelMentor() async {
    if (!current || busy) return;
    setState(() => busy = true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this mentor package?'),
        content: const Text(
          'This ends access to this mentor’s materials and cancels any upcoming bookings made with an older package credit. Separately purchased sessions stay booked. Your materials payment is non-refundable.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep package'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Cancel mentor'),
          ),
        ],
      ),
    );
    if (!mounted || !vm.current) return;
    setState(() => busy = false);
    if (confirmed != true) return;
    setState(() {
      busy = true;
      error = null;
      success = null;
    });
    try {
      vm.invalidatePlayback();
      setState(() => _playingVideoId = null);
      await widget.repository.cancelMentorPackage(widget.mentor.id);
      if (!mounted || !vm.current) return;
      setState(() {
        access = const MentorPaymentAccess();
        success = 'Mentor package cancelled.';
      });
      await load();
    } catch (e) {
      if (current) setState(() => error = tutorError(e));
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> pay() async {
    if (!current ||
        busy ||
        vm.loadingAccount ||
        vm.loadingMaterials ||
        accountRole != 'student' ||
        vm.own ||
        vm.resources.isEmpty ||
        vm.materialsError != null) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final order = await widget.repository.prepareDemoPayment(
        widget.mentor.id,
      );
      if (!mounted || !vm.current) return;
      final paid = await Navigator.push<bool>(
        context,
        AppRouter.featureRoute(
          builder: (_) =>
              DemoCheckoutScreen(repository: widget.repository, order: order),
        ),
      );
      if (current) {
        if (paid == true) {
          setState(
            () => success =
                'Payment successful. Your learning materials are unlocked.',
          );
        }
        await load();
      }
    } catch (e) {
      if (current) setState(() => error = tutorError(e));
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> request(List<MentorSlot> options) async {
    if (!current || busy || accountRole != 'student' || !access.materials) {
      return;
    }
    setState(() => busy = true);
    final slot = await showDialog<MentorSlot>(
      context: context,
      builder: (_) => SessionBookingDialog(
        sessions: options,
        price: access.credits > 0 ? null : sessionPaymentOffer.price,
      ),
    );
    if (!mounted || !vm.current) return;
    setState(() => busy = false);
    if (slot == null) return;
    setState(() {
      busy = true;
      error = null;
      success = null;
    });
    try {
      if (access.credits > 0) {
        await widget.repository.request(
          slot.id,
          'Mentorship session requested.',
        );
      } else {
        final order = await widget.repository.prepareSessionPayment(slot.id);
        if (!mounted || !vm.current) return;
        final paid = await Navigator.push<bool>(
          context,
          AppRouter.featureRoute(
            builder: (_) =>
                DemoCheckoutScreen(repository: widget.repository, order: order),
          ),
        );
        if (paid != true) return;
      }
      if (current) {
        setState(() => success = 'Session confirmed. Find it in My sessions.');
      }
      if (current) await load();
    } catch (e) {
      if (current) setState(() => error = tutorError(e));
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> openResource(LearningResource r) async {
    if (!current || busy) return;
    setState(() => busy = true);
    try {
      if (!await vm.canOpen(r.id)) {
        if (current) {
          setState(
            () => error =
                'This resource is no longer available or materials access is required.',
          );
        }
        if (current) {
          await load();
          if (current) {
            setState(
              () => error =
                  'This resource is no longer available or materials access is required.',
            );
          }
        }
        return;
      }
      if (!mounted || !vm.current) return;
      await Navigator.of(
        context,
      ).pushNamed('/resources/details', arguments: r.id);
      if (current) await load();
    } catch (e) {
      if (current) {
        await load();
        if (current) setState(() => error = tutorError(e));
      }
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> paymentHistory() async {
    if (!current || busy) return;
    setState(() => busy = true);
    try {
      await Navigator.push<void>(
        context,
        AppRouter.featureRoute(
          builder: (_) => MentorPaymentsScreen(repository: widget.repository),
        ),
      );
      if (current) await load();
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> openManagement(String route) async {
    if (!current || busy) return;
    setState(() => busy = true);
    try {
      await Navigator.of(context).pushNamed(route);
      if (current) await load();
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Widget videoPreview(LearningResource resource) {
    final unlocked = vm.unlocked;
    final canTap =
        !busy &&
        !vm.loadingAccount &&
        (unlocked ||
            (accountRole == 'student' &&
                !vm.loadingMaterials &&
                offer != null &&
                vm.paymentError == null));
    return Semantics(
      button: true,
      label: unlocked
          ? 'Play ${resource.title}'
          : 'Unlock to Watch ${resource.title}',
      enabled: canTap,
      child: Material(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('video-preview-${resource.id}'),
          onTap: !canTap
              ? null
              : () {
                  if (!unlocked) {
                    pay();
                    return;
                  }
                  if (_playingVideoId == resource.id) return;
                  vm.invalidatePlayback();
                  _playbackVersion = vm.playbackVersion;
                  setState(() => _playingVideoId = resource.id);
                },
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        unlocked ? Icons.play_circle_fill : Icons.lock_outline,
                        size: 56,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                      if (!unlocked) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Unlock to Watch',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onPrimaryContainer,
                              ),
                        ),
                      ],
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

  Widget materialCard(LearningResource r) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                child: Text(
                  widget.mentor.name.isEmpty
                      ? 'M'
                      : widget.mentor.name.characters.first,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(widget.mentor.name)),
              if (!vm.unlocked) const Icon(Icons.lock_outline),
            ],
          ),
          const SizedBox(height: 12),
          Text(r.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              Chip(label: Text(r.kind)),
              Chip(label: Text(r.level)),
            ],
          ),
          Text(r.summary),
          const SizedBox(height: 12),
          if (r.kind == 'Video')
            if (vm.unlocked && _playingVideoId == r.id)
              UploadedVideoPlayer(
                key: ValueKey(r.id),
                loadUrl: () => vm.videoPlaybackUrl(r.id),
              )
            else
              videoPreview(r)
          else if (vm.unlocked)
            FilledButton.icon(
              onPressed: busy || vm.loadingAccount
                  ? null
                  : () => openResource(r),
              icon: const Icon(Icons.menu_book_outlined),
              label: Text(r.kind == 'Reading' ? 'Read' : 'View'),
            )
          else if (accountRole == 'student')
            FilledButton.icon(
              onPressed:
                  busy ||
                      vm.loadingAccount ||
                      vm.loadingMaterials ||
                      offer == null ||
                      vm.paymentError != null
                  ? null
                  : pay,
              icon: const Icon(Icons.lock_open),
              label: const Text('Unlock Materials'),
            )
          else
            const Text(
              'Materials are available to enrolled learners and their author.',
            ),
          if (vm.unlocked && r.kind == 'Video')
            TextButton(
              onPressed: busy ? null : () => openResource(r),
              child: const Text('Details'),
            ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final m = widget.mentor;
    if (!vm.current) {
      return const Scaffold(
        body: Center(
          child: Text('Your account changed. Return to Explore to continue.'),
        ),
      );
    }
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mentor'),
          actions: [
            PopupMenuButton<String>(
              enabled: !busy && !loading,
              onSelected: (value) {
                if (value == 'history') paymentHistory();
                if (value == 'refresh') refreshPayment();
                if (value == 'cancel') cancelMentor();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'history',
                  child: Text('Payment history'),
                ),
                const PopupMenuItem(
                  value: 'refresh',
                  child: Text('Refresh Status'),
                ),
                if (accountRole == 'student' && access.materials)
                  const PopupMenuItem(
                    value: 'cancel',
                    child: Text('Cancel mentor'),
                  ),
              ],
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: RefreshIndicator(
              onRefresh: load,
              child: ListView(
                key: PageStorageKey(tab),
                controller: tabScroll[tab],
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 26,
                        child: Text(
                          m.name.isEmpty ? 'M' : m.name.characters.first,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.name,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const Chip(label: Text('Mentor')),
                            Text(
                              m.headline,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(m.expertise),
                  if (m.rating != null && m.reviewCount > 0)
                    Text(
                      '${m.rating!.toStringAsFixed(1)} / 5 · ${m.reviewCount} reviews',
                    ),
                  if (vm.own)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Your mentor profile. Manage published materials in Library and availability in Mentorship.',
                      ),
                    ),
                  if (vm.own)
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => openManagement('/marketplace/library'),
                          child: const Text('Manage materials'),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => openManagement('/marketplace/mentorship'),
                          child: const Text('Manage sessions'),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    onTap: (i) {
                      if (tab == i) return;
                      vm.invalidatePlayback();
                      _playbackVersion = vm.playbackVersion;
                      setState(() {
                        tab = i;
                        _playingVideoId = null;
                      });
                    },
                    tabs: const [
                      Tab(text: 'Learning Materials'),
                      Tab(text: 'Sessions'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (vm.loadingAccount || (tab == 1 && vm.loadingSessions))
                    const LinearProgressIndicator(),
                  if (error != null) ...[
                    Notice(error!, error: true),
                    TextButton(
                      onPressed: busy ? null : load,
                      child: const Text('Retry'),
                    ),
                  ],
                  if (success != null) Notice(success!),
                  if (vm.paymentError != null)
                    Notice(vm.paymentError!, error: true),
                  if (tab == 0) ...[
                    if (vm.loadingMaterials) const LinearProgressIndicator(),
                    if (vm.materialsError != null) ...[
                      Notice(vm.materialsError!, error: true),
                      TextButton(
                        onPressed: vm.loadingMaterials
                            ? null
                            : () => vm.loadMaterials(),
                        child: const Text('Retry materials'),
                      ),
                    ],
                    if (!vm.loadingMaterials &&
                        vm.materialsError == null &&
                        vm.resources.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('No published learning materials yet.'),
                      ),
                    if (vm.resources.isNotEmpty) ...[
                      if (accountRole == 'student')
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            access.materials
                                ? 'Materials unlocked. Sessions are purchased separately.'
                                : offer == null
                                ? 'This mentor has not set a materials price yet.'
                                : '${offer!.price} · Unlock this mentor’s published learning materials. Sessions are purchased separately. Demo checkout; no money is charged.',
                          ),
                        ),
                      for (final r in vm.resources) materialCard(r),
                      if (vm.hasMore)
                        TextButton(
                          onPressed: vm.loadingMaterials
                              ? null
                              : () => vm.loadMaterials(more: true),
                          child: const Text('Load more materials'),
                        ),
                    ],
                  ] else ...[
                    Text(
                      'Available sessions',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Text(
                      'Times follow the mentor’s schedule. Choose a day to see the bookable times. Sessions last up to one hour.',
                    ),
                    Text(
                      'Session price: ${sessionPaymentOffer.price}. Materials purchase is required first.',
                    ),
                    if (access.credits > 0)
                      Text('Existing session credits: ${access.credits}'),
                    if (accountRole == 'student' && !access.materials)
                      const Text(
                        'Unlock learning materials in the Learning Materials tab before booking.',
                      ),
                    if (!vm.loadingSessions && slots.isEmpty && error == null)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text('No available sessions at the moment.'),
                      ),
                    for (final options in nearestWeekdayOptions(slots))
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                weekdaySessionTime(
                                  context,
                                  options.first,
                                  last: options.last,
                                ),
                              ),
                              if (!vm.own && accountRole == 'student')
                                OutlinedButton(
                                  onPressed:
                                      busy ||
                                          vm.loadingAccount ||
                                          vm.loadingSessions ||
                                          !access.materials
                                      ? null
                                      : () => request(options),
                                  child: Text(
                                    access.credits > 0
                                        ? 'Choose session time'
                                        : 'Choose session · ${sessionPaymentOffer.price}',
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
