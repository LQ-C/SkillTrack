import 'package:skilltrack/features/tutor_management/utils/qualification_file.dart';

class MentorRegistration {
  const MentorRegistration({
    required this.expertise,
    required this.qualification,
  });
  final String expertise;
  final QualificationDocument qualification;
}
