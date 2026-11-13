String? validateName(String? value) {
  final name = value?.trim() ?? '';
  if (name.length < 2 ||
      name.length > 100 ||
      RegExp(r'[0-9<>\x00-\x1F]').hasMatch(name)) {
    return 'Enter your name (2–100 characters, without numbers).';
  }
  return null;
}

String? validateEmail(String? value) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value?.trim() ?? '')
    ? null
    : 'Enter a valid email address.';

String? validatePassword(String? value) {
  final p = value ?? '';
  if (p.length < 8 ||
      p.length > 128 ||
      !RegExp(r'[A-Z]').hasMatch(p) ||
      !RegExp(r'[a-z]').hasMatch(p) ||
      !RegExp(r'[0-9]').hasMatch(p) ||
      !RegExp(r'[^A-Za-z0-9\s]').hasMatch(p)) {
    return 'Use 8–128 characters with uppercase, lowercase, a number and a symbol.';
  }
  return null;
}

String? validateBirthDate(String? value) {
  final input = value ?? '';
  final date = DateTime.tryParse(input);
  if (date == null ||
      input.length != 10 ||
      date.toIso8601String().substring(0, 10) != input ||
      date.isAfter(DateTime.now()) ||
      date.year < 1900) {
    return 'Choose a valid date of birth.';
  }
  return null;
}
