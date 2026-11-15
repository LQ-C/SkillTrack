import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/authentication/services/account_service.dart';
import 'package:skilltrack/features/authentication/viewmodels/auth_view_model.dart';
import 'package:skilltrack/features/profile/viewmodels/profile_view_model.dart';
import 'package:skilltrack/features/dashboard/viewmodels/dashboard_view_model.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/educational_content/repositories/content_repository.dart';
import 'package:skilltrack/features/educational_content/viewmodels/content_library_view_model.dart';

class MemoryAccountService extends AccountService {
  Map<String, dynamic> profile = {
    'full_name': 'Liau',
    'date_of_birth': '2004-01-08',
    'role': 'mentor',
    'bio': '',
  };
  bool failSave = false;
  @override
  Future<Map<String, dynamic>> loadProfile() async => profile;
  @override
  Future<void> saveProfile(
    String name,
    String birthDate,
    String role,
    String bio,
  ) async {
    if (failSave) throw Exception('offline');
    profile = {
      'full_name': name,
      'date_of_birth': birthDate,
      'role': role,
      'bio': bio,
    };
  }
}

class DelayedCatalog implements ContentRepository {
  final requests = <Completer<List<LearningResource>>>[];
  @override
  String get userId => 'mentor';
  @override
  Future<({bool mentor, bool publisher})> permissions() async =>
      (mentor: true, publisher: false);
  @override
  Future<Set<String>> bookmarks() async => {};
  @override
  Future<List<LearningResource>> list({
    required bool mine,
    required String search,
    String? category,
    String? level,
    String? kind,
    required int offset,
  }) {
    final pending = Completer<List<LearningResource>>();
    requests.add(pending);
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'auth command clears busy and exposes failure without leaking exception details',
    () async {
      final vm = AuthViewModel(MemoryAccountService());
      await vm.perform(() async => throw Exception('private backend detail'));
      expect(vm.busy, isFalse);
      expect(vm.error, isTrue);
      expect(vm.message, isNot(contains('private backend detail')));
      vm.dispose();
    },
  );
  test(
    'auth command ignores duplicate submission and safely finishes after dispose',
    () async {
      final vm = AuthViewModel(MemoryAccountService());
      final pending = Completer<String?>();
      var commands = 0;
      final first = vm.perform(() {
        commands++;
        return pending.future;
      });
      await vm.perform(() async {
        commands++;
        return 'duplicate';
      });
      expect(commands, 1);
      vm.dispose();
      pending.complete('finished');
      await first;
    },
  );
  test(
    'profile viewmodel loads typed data and saves through its repository',
    () async {
      final backend = MemoryAccountService();
      final vm = ProfileViewModel(backend, backend);
      final profile = await vm.load();
      expect(profile?.name, 'Liau');
      expect(vm.loaded, isTrue);
      await vm.save('Jun', '2004-01-08', 'mentor', 'I teach Flutter.');
      expect(backend.profile['full_name'], 'Jun');
      expect(vm.error, isFalse);
      backend.failSave = true;
      await vm.save('Unsaved', '2004-01-08', 'mentor', '');
      expect(backend.profile['full_name'], 'Jun');
      expect(vm.error, isTrue);
      vm.dispose();
    },
  );
  test(
    'dashboard does not notify a disposed view after profile loads',
    () async {
      final result = Completer<Map<String, dynamic>>();
      final vm = DashboardViewModel(() => result.future);
      final load = vm.load();
      vm.dispose();
      result.complete({'full_name': 'Liau'});
      await load;
    },
  );
  test(
    'catalog ignores stale request errors after a later successful refresh',
    () async {
      final repository = DelayedCatalog();
      final vm = ContentLibraryViewModel(repository);
      final oldRequest = vm.load();
      await Future<void>.delayed(Duration.zero);
      vm.search = 'different query';
      final freshRequest = vm.load();
      await Future<void>.delayed(Duration.zero);
      expect(repository.requests.length, 2);
      repository.requests[1].complete([]);
      await freshRequest;
      repository.requests[0].completeError(Exception('old failure'));
      await oldRequest;
      expect(vm.error, isNull);
      expect(vm.loading, isFalse);
      expect(vm.mentor, isTrue);
      vm.dispose();
    },
  );
}
