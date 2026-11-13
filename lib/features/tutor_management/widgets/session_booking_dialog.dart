import 'package:flutter/material.dart';
import '../models/tutor_models.dart';

String bookingTime(BuildContext context, DateTime value) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(value),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

class SessionBookingDialog extends StatefulWidget {
  const SessionBookingDialog({super.key, required this.sessions, this.price});
  final List<MentorSlot> sessions;
  final String? price;
  @override
  State<SessionBookingDialog> createState() => _SessionBookingDialogState();
}

class _SessionBookingDialogState extends State<SessionBookingDialog> {
  late MentorSlot selected = widget.sessions.first;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose and confirm your session'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                MaterialLocalizations.of(
                  context,
                ).formatFullDate(selected.scheduleStart),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<MentorSlot>(
                initialValue: selected,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Available session time',
                ),
                items: [
                  for (final slot in widget.sessions)
                    DropdownMenuItem(
                      value: slot,
                      child: Text(
                        '${bookingTime(context, slot.scheduleStart)}–${bookingTime(context, slot.scheduleEnd)}',
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => selected = value!),
              ),
              const SizedBox(height: 12),
              Text(
                'Duration: ${selected.end.difference(selected.start).inMinutes} minutes',
              ),
              const SizedBox(height: 16),
              const Text(
                'The selected time is confirmed when you finish booking.',
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
          onPressed: () => Navigator.pop(context, selected),
          child: Text(
            widget.price == null
                ? 'Confirm booking'
                : 'Continue to pay ${widget.price}',
          ),
        ),
      ],
    );
  }
}
