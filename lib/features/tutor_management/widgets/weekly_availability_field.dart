import 'package:flutter/material.dart';
import '../models/tutor_models.dart';

class WeeklyAvailabilityField extends StatefulWidget {
  const WeeklyAvailabilityField({
    super.key,
    required this.initial,
    required this.onChanged,
    required this.enabled,
  });
  final List<WeeklyAvailability> initial;
  final ValueChanged<List<WeeklyAvailability>> onChanged;
  final bool enabled;
  @override
  State<WeeklyAvailabilityField> createState() =>
      _WeeklyAvailabilityFieldState();
}

class _WeeklyAvailabilityFieldState extends State<WeeklyAvailabilityField> {
  late final days = {for (final day in widget.initial) day.day: day};
  static const names = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  void changed() => widget.onChanged(
    days.values.toList()..sort((a, b) => a.day.compareTo(b.day)),
  );
  Future<void> pick(int day, bool start) async {
    final current = days[day]!;
    final minutes = start ? current.start : current.end;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
    );
    if (time == null || !mounted) return;
    final value = time.hour * 60 + time.minute;
    setState(
      () => days[day] = WeeklyAvailability(
        day,
        start ? value : current.start,
        start ? current.end : value,
      ),
    );
    changed();
  }

  @override
  Widget build(BuildContext context) => FormField<List<WeeklyAvailability>>(
    validator: (_) {
      if (days.isEmpty) return 'Select at least one day you are free.';
      for (final d in days.values) {
        if (d.end <= d.start) {
          return '${names[d.day - 1]}: end time must be after start time.';
        }
      }
      return null;
    },
    builder: (field) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 1; i <= 7; i++)
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: Text(names[i - 1]),
                  subtitle: Text(
                    days.containsKey(i) ? 'Available' : 'Not available',
                  ),
                  value: days.containsKey(i),
                  onChanged: !widget.enabled
                      ? null
                      : (value) {
                          setState(() {
                            if (value) {
                              days[i] = WeeklyAvailability(i, 540, 1020);
                            } else {
                              days.remove(i);
                            }
                          });
                          changed();
                        },
                ),
                if (days.containsKey(i))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: widget.enabled
                              ? () => pick(i, true)
                              : null,
                          child: Text(
                            'From ${TimeOfDay(hour: days[i]!.start ~/ 60, minute: days[i]!.start % 60).format(context)}',
                          ),
                        ),
                        OutlinedButton(
                          onPressed: widget.enabled
                              ? () => pick(i, false)
                              : null,
                          child: Text(
                            'To ${TimeOfDay(hour: days[i]!.end ~/ 60, minute: days[i]!.end % 60).format(context)}',
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        if (field.hasError)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              field.errorText!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );
}
