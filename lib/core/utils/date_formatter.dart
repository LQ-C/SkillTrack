class DateFormatter {
  static String short(DateTime? date) {
    if (date == null) return 'No deadline';
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year}';
  }
}
