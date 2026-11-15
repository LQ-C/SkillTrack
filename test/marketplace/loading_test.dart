import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/tutor_management/models/mentor_payment.dart';
import 'package:skilltrack/features/tutor_management/models/tutor_models.dart';
import 'package:skilltrack/features/tutor_management/viewmodels/mentor_detail_view_model.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/educational_content/viewmodels/content_library_view_model.dart';
import 'mentor_payments_test.dart' show PaymentTutors;
import 'mentor_detail_test.dart' show Previews;
import 'content_test.dart' show FakeContentRepository, sample;

class SlowTutors extends PaymentTutors {
  final price = Completer<MentorPaymentOffer?>();
  final entitlement = Completer<MentorPaymentAccess>();
  final available = Completer<List<MentorSlot>>();
  bool priceStarted = false, accessStarted = false;
  int feedbackCalls = 0;
  @override
  Future<MentorPaymentOffer?> paymentOffer(String id) {
    priceStarted = true;
    return price.future;
  }

  @override
  Future<MentorPaymentAccess> paymentAccess(String id) {
    accessStarted = true;
    return entitlement.future;
  }

  @override
  Future<List<MentorSlot>> availableSlots(String id) => available.future;
  @override
  Future<List<MentorFeedback>> feedback(String id) async {
    feedbackCalls++;
    return [];
  }
}

class SlowLibrary extends FakeContentRepository {
  final bookmarksReady = Completer<Set<String>>();
  bool listStarted = false;
  @override
  Future<Set<String>> bookmarks() => bookmarksReady.future;
  @override
  Future<List<LearningResource>> list({
    required bool mine,
    required String search,
    String? category,
    String? level,
    String? kind,
    required int offset,
  }) async {
    listStarted = true;
    return [sample];
  }
}

void main() {
  test(
    'mentor pricing and entitlement overlap, and materials do not wait on slots',
    () async {
      final repo = SlowTutors()
        ..userId = 'student'
        ..accountRole = 'student';
      final vm = MentorDetailViewModel(repo, 'mentor', Previews());
      final pending = vm.load();
      await Future<void>.delayed(Duration.zero);
      expect(repo.priceStarted, true);
      expect(repo.accessStarted, true);
      repo.price.complete(const MentorPaymentOffer(5000));
      repo.entitlement.complete(const MentorPaymentAccess(materials: true));
      await Future<void>.delayed(Duration.zero);
      expect(vm.loadingAccount, false);
      expect(vm.unlocked, true);
      expect(vm.resources, isNotEmpty);
      expect(vm.loadingSessions, true);
      expect(repo.feedbackCalls, 0);
      repo.available.complete([]);
      await pending;
      expect(vm.loading, false);
      vm.dispose();
    },
  );
  test(
    'library requests resources while bookmarks are still pending',
    () async {
      final repo = SlowLibrary();
      final vm = ContentLibraryViewModel(repo);
      final pending = vm.load();
      await Future<void>.delayed(Duration.zero);
      expect(repo.listStarted, true);
      expect(vm.loading, true);
      repo.bookmarksReady.complete({'one'});
      await pending;
      expect(vm.resources.single.id, 'one');
      expect(vm.bookmarks, {'one'});
      expect(vm.loading, false);
      vm.dispose();
    },
  );
}
