import 'package:flutter/material.dart';
import 'package:skilltrack/app/widgets/notice.dart';
import 'package:skilltrack/core/constants/content_options.dart';
import 'package:skilltrack/features/educational_content/utils/content_validation.dart';
import '../models/tutor_models.dart';
import '../repositories/tutor_repository.dart';
import '../viewmodels/tutor_view_model.dart';
import 'weekly_availability_field.dart';

String sessionTime(BuildContext context, DateTime date) {
  final l = MaterialLocalizations.of(context);
  return '${l.formatMediumDate(date)} · ${l.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
}

class TutorProfileEditor extends StatefulWidget {
  const TutorProfileEditor({
    super.key,
    required this.repository,
    required this.profile,
  });
  final TutorRepository repository;
  final TutorProfile profile;
  @override
  State<TutorProfileEditor> createState() => _TutorProfileEditorState();
}

class _TutorProfileEditorState extends State<TutorProfileEditor> {
  final form = GlobalKey<FormState>();
  String? selectedHeadline;
  final expertise = TextEditingController(),
      experience = TextEditingController(),
      credential = TextEditingController();
  bool busy = false, dirty = false;
  String? error;
  late List<WeeklyAvailability> availability;
  late int utcOffsetMinutes;
  @override
  void initState() {
    super.initState();
    selectedHeadline = contentCategories.contains(widget.profile.headline)
        ? widget.profile.headline
        : null;
    expertise.text = widget.profile.expertise;
    experience.text = widget.profile.experience;
    credential.text = widget.profile.credentialUrl;
    availability = List.of(widget.profile.availability);
    utcOffsetMinutes =
        widget.profile.utcOffsetMinutes ??
        DateTime.now().timeZoneOffset.inMinutes;
  }

  @override
  void dispose() {
    for (final c in [expertise, experience, credential]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> save(bool submit) async {
    if (busy) return;
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repository.publishWithSchedule(
        headline: selectedHeadline!,
        expertise: expertise.text.trim(),
        experience: experience.text.trim(),
        credentialUrl: credential.text.trim(),
        preferences: '',
        availability: availability,
        utcOffsetMinutes: utcOffsetMinutes,
      );
      if (!mounted) return;
      setState(() => dirty = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, true);
      });
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> leave() async {
    if (busy) return;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => dirty = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  Widget field(
    TextEditingController c,
    String label,
    int max, {
    int minimum = 3,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: c,
      enabled: !busy,
      maxLength: max,
      maxLines: lines,
      decoration: InputDecoration(
        labelText: label,
        alignLabelWithHint: lines > 1,
      ),
      validator: (v) => contentText(v, label, minimum, max),
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !dirty && !busy,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) leave();
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('Mentor profile')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: form,
              onChanged: () {
                if (!dirty) setState(() => dirty = true);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Share your expertise',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Choose your teaching category and share your skills in Explore for students to view. No qualification upload or administrator approval is required.',
                  ),
                  const SizedBox(height: 20),
                  if (error != null) Notice(error!, error: true),
                  DropdownButtonFormField<String>(
                    initialValue: selectedHeadline,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Teaching category',
                    ),
                    items: [
                      for (final category in contentCategories)
                        DropdownMenuItem(
                          value: category,
                          child: Text(category),
                        ),
                    ],
                    validator: (value) =>
                        value == null ? 'Select your teaching category.' : null,
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                            selectedHeadline = value;
                            dirty = true;
                          }),
                  ),
                  const SizedBox(height: 16),
                  field(expertise, 'Areas of expertise', 500, lines: 3),
                  TextFormField(
                    controller: credential,
                    enabled: !busy,
                    maxLength: 2000,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Portfolio link (optional)',
                      helperText: 'Use an HTTPS portfolio link.',
                    ),
                    validator: (v) => contentLink(v, required: false),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Weekly availability',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Select your free days and times. Students choose a session of up to one hour within your free times for the next four weeks. Existing session requests are kept when you change your schedule.',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Schedule time zone: UTC${utcOffsetMinutes < 0 ? '-' : '+'}${(utcOffsetMinutes.abs() ~/ 60).toString().padLeft(2, '0')}:${(utcOffsetMinutes.abs() % 60).toString().padLeft(2, '0')} (fixed offset)',
                  ),
                  const SizedBox(height: 12),
                  WeeklyAvailabilityField(
                    initial: availability,
                    enabled: !busy,
                    onChanged: (value) => setState(() {
                      availability = value;
                      dirty = true;
                    }),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: busy ? null : () => save(true),
                    child: Text(
                      busy ? 'Publishing…' : 'Publish profile to Explore',
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
}

class SlotDialog extends StatefulWidget {
  const SlotDialog({super.key, this.slot});
  final MentorSlot? slot;
  @override
  State<SlotDialog> createState() => _SlotDialogState();
}

class _SlotDialogState extends State<SlotDialog> {
  DateTime? start;
  int minutes = 60;
  String? error;
  @override
  void initState() {
    super.initState();
    start = widget.slot?.start;
    minutes = widget.slot?.end.difference(widget.slot!.start).inMinutes ?? 60;
  }

  Future<void> pick() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: start != null && start!.isAfter(now) ? start! : now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(start ?? now),
    );
    if (time == null || !mounted) return;
    setState(
      () => start = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.slot == null ? 'Add availability' : 'Edit availability'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Times use your device’s local time zone.'),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: pick,
            child: Text(
              start == null
                  ? 'Choose date and time'
                  : sessionTime(context, start!),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: minutes,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Duration'),
            items:
                ({
                      ...[30, 60, 90, 120, 180, 240, 480],
                      minutes,
                    }.toList()..sort())
                    .map(
                      (n) =>
                          DropdownMenuItem(value: n, child: Text('$n minutes')),
                    )
                    .toList(),
            onChanged: (v) => setState(() => minutes = v!),
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (start == null || !start!.isAfter(DateTime.now())) {
            setState(() => error = 'Choose a future date and time.');
            return;
          }
          Navigator.pop(context, (
            start: start!,
            end: start!.add(Duration(minutes: minutes)),
          ));
        },
        child: const Text('Save slot'),
      ),
    ],
  );
}

class MentorshipMessageDialog extends StatefulWidget {
  const MentorshipMessageDialog({super.key, this.review = false});
  final bool review;
  @override
  State<MentorshipMessageDialog> createState() =>
      _MentorshipMessageDialogState();
}

class _MentorshipMessageDialogState extends State<MentorshipMessageDialog> {
  final form = GlobalKey<FormState>();
  final text = TextEditingController();
  int? rating;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.review ? 'Review your mentor' : 'Request mentorship'),
    content: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.review) ...[
              DropdownButtonFormField<int>(
                initialValue: rating,
                decoration: const InputDecoration(labelText: 'Star rating'),
                items: [
                  for (var n = 1; n <= 5; n++)
                    DropdownMenuItem(value: n, child: Text('$n / 5 stars')),
                ],
                validator: (v) => v == null ? 'Choose a star rating.' : null,
                onChanged: (v) => setState(() => rating = v),
              ),
              const SizedBox(height: 16),
            ],
            TextFormField(
              controller: text,
              maxLines: 4,
              maxLength: 1000,
              decoration: InputDecoration(
                labelText: widget.review
                    ? 'Your feedback'
                    : 'What would you like to learn?',
              ),
              validator: (v) => contentText(
                v,
                widget.review ? 'Feedback' : 'Message',
                10,
                1000,
              ),
            ),
            if (widget.review)
              const Text(
                'Your rating and feedback will be visible to other learners.',
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, (
              text: text.text.trim(),
              rating: rating ?? 5,
            ));
          }
        },
        child: Text(widget.review ? 'Submit review' : 'Submit'),
      ),
    ],
  );
}
