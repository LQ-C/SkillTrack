class TutorProfile {
  TutorProfile.fromJson(Map<String, dynamic> row)
    : availability = ((row['weekly_availability'] as List?) ?? [])
          .map((d) => WeeklyAvailability.fromJson(Map<String, dynamic>.from(d)))
          .toList(),
      sessionMinutes = (row['session_minutes'] as num?)?.toInt() ?? 60,
      utcOffsetMinutes = (row['utc_offset_minutes'] as num?)?.toInt(),
      isListed = row['is_listed'] == true,
      headline = row['headline'] as String,
      expertise = row['expertise'] as String,
      experience = row['experience'] as String,
      credentialUrl = row['credential_url'] as String,
      qualificationPath = row['qualification_path'] as String? ?? '',
      preferences = row['teaching_preferences'] as String,
      status = row['verification_status'] as String,
      reviewNote = row['review_note'] as String;
  final String headline,
      expertise,
      experience,
      credentialUrl,
      qualificationPath,
      preferences,
      status,
      reviewNote;
  final bool isListed;
  final List<WeeklyAvailability> availability;
  final int sessionMinutes;
  final int? utcOffsetMinutes;
}

class WeeklyAvailability {
  const WeeklyAvailability(this.day, this.start, this.end);
  WeeklyAvailability.fromJson(Map<String, dynamic> row)
    : day = (row['day'] as num).toInt(),
      start = (row['start'] as num).toInt(),
      end = (row['end'] as num).toInt();
  final int day, start, end;
  Map<String, dynamic> toJson() => {'day': day, 'start': start, 'end': end};
}

class Mentor {
  Mentor.fromJson(Map<String, dynamic> row)
    : id = row['user_id'] as String,
      name = row['full_name'] as String,
      headline = row['headline'] as String,
      expertise = row['expertise'] as String,
      preferences = row['teaching_preferences'] as String,
      rating = (row['average_rating'] as num?)?.toDouble(),
      reviewCount = (row['review_count'] as num).toInt();
  final String id, name, headline, expertise, preferences;
  final double? rating;
  final int reviewCount;
}

class MentorSlot {
  MentorSlot.fromJson(Map<String, dynamic> row)
    : id = row['id'] as String,
      start = DateTime.parse(row['starts_at'] as String).toLocal(),
      end = DateTime.parse(row['ends_at'] as String).toLocal(),
      utcOffsetMinutes = (row['utc_offset_minutes'] as num?)?.toInt(),
      windowStartMinutes = (row['window_start'] as num?)?.toInt(),
      windowEndMinutes = (row['window_end'] as num?)?.toInt();
  final String id;
  final DateTime start, end;
  final int? utcOffsetMinutes, windowStartMinutes, windowEndMinutes;

  DateTime _scheduleTime(DateTime value) => utcOffsetMinutes == null
      ? value
      : value.toUtc().add(Duration(minutes: utcOffsetMinutes!));

  DateTime get scheduleStart => _scheduleTime(start);
  DateTime get scheduleEnd => _scheduleTime(end);
}

class MentorshipSession {
  MentorshipSession.fromJson(Map<String, dynamic> row)
    : id = row['id'] as String,
      mentorId = row['mentor_id'] as String,
      learnerId = row['learner_id'] as String,
      mentorName = row['mentor_name'] as String,
      learnerName = row['learner_name'] as String,
      message = row['message'] as String,
      status = row['status'] as String,
      start = DateTime.parse(row['starts_at'] as String).toLocal(),
      end = DateTime.parse(row['ends_at'] as String).toLocal(),
      reviewed = row['reviewed'] == true;
  final String id,
      mentorId,
      learnerId,
      mentorName,
      learnerName,
      message,
      status;
  final DateTime start, end;
  final bool reviewed;
}

class MentorFeedback {
  MentorFeedback.fromJson(Map<String, dynamic> row)
    : rating = (row['rating'] as num).toInt(),
      review = row['review'] as String;
  final int rating;
  final String review;
}
