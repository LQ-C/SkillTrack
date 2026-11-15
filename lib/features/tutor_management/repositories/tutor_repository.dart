import '../models/tutor_models.dart';
import 'dart:typed_data';
import '../models/mentor_payment.dart';

abstract class TutorRepository {
  String get userId;
  Future<String> role();
  Future<String> uploadQualification(Uint8List bytes, String fileName);
  Future<void> removeQualification(String path);
  Future<TutorProfile?> profile();
  Future<List<Mentor>> directory();
  Future<List<MentorSlot>> slots(String mentorId);
  Future<List<MentorSlot>> availableSlots(String mentorId);
  Future<List<MentorshipSession>> sessions();
  Future<List<MentorFeedback>> feedback(String mentorId);
  Future<void> enable();
  Future<MentorPaymentOffer?> paymentOffer(String mentorId);
  Future<MentorPaymentAccess> paymentAccess(String mentorId);
  Future<List<MentorPaymentOrder>> paymentOrders();
  Future<void> savePaymentOffer(int amount);
  Future<MentorPaymentOrder> prepareDemoPayment(String mentorId);
  Future<MentorPaymentOrder> prepareSessionPayment(String slotId);
  Future<void> completeDemoPayment(String orderId, String outcome);
  Future<void> refreshPayments();
  Future<void> cancelMentorPackage(String mentorId);
  Future<bool> learnerLibraryAccess(String learnerId);
  Future<void> setLearnerLibraryAccess(String learnerId, bool grant);
  Future<void> publishWithSchedule({
    required String headline,
    required String expertise,
    required String experience,
    required String credentialUrl,
    required String preferences,
    required List<WeeklyAvailability> availability,
    required int utcOffsetMinutes,
  });
  Future<void> saveProfile({
    required String headline,
    required String expertise,
    required String experience,
    required String credentialUrl,
    required String qualificationPath,
    required String preferences,
    required bool submit,
  });
  Future<void> saveSlot(DateTime start, DateTime end, {String? id});
  Future<void> deleteSlot(String id);
  Future<void> request(String slotId, String message);
  Future<void> respond(String requestId, String status);
  Future<void> review(String requestId, int rating, String review);
}

abstract interface class TutorSessionSource {
  Stream<String?> get userChanges;
}
