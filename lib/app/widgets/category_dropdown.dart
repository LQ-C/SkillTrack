import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Category-only styling; retains Flutter's FormField, keyboard and menu route.
DropdownButtonFormField<String> categoryDropdown({
  required BuildContext context,
  Key? key,
  required String label,
  required String? value,
  required List<String> options,
  required ValueChanged<String?>? onChanged,
  FormFieldValidator<String>? validator,
  bool includeAll = false,
}) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final values = [if (includeAll) '', ...options];
  String text(String v) => v.isEmpty && includeAll ? 'All' : v;
  return DropdownButtonFormField<String>(
    key: key,
    initialValue: value,
    isExpanded: true,
    itemHeight: null,
    menuMaxHeight: math.min(
      330,
      math.max(
        48,
        MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom -
            MediaQuery.paddingOf(context).vertical -
            96,
      ),
    ),
    dropdownColor: scheme.surface,
    elevation: 3,
    borderRadius: BorderRadius.circular(14),
    icon: Icon(
      Icons.keyboard_arrow_down_rounded,
      color: onChanged == null ? theme.disabledColor : scheme.primary,
    ),
    decoration: InputDecoration(
      labelText: label,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary.withValues(alpha: .25)),
      ),
    ),
    selectedItemBuilder: (_) => [
      for (final v in values)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(text(v), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
    ],
    items: [
      for (final v in values)
        DropdownMenuItem<String>(
          value: v,
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: v == value ? scheme.primaryContainer : scheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: v == value
                  ? Border.all(color: scheme.primary.withValues(alpha: .2))
                  : null,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    text(v),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: v == value
                          ? scheme.onPrimaryContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 20,
                  child: v == value
                      ? Icon(
                          Icons.check_rounded,
                          size: 20,
                          color: scheme.primary,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
    ],
    onChanged: onChanged,
    validator: validator,
  );
}
