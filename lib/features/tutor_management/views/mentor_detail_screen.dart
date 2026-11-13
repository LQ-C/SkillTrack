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
  });
  final TutorRepository repository;
  final Mentor mentor;
  @override
  State<MentorDetailScreen> createState() => _MentorDetailScreenState();
}

class _MentorDetailScreenState extends State<MentorDetailScreen> {
  List<MentorSlot> slots = [];
  List<MentorFeedback> feedback = [];
  bool loading = true, busy = false;
  String? error, success;
  MentorPaymentOffer? offer;
  MentorPaymentAccess access = const MentorPaymentAccess();
  String? accountRole;
  String? paymentError;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final s = await widget.repository.availableSlots(widget.mentor.id);
      final f = await widget.repository.feedback(widget.mentor.id);
      final role = await widget.repository.role();
      MentorPaymentOffer? price;
      var paidAccess = const MentorPaymentAccess();
      String? paymentNotice;
      try {
        price = await widget.repository.paymentOffer(widget.mentor.id);
        if (role == 'student') {
          paidAccess = await widget.repository.paymentAccess(widget.mentor.id);
        }
      } catch (_) {
        paymentNotice =
            'Payments are not available yet. Please contact the app administrator.';
      }
      if (mounted) {
        setState(() {
          slots = s;
          feedback = f;
          accountRole = role;
          paymentError = paymentNotice;
          offer = price;
          access = paidAccess;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> refreshPayment() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repository.refreshPayments();
      if (mounted) await load();
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> cancelMentor() async {
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
    if (!mounted || confirmed != true || busy) return;
    setState(() {
      busy = true;
      error = null;
      success = null;
    });
    try {
      await widget.repository.cancelMentorPackage(widget.mentor.id);
      if (!mounted) return;
      setState(() {
        access = const MentorPaymentAccess();
        success = 'Mentor package cancelled.';
      });
      await load();
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pay() async {
    if (busy || accountRole != 'student') return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final order = await widget.repository.prepareDemoPayment(
        widget.mentor.id,
      );
      if (!mounted) return;
      final paid = await Navigator.push<bool>(
        context,
        AppRouter.featureRoute(
          builder: (_) =>
              DemoCheckoutScreen(repository: widget.repository, order: order),
        ),
      );
      if (mounted) {
        if (paid == true) {
          setState(
            () => success =
                'Payment successful. Your learning materials are unlocked.',
          );
        }
        await load();
      }
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> request(List<MentorSlot> options) async {
    if (busy || accountRole != 'student' || !access.materials) return;
    final slot = await showDialog<MentorSlot>(
      context: context,
      builder: (_) => SessionBookingDialog(
        sessions: options,
        price: access.credits > 0 ? null : sessionPaymentOffer.price,
      ),
    );
    if (slot == null || !mounted || busy) return;
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
        if (!mounted) return;
        final paid = await Navigator.push<bool>(
          context,
          AppRouter.featureRoute(
            builder: (_) =>
                DemoCheckoutScreen(repository: widget.repository, order: order),
          ),
        );
        if (paid != true) return;
      }
      if (mounted) {
        setState(() => success = 'Session confirmed. Find it in My sessions.');
      }
      if (mounted) await load();
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.mentor;
    return Scaffold(
      appBar: AppBar(title: const Text('Mentor')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: RefreshIndicator(
            onRefresh: load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  m.name,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Chip(avatar: Icon(Icons.school), label: Text('Mentor')),
                Text(m.headline, style: const TextStyle(fontSize: 20)),
                const SizedBox(height: 16),
                const Text(
                  'Expertise',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(m.expertise),
                const SizedBox(height: 20),
                if (accountRole == 'student')
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Learning materials',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const Text(
                            'Unlock this mentor’s published learning materials.',
                          ),
                          const SizedBox(height: 8),
                          if (paymentError != null) Text(paymentError!),
                          if (paymentError == null)
                            Text(
                              offer == null
                                  ? 'This mentor has not set a materials price yet.'
                                  : 'Materials price: ${offer!.price}',
                            ),
                          if (access.credits > 0)
                            Text('Existing session credits: ${access.credits}'),
                          Text(
                            access.materials
                                ? 'Learning materials unlocked in Library.'
                                : 'Buy this mentor’s learning materials to unlock session booking.',
                          ),
                          if (!access.materials && offer != null)
                            FilledButton(
                              onPressed: busy || loading ? null : pay,
                              child: Text('Pay ${offer!.price}'),
                            ),
                          if (access.materials)
                            TextButton(
                              onPressed: busy || loading ? null : cancelMentor,
                              child: const Text('Cancel mentor'),
                            ),
                          TextButton(
                            onPressed: busy || loading ? null : refreshPayment,
                            child: const Text('Refresh payment status'),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => Navigator.push<void>(
                                    context,
                                    AppRouter.featureRoute(
                                      builder: (_) => MentorPaymentsScreen(
                                        repository: widget.repository,
                                      ),
                                    ),
                                  ),
                            child: const Text('Payment history'),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                const SizedBox(height: 24),
                if (error != null) ...[
                  Notice(error!, error: true),
                  OutlinedButton(
                    onPressed: busy ? null : load,
                    child: const Text('Retry'),
                  ),
                ],
                if (success != null) Notice(success!),
                const Text(
                  'Available sessions',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const Text(
                  'Times follow the mentor’s schedule. Choose a day to see the bookable times. Sessions last up to one hour.',
                ),
                if (loading) const Center(child: CircularProgressIndicator()),
                if (!loading && slots.isEmpty)
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
                          if (m.id != widget.repository.userId &&
                              accountRole == 'student')
                            OutlinedButton(
                              onPressed: busy || loading || !access.materials
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
                const SizedBox(height: 24),
                const Text(
                  'Learner feedback',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                if (!loading && feedback.isEmpty) const Text('No reviews yet.'),
                for (final f in feedback)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${f.rating} / 5 stars'),
                          Text(f.review),
                        ],
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
