import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math';
import 'dart:typed_data';
import '../utils/qualification_file.dart';
import '../models/tutor_models.dart';
import '../models/mentor_payment.dart';
import 'tutor_repository.dart';

class SupabaseTutorRepository implements TutorRepository {
  SupabaseTutorRepository(this.client);
  final SupabaseClient client;
  @override
  String get userId => client.auth.currentUser!.id;
  @override
  Future<MentorPaymentOffer?> paymentOffer(String mentorId) async {
    // Pending checkouts keep their original quote even if the mentor edits prices.
    final pending = await client
        .from('mentor_payments')
        .select('amount')
        .eq('mentor_id', mentorId)
        .eq('learner_id', userId)
        .eq('status', 'pending')
        .inFilter('purchase_kind', ['materials', 'legacy'])
        .maybeSingle();
    if (pending != null) {
      return MentorPaymentOffer((pending['amount'] as num).toInt());
    }
    final row = await client
        .from('mentor_payment_offers')
        .select('amount')
        .eq('mentor_id', mentorId)
        .maybeSingle();
    return row == null
        ? null
        : MentorPaymentOffer((row['amount'] as num).toInt());
  }

  @override
  Future<MentorPaymentAccess> paymentAccess(String mentorId) async {
    final row = Map<String, dynamic>.from(
      await client.rpc('mentor_payment_access', params: {'p_mentor': mentorId}),
    );
    return MentorPaymentAccess(
      materials: row['materials'] == true,
      credits: (row['credits'] as num).toInt(),
    );
  }

  @override
  Future<List<MentorPaymentOrder>> paymentOrders() async =>
      (await client
              .from('mentor_payments')
              .select()
              .order('created_at', ascending: false)
              .limit(100))
          .map((r) => MentorPaymentOrder.fromJson(r))
          .toList();
  @override
  Future<void> savePaymentOffer(int amount) async {
    await client.rpc('save_mentor_payment_offer', params: {'p_amount': amount});
  }

  @override
  Future<MentorPaymentOrder> prepareDemoPayment(String mentorId) async {
    return _preparePayment('prepare_mentor_checkout', {'p_mentor': mentorId});
  }

  @override
  Future<MentorPaymentOrder> prepareSessionPayment(String slotId) =>
      _preparePayment('prepare_session_checkout', {'p_slot': slotId});

  Future<MentorPaymentOrder> _preparePayment(
    String function,
    Map<String, dynamic> params,
  ) async {
    final data = await client.rpc(function, params: params);
    final row = data is List ? data.first : data;
    return MentorPaymentOrder.fromJson(Map<String, dynamic>.from(row));
  }

  @override
  Future<void> completeDemoPayment(String orderId, String outcome) async {
    await client.rpc(
      'complete_demo_mentor_payment',
      params: {'p_order': orderId, 'p_result': outcome},
    );
  }

  @override
  Future<void> refreshPayments() async {
    await paymentOrders();
  }

  @override
  Future<void> cancelMentorPackage(String mentorId) async {
    await client.rpc('cancel_mentor_package', params: {'p_mentor': mentorId});
  }

  @override
  Future<String> role() async =>
      (await client
              .from('profiles')
              .select('role')
              .eq('id', userId)
              .single())['role']
          as String;
  @override
  Future<String> uploadQualification(Uint8List bytes, String fileName) async {
    final mime = qualificationMime(bytes, fileName);
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final ext = switch (mime) {
      'application/pdf' => 'pdf',
      'image/png' => 'png',
      _ => 'jpg',
    };
    final path = '$userId/$token.$ext';
    await client.storage
        .from('mentor-qualifications')
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: false),
        );
    return path;
  }

  @override
  Future<void> removeQualification(String path) async {
    await client.storage.from('mentor-qualifications').remove([path]);
  }

  @override
  Future<TutorProfile?> profile() async {
    final row = await client
        .from('tutor_profiles')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    return row == null ? null : TutorProfile.fromJson(row);
  }

  @override
  Future<List<Mentor>> directory() async =>
      (await client.rpc('tutor_directory') as List)
          .map((r) => Mentor.fromJson(Map<String, dynamic>.from(r)))
          .toList();
  @override
  Future<List<MentorSlot>> slots(String mentorId) async =>
      (await client
              .from('mentor_slots')
              .select()
              .eq('mentor_id', mentorId)
              .order('starts_at'))
          .map(MentorSlot.fromJson)
          .toList();
  @override
  Future<List<MentorSlot>> availableSlots(String mentorId) async =>
      (await client.rpc(
                'available_mentor_schedule',
                params: {'p_mentor': mentorId},
              )
              as List)
          .map((r) => MentorSlot.fromJson(Map<String, dynamic>.from(r)))
          .toList();
  @override
  Future<List<MentorshipSession>> sessions() async =>
      (await client.rpc('my_mentorship_sessions') as List)
          .map((r) => MentorshipSession.fromJson(Map<String, dynamic>.from(r)))
          .toList();
  @override
  Future<List<MentorFeedback>> feedback(String mentorId) async =>
      (await client.rpc('tutor_feedback', params: {'p_mentor': mentorId})
              as List)
          .map((r) => MentorFeedback.fromJson(Map<String, dynamic>.from(r)))
          .toList();
  @override
  Future<bool> learnerLibraryAccess(String learnerId) async =>
      await client.rpc(
            'my_learner_library_access',
            params: {'p_learner': learnerId},
          )
          as bool;
  @override
  Future<void> setLearnerLibraryAccess(String learnerId, bool grant) async {
    await client.rpc(
      'set_learner_library_access',
      params: {'p_learner': learnerId, 'p_grant': grant},
    );
  }

  @override
  Future<void> enable() async {
    await client.rpc('enable_tutor_profile');
  }

  @override
  Future<void> publishWithSchedule({
    required String headline,
    required String expertise,
    required String experience,
    required String credentialUrl,
    required String preferences,
    required List<WeeklyAvailability> availability,
    required int utcOffsetMinutes,
  }) async {
    await client.rpc(
      'publish_mentor_schedule',
      params: {
        'p_headline': headline,
        'p_expertise': expertise,
        'p_experience': experience,
        'p_credential_url': credentialUrl,
        'p_preferences': preferences,
        'p_availability': availability.map((d) => d.toJson()).toList(),
        'p_session_minutes':
            60, // Legacy RPC argument; time ranges define sessions.
        'p_utc_offset': utcOffsetMinutes,
      },
    );
  }

  @override
  Future<void> saveProfile({
    required String headline,
    required String expertise,
    required String experience,
    required String credentialUrl,
    required String qualificationPath,
    required String preferences,
    required bool submit,
  }) async {
    await client.rpc(
      'save_tutor_profile',
      params: {
        'p_headline': headline,
        'p_expertise': expertise,
        'p_experience': experience,
        'p_credential_url': credentialUrl,
        'p_qualification_path': qualificationPath,
        'p_preferences': preferences,
        'p_submit': submit,
      },
    );
  }

  @override
  Future<void> saveSlot(DateTime start, DateTime end, {String? id}) async {
    await client.rpc(
      'save_mentor_slot',
      params: {
        'p_id': id,
        'p_start': start.toUtc().toIso8601String(),
        'p_end': end.toUtc().toIso8601String(),
      },
    );
  }

  @override
  Future<void> deleteSlot(String id) async {
    await client.rpc('delete_mentor_slot', params: {'p_id': id});
  }

  @override
  Future<void> request(String slotId, String message) async {
    await client.rpc(
      'request_mentorship',
      params: {'p_slot': slotId, 'p_message': message},
    );
  }

  @override
  Future<void> respond(String requestId, String status) async {
    await client.rpc(
      'respond_mentorship',
      params: {'p_request': requestId, 'p_status': status},
    );
  }

  @override
  Future<void> review(String requestId, int rating, String review) async {
    await client.rpc(
      'review_mentor',
      params: {'p_request': requestId, 'p_rating': rating, 'p_review': review},
    );
  }
}
