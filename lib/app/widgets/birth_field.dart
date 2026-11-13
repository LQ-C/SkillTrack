import 'package:flutter/material.dart';
import 'package:skilltrack/core/utils/validation.dart';

class BirthField extends StatelessWidget {
  const BirthField({super.key, required this.controller, this.enabled = true});
  final TextEditingController controller;
  final bool enabled;
  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    enabled: enabled,
    readOnly: true,
    validator: validateBirthDate,
    decoration: const InputDecoration(
      labelText: 'Date of birth',
      prefixIcon: Icon(Icons.calendar_today_outlined),
    ),
    onTap: () async {
      final date = await showDatePicker(
        context: context,
        initialDate: DateTime.tryParse(controller.text) ?? DateTime(2004),
        firstDate: DateTime(1900),
        lastDate: DateTime.now(),
      );
      if (date != null) {
        controller.text = date.toIso8601String().substring(0, 10);
      }
    },
  );
}
