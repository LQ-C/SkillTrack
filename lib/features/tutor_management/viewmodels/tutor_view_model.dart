import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/core/utils/view_model.dart';
import '../models/tutor_models.dart';
import '../repositories/tutor_repository.dart';

String tutorError(Object e) {
  if (e is FormatException) return e.message;
  if (e is StorageException) {
    return 'Could not upload your qualification document. Check your connection and try again. If it continues, contact the platform administrator.';
  }
  if (e is PostgrestException) {
    if (['PGRST202', 'PGRST205', '42P01', '42883'].contains(e.code)) {
      return 'Mentorship is not available yet. Please contact the platform administrator.';
    }
    if (e.code == 'P0001') return e.message;
    if (e.code == '23505') {
      return 'This session has already been requested, booked or reviewed. Refresh to see its status.';
    }
    if (e.code == '23514') return 'Check your information and try again.';
    if (e.code == '42501') {
      return 'This action is not allowed. Check your account role and sign-in status.';
    }
  }
  return 'Could not complete the request. Check your connection and try again.';
}

class TutorViewModel extends ViewModel {
  TutorViewModel(this.repository);
  final TutorRepository repository;
  TutorProfile? profile;
  String? role;
  List<Mentor> mentors = [];
  List<MentorSlot> slots = [];
  List<MentorshipSession> sessions = [];
  List<MentorFeedback> feedback = [];
  bool loading = true, busy = false;
  String? error, success;
  int _request = 0;
  Future<void> load() async {
    final request = ++_request;
    update(() {
      loading = true;
      error = null;
    });
    try {
      final accountRole = await repository.role();
      final p = await repository.profile();
      final m = accountRole == 'student'
          ? await repository.directory()
          : <Mentor>[];
      final s = await repository.sessions();
      final a = p == null
          ? <MentorSlot>[]
          : await repository.slots(repository.userId);
      final f = p == null
          ? <MentorFeedback>[]
          : await repository.feedback(repository.userId);
      if (request != _request) return;
      update(() {
        role = accountRole;
        profile = p;
        mentors = m;
        sessions = s;
        slots = a;
        feedback = f;
      });
    } catch (e) {
      if (request == _request) update(() => error = tutorError(e));
    } finally {
      if (request == _request) update(() => loading = false);
    }
  }

  Future<bool> action(Future<void> Function() work, String message) async {
    if (busy || !isActive) return false;
    update(() {
      busy = true;
      error = null;
      success = null;
    });
    try {
      await work();
      await load();
      update(() => success = message);
      return true;
    } catch (e) {
      update(() => error = tutorError(e));
      return false;
    } finally {
      update(() => busy = false);
    }
  }
}
