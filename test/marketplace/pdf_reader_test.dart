import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:skilltrack/features/educational_content/repositories/content_repository.dart';
import 'package:skilltrack/features/educational_content/repositories/supabase_content_repository.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/educational_content/viewmodels/pdf_reader_view_model.dart';
import 'package:skilltrack/features/educational_content/views/pdf_reader_screen.dart';
import 'package:skilltrack/features/educational_content/views/resource_detail.dart';
import 'content_test.dart' show FakeContentRepository;
import 'session_integration_test.dart' show fixture, first;
import 'resource_bucket_split_test.dart' show resource;

final pdfBytes = Uint8List.fromList('%PDF-1.4 fixture'.codeUnits);

class MemoryPdf extends FakeContentRepository
    implements ResourcePdfRepository, ContentSessionSource {
  final changes = StreamController<String?>.broadcast(sync: true);
  @override
  Stream<String?> get userChanges => changes.stream;
  int downloads = 0;
  bool downloadFails = false;
  Completer<Uint8List>? pending;
  @override
  bool isPdfFile(LearningResource r) =>
      r.kind == 'Reading' && r.attachmentPath?.endsWith('.pdf') == true;
  @override
  Future<LearningResource> get(String id) async =>
      resource('Reading', '', attachment: 'mentor/fixture.pdf');
  @override
  Future<Uint8List> downloadPdf(String id) async {
    downloads++;
    if (downloadFails) {
      throw const FormatException('Download failed. Retry access.');
    }
    return pending == null ? pdfBytes : pending!.future;
  }
}

class Doc extends Fake implements PdfDocument {
  int closes = 0;
  @override
  List<PdfPage> get pages => [Page(), Page()];
  @override
  Future<void> dispose() async {
    closes++;
  }
}

class Page extends Fake implements PdfPage {}

class DownloadRepo extends SupabaseContentRepository {
  DownloadRepo(super.client, {required super.pdfClientFactory});
  bool allowed = true;
  int reads = 0;
  @override
  Future<LearningResource> get(String id) async {
    reads++;
    if (!allowed) throw StateError('Denied');
    return resource('Reading', '', attachment: '$first/fixture.pdf');
  }
}

void main() {
  group('authorised PDF repository', () {
    late DownloadRepo repo;
    late http.Client transport;
    late dynamic client;
    late List<http.Request> calls;
    int downloads = 0;
    int status = 200;
    Uint8List payload = pdfBytes;
    setUp(() async {
      calls = [];
      client = fixture(calls);
      await client.auth.signInWithPassword(
        email: 'first@example.test',
        password: 'Fixture1!',
      );
      downloads = 0;
      status = 200;
      payload = pdfBytes;
      repo = DownloadRepo(
        client,
        pdfClientFactory: () {
          transport = MockClient((request) async {
            downloads++;
            expect(request.followRedirects, false);
            return http.Response.bytes(payload, status);
          });
          return transport;
        },
      );
    });
    tearDown(() async {
      await client.dispose();
    });
    test(
      'read and sign precede in-memory download; expired URL retry reauthorises',
      () async {
        status = 403;
        await expectLater(repo.downloadPdf(first), throwsFormatException);
        status = 200;
        payload = pdfBytes;
        expect(await repo.downloadPdf(first), pdfBytes);
        expect(repo.reads, 2);
        expect(downloads, 2);
        expect(
          calls.where((r) => r.url.path.contains('/object/sign/')),
          hasLength(2),
        );
      },
    );
    test(
      'invalid PDF bodies and oversized documents fail before parsing',
      () async {
        payload = Uint8List.fromList('Not a PDF'.codeUnits);
        await expectLater(repo.downloadPdf(first), throwsFormatException);
        payload = Uint8List(25 * 1024 * 1024 + 1);
        await expectLater(
          repo.downloadPdf(first),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('25 MB'),
            ),
          ),
        );
      },
    );
    test('unpaid rejection prevents signing and downloading', () async {
      repo.allowed = false;
      await expectLater(repo.downloadPdf(first), throwsStateError);
      expect(downloads, 0);
      expect(calls.where((r) => r.url.path.contains('/object/sign/')), isEmpty);
    });
    test(
      'PDF classification validates location, type and attachment rather than Reading alone',
      () {
        expect(
          repo.isPdfFile(
            resource('Reading', '', attachment: '$first/file.PDF'),
          ),
          true,
        );
        for (final r in [
          resource('Reading', '', attachment: '$first/file.png'),
          resource('Video', '', attachment: '$first/file.mp4'),
          resource('Guide', '', attachment: '$first/file.pdf'),
          resource('Reading', 'https://foreign.invalid/file.pdf'),
          resource('Reading', '', attachment: '../file.pdf'),
        ]) {
          expect(repo.isPdfFile(r), false);
        }
      },
    );
  });
  group('PDF reader state', () {
    late MemoryPdf repo;
    late PdfReaderViewModel vm;
    late List<Doc> docs;
    setUp(() {
      repo = MemoryPdf();
      docs = [];
      vm = PdfReaderViewModel(
        repo,
        'pdf',
        openDocument: (_) async {
          final d = Doc();
          docs.add(d);
          return d;
        },
      );
    });
    tearDown(() async {
      vm.dispose();
      await repo.changes.close();
    });
    test(
      'loads, retains page on ordinary notifications, retries and closes replaced document',
      () async {
        await vm.load();
        expect(vm.pages, 2);
        expect(vm.loading, false);
        vm.pageChanged(vm.version, 2);
        expect(vm.page, 2);
        expect(repo.downloads, 1);
        final old = docs.single;
        await vm.load();
        expect(old.closes, 1);
        expect(repo.downloads, 2);
      },
    );
    test('failure recovers and duplicate calls share one download', () async {
      repo.downloadFails = true;
      await vm.load();
      expect(vm.error, isNotNull);
      expect(vm.loading, false);
      repo.downloadFails = false;
      repo.pending = Completer();
      final a = vm.load(), b = vm.load();
      expect(repo.downloads, 2);
      repo.pending!.complete(pdfBytes);
      await Future.wait([a, b]);
      expect(vm.document, isNotNull);
      expect(vm.error, isNull);
    });
    test(
      'account changes discard late bytes without invoking native parser',
      () async {
        repo.pending = Completer();
        final pending = vm.load();
        repo.userId = 'another';
        repo.changes.add('another');
        repo.pending!.complete(pdfBytes);
        await pending;
        expect(vm.document, isNull);
        expect(docs, isEmpty);
        expect(vm.loading, false);
      },
    );
    test('late native result after disposal is explicitly closed', () async {
      vm.dispose();
      final native = Completer<PdfDocument>();
      vm = PdfReaderViewModel(repo, 'pdf', openDocument: (_) => native.future);
      final load = vm.load();
      await Future<void>.delayed(Duration.zero);
      vm.dispose();
      final doc = Doc();
      native.complete(doc);
      await load;
      expect(doc.closes, 1);
      vm = PdfReaderViewModel(repo, 'pdf');
    });
    test(
      'signout closes open document and stale render callbacks are ignored',
      () async {
        await vm.load();
        final doc = docs.single, version = vm.version;
        repo.userId = '';
        repo.changes.add(null);
        expect(vm.document, isNull);
        expect(doc.closes, 1);
        vm.pageChanged(version, 2);
        expect(vm.page, 1);
      },
    );
    test(
      'corrupt/password protected parser failure is recoverable and sanitised',
      () async {
        vm.dispose();
        vm = PdfReaderViewModel(
          repo,
          'pdf',
          openDocument: (_) async =>
              throw const FormatException('PRIVATE PDF DATA'),
        );
        await vm.load();
        expect(vm.loading, false);
        expect(vm.error, contains('password-protected'));
        expect(vm.error, isNot(contains('PRIVATE PDF DATA')));
      },
    );
  });
  testWidgets(
    'Read PDF opens reader once, Back returns; pending download cannot open after pop',
    (tester) async {
      final repo = MemoryPdf()..pending = Completer();
      await tester.pumpWidget(
        MaterialApp(
          home: ResourceDetail(
            repository: repo,
            id: first,
            bookmarked: false,
            canPublish: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Read PDF'), findsOneWidget);
      expect(find.text('Open reading file'), findsNothing);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Read PDF'),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PdfReaderScreen), findsOneWidget);
      expect(repo.downloads, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      repo.pending!.complete(pdfBytes);
      await tester.pump();
      expect(find.byType(PdfReaderScreen), findsNothing);
      expect(find.text('Read PDF'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await repo.changes.close();
    },
  );
  testWidgets('reader download failure offers retry and fits large text', (
    tester,
  ) async {
    final repo = MemoryPdf()..downloadFails = true;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: PdfReaderScreen(
          repository: repo,
          id: 'pdf',
          title: 'A long PDF document title',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Retry PDF'), findsOneWidget);
    expect(tester.takeException(), isNull);
    repo.pending = Completer();
    repo.downloadFails = false;
    await tester.tap(find.text('Retry PDF'));
    await tester.pump();
    expect(repo.downloads, 2);
    await tester.pumpWidget(const SizedBox());
    repo.pending!.complete(pdfBytes);
    await tester.pump();
    await repo.changes.close();
  });
}
