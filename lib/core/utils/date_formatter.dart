class DateFormatter {
  static String relative(DateTime date, {DateTime? now}) {
    final elapsed = (now ?? DateTime.now()).toLocal().difference(
      date.toLocal(),
    );
    if (elapsed.isNegative) return short(date);
    if (elapsed.inMinutes < 1) return 'Just now';
    if (elapsed.inHours < 1) {
      return '${elapsed.inMinutes} ${elapsed.inMinutes == 1 ? 'minute' : 'minutes'} ago';
    }
    if (elapsed.inDays < 1) {
      return '${elapsed.inHours} ${elapsed.inHours == 1 ? 'hour' : 'hours'} ago';
    }
    return '${elapsed.inDays} ${elapsed.inDays == 1 ? 'day' : 'days'} ago';
  }

  static String short(DateTime? date) {
    if (date == null) return 'No deadline';
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/${local.year}';
  }
}
