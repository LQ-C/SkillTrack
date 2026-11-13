String? contentText(String? value, String label, int minimum, int maximum) {
  final text = value?.trim() ?? '';
  return text.length < minimum || text.length > maximum
      ? '$label must be $minimum–$maximum characters.'
      : null;
}

String? contentLink(String? value, {bool required = true}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty && !required) return null;
  final uri = Uri.tryParse(text);
  if (text.length > 2000 ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      !uri.host.contains('.') ||
      uri.userInfo.isNotEmpty ||
      RegExp(r'\s').hasMatch(text)) {
    return 'Enter a complete HTTPS link, for example https://example.com/lesson.';
  }
  return null;
}

List<String> parseTags(String value) => value
    .split(',')
    .map((t) => t.trim().toLowerCase())
    .where((t) => t.isNotEmpty)
    .toSet()
    .toList();
