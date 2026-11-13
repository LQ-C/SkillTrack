import 'package:flutter/material.dart';
import '../repositories/tutor_repository.dart';
import '../viewmodels/tutor_view_model.dart';

class LibraryAccessDialog extends StatefulWidget {
  const LibraryAccessDialog({
    super.key,
    required this.repository,
    required this.learnerId,
    required this.learnerName,
  });
  final TutorRepository repository;
  final String learnerId, learnerName;
  @override
  State<LibraryAccessDialog> createState() => _LibraryAccessDialogState();
}

class _LibraryAccessDialogState extends State<LibraryAccessDialog> {
  bool loading = true, busy = false, granted = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final value = await widget.repository.learnerLibraryAccess(
        widget.learnerId,
      );
      if (mounted) setState(() => granted = value);
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repository.setLearnerLibraryAccess(
        widget.learnerId,
        !granted,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = tutorError(e);
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Learning material access'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.learnerName),
        const SizedBox(height: 12),
        if (loading)
          const CircularProgressIndicator()
        else if (error != null)
          Text(error!)
        else
          Text(
            granted
                ? 'This student can view your published learning materials.'
                : 'Grant access to your published learning materials after accepting this student’s booking. Drafts stay private.',
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      if (!loading && error == null)
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(
            busy
                ? 'Saving…'
                : granted
                ? 'Revoke access'
                : 'Grant access',
          ),
        ),
    ],
  );
}
