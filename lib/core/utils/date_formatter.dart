class DateFormatter {
  // Malaysia has a fixed UTC+08 offset. Wall values below carry calendar
  // components for pickers/formatting only (UTC-marked, not a real instant).
  // Use fromMalaysia for persistence; never call toLocal on these wall values.
  static const malaysiaOffset = Duration(hours: 8);

  static DateTime malaysiaTime(DateTime instant) =>
      instant.toUtc().add(malaysiaOffset);

  static DateTime fromMalaysia(DateTime wall) => DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.millisecond,
    wall.microsecond,
  ).subtract(malaysiaOffset);

  static DateTime dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static DateTime today({DateTime? now}) =>
      dateOnly(malaysiaTime(now ?? DateTime.now()));

  static DateTime endOfDateUtc(DateTime date) => DateTime.utc(
    date.year,
    date.month,
    date.day + 1,
  ).subtract(malaysiaOffset).subtract(const Duration(milliseconds: 1));

  static String relative(DateTime date, {DateTime? now}) {
    final elapsed = (now ?? DateTime.now()).toUtc().difference(date.toUtc());
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
    return calendarDate(malaysiaTime(date));
  }

  // Project/draft dates are calendar values, not timestamp instants.
  static String calendarDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';
}
