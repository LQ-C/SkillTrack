import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:skilltrack/app/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skilltrack/features/educational_content/models/learning_resource.dart';
import 'package:skilltrack/features/educational_content/repositories/content_repository.dart';
import 'package:skilltrack/features/educational_content/viewmodels/resource_detail_view_model.dart';
import 'package:skilltrack/features/educational_content/views/resource_detail.dart';
import 'package:skilltrack/features/educational_content/widgets/resource_image_preview.dart';
import 'content_test.dart' show FakeContentRepository;

LearningResource uploaded({
  String extension = 'png',
  String kind = 'Reading',
  bool hidden = false,
  String status = 'published',
}) => LearningResource(
  id: 'image',
  authorId: 'mentor',
  authorName: 'Mentor',
  title: 'Image lesson',
  summary: 'Fixture summary',
  category: 'Programming',
  level: 'Beginner',
  kind: kind,
  body: 'Protected notes',
  link: '',
  tags: [],
  status: status,
  hidden: hidden,
  attachmentPath: 'mentor/fixture.$extension',
);

class ImageRepository extends FakeContentRepository
    implements ResourceOpeningRepository, ContentSessionSource {
  LearningResource value = uploaded();
  final changes = StreamController<String?>.broadcast(sync: true);
  @override
  Stream<String?> get userChanges => changes.stream;
  bool entitled = true, failSign = false;
  int gets = 0, signs = 0;
  Completer<String>? pendingUrl;
  Completer<LearningResource>? pendingResource;
  @override
  Future<LearningResource> get(String id) async {
    gets++;
    if (!entitled) throw StateError('Access denied');
    return pendingResource == null ? value : pendingResource!.future;
  }

  @override
  bool isImageFile(LearningResource resource) =>
      resource.kind == 'Reading' &&
      {
        'png',
        'jpg',
        'jpeg',
      }.contains(resource.attachmentPath?.split('.').last.toLowerCase());
  @override
  Future<String> primaryFileUrl(LearningResource resource) async {
    signs++;
    if (failSign) throw StateError('Unavailable');
    return pendingUrl == null
        ? 'https://fixture.invalid/image-$signs.png'
        : pendingUrl!.future;
  }
}

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class FixtureImageClient implements HttpClient {
  bool fail = false;
  int reads = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    reads++;
    return FixtureImageRequest(this);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FixtureImageRequest implements HttpClientRequest {
  FixtureImageRequest(this.client);
  final FixtureImageClient client;
  @override
  Future<HttpClientResponse> close() async => FixtureImageResponse(client.fail);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FixtureImageResponse extends Stream<List<int>>
    implements HttpClientResponse {
  FixtureImageResponse(this.fail);
  final bool fail;
  @override
  int get statusCode => fail ? 403 : 200;
  @override
  int get contentLength => png.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(png).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> decodeImages(WidgetTester tester) async {
  // Await actual engine decode completion instead of advancing a fake clock
  // while a codec is still pending under parallel suite load.
  await tester.runAsync(() async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (PaintingBinding.instance.imageCache.pendingImageCount > 0 &&
        DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  group('resource image state', () {
    late ImageRepository repo;
    late ResourceDetailViewModel vm;
    setUp(() {
      repo = ImageRepository();
      vm = ResourceDetailViewModel(repo, 'image', bookmarked: false);
    });
    tearDown(() async {
      vm.dispose();
      await repo.changes.close();
    });
    test(
      'authorised image signs only after full-row read and retry rechecks access',
      () async {
        repo.pendingUrl = Completer();
        final load = vm.load();
        await Future<void>.delayed(Duration.zero);
        expect(vm.loading, false);
        expect(vm.isImage, true);
        expect(vm.imageLoading, true);
        expect(vm.imageUrl, isNull);
        repo.pendingUrl!.complete('https://fixture.invalid/one.png');
        await load;
        expect(repo.gets, 1);
        expect(repo.signs, 1);
        expect(vm.imageUrl, endsWith('one.png'));
        repo.pendingUrl = null;
        repo.failSign = true;
        await vm.loadImage();
        expect(vm.imageUrl, isNull);
        expect(vm.imageError, isNotNull);
        expect(vm.resource, isNotNull);
        repo.failSign = false;
        await vm.loadImage();
        expect(repo.gets, 3);
        expect(repo.signs, 3);
        expect(vm.imageError, isNull);
        expect(vm.imageUrl, endsWith('image-3.png'));
      },
    );
    test(
      'unpaid and hidden resources cannot request protected image URLs',
      () async {
        repo.entitled = false;
        await vm.load();
        expect(vm.resource, isNull);
        expect(repo.signs, 0);
        repo.entitled = true;
        repo.value = uploaded(hidden: true);
        await vm.load();
        expect(vm.resource, isNull);
        expect(repo.signs, 0);
        repo.value = uploaded(status: 'draft');
        await vm.load();
        expect(repo.signs, 0);
      },
    );
    test(
      'revoked access clears protected details and does not sign again',
      () async {
        await vm.load();
        repo.entitled = false;
        await vm.loadImage();
        expect(vm.resource, isNull);
        expect(vm.imageUrl, isNull);
        expect(repo.signs, 1);
      },
    );
    test('PDF, guide and video do not start image requests', () async {
      for (final value in [
        uploaded(extension: 'pdf'),
        uploaded(kind: 'Guide'),
        uploaded(extension: 'mp4', kind: 'Video'),
      ]) {
        repo.value = value;
        await vm.load();
        expect(vm.isImage, false);
        expect(vm.imageUrl, isNull);
      }
      expect(repo.signs, 0);
    });
    test(
      'duplicate loads/retries share requests and resource replacement drops old signing response',
      () async {
        repo.pendingUrl = Completer();
        final old = vm.load();
        await Future<void>.delayed(Duration.zero);
        final duplicate = vm.load();
        final image = vm.loadImage();
        expect(repo.gets, 1);
        expect(repo.signs, 1);
        repo.pendingUrl!.complete('https://fixture.invalid/old.png');
        await Future.wait([old, duplicate, image]);
        repo.pendingUrl = Completer();
        final retry = vm.loadImage();
        await Future<void>.delayed(Duration.zero);
        repo.value = uploaded(extension: 'pdf');
        final refresh = vm.load();
        await refresh;
        repo.pendingUrl!.complete('https://fixture.invalid/stale.png');
        await retry;
        expect(vm.isImage, false);
        expect(vm.imageUrl, isNull);
        expect(vm.imageLoading, false);
      },
    );
    test(
      'logout/account change ignores late resource and URL results',
      () async {
        repo.pendingResource = Completer();
        final load = vm.load();
        repo.userId = 'another';
        repo.changes.add('another');
        repo.pendingResource!.complete(uploaded());
        await load;
        expect(vm.resource, isNull);
        expect(repo.signs, 0);
        repo.pendingResource = null;
        await vm.load();
        repo.pendingUrl = Completer();
        final image = vm.loadImage();
        await Future<void>.delayed(Duration.zero);
        repo.userId = '';
        repo.changes.add(null);
        repo.pendingUrl!.complete('https://fixture.invalid/late.png');
        await image;
        expect(vm.resource, isNull);
        expect(vm.imageUrl, isNull);
        expect(vm.imageLoading, false);
      },
    );
    test('disposed ViewModel ignores pending signing', () async {
      repo.pendingUrl = Completer();
      final load = vm.load();
      await Future<void>.delayed(Duration.zero);
      vm.dispose();
      repo.pendingUrl!.complete('https://fixture.invalid/late.png');
      await load;
      expect(vm.imageUrl, isNull);
      // Avoid disposing the same notifier twice in tearDown.
      vm = ResourceDetailViewModel(repo, 'image', bookmarked: false);
    });
  });
  group('image widget', () {
    late ImageRepository repo;
    late FixtureImageClient client;
    setUp(() {
      repo = ImageRepository();
      client = FixtureImageClient();
      debugNetworkImageHttpClientProvider = () => client;
    });
    tearDown(() async {
      debugNetworkImageHttpClientProvider = null;
      PaintingBinding.instance.imageCache.clear();
      await repo.changes.close();
    });
    Future<void> show(WidgetTester tester, {double textScale = 1}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: ResourceDetail(
            repository: repo,
            id: 'image',
            bookmarked: false,
            canPublish: false,
          ),
        ),
      );
      await tester.pump();
      await decodeImages(tester);
    }

    testWidgets(
      'image replaces generic opening; enlarge supports zoom, close and system Back',
      (tester) async {
        await show(tester);
        expect(find.byType(ResourceImagePreview), findsOneWidget);
        expect(find.text('Open reading file'), findsNothing);
        expect(find.bySemanticsLabel('Enlarge resource image'), findsOneWidget);
        await tester.tap(find.bySemanticsLabel('Enlarge resource image'));
        await tester.pump();
        await decodeImages(tester);
        expect(repo.gets, 2);
        expect(repo.signs, 2);
        final bar = tester.widget<AppBar>(find.byType(AppBar).last);
        expect(bar.iconTheme?.color, Colors.white);
        expect(bar.titleTextStyle?.color, Colors.white);
        final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        expect(viewer.panEnabled, true);
        expect(viewer.scaleEnabled, true);
        expect(viewer.maxScale, greaterThan(1));
        final center = tester.getCenter(find.byType(InteractiveViewer));
        final left = await tester.startGesture(
          center - const Offset(30, 0),
          pointer: 1,
        );
        final right = await tester.startGesture(
          center + const Offset(30, 0),
          pointer: 2,
        );
        await left.moveBy(const Offset(-80, 0));
        await right.moveBy(const Offset(80, 0));
        await tester.pump();
        final transform = tester.widget<Transform>(
          find
              .descendant(
                of: find.byType(InteractiveViewer),
                matching: find.byType(Transform),
              )
              .first,
        );
        expect(transform.transform.getMaxScaleOnAxis(), greaterThan(1));
        await left.up();
        await right.up();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Close image'));
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsNothing);
        await tester.tap(find.bySemanticsLabel('Enlarge resource image'));
        await tester.pump();
        await decodeImages(tester);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsNothing);
        expect(find.text('Image lesson'), findsOneWidget);
        debugNetworkImageHttpClientProvider = null;
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
    testWidgets(
      'network image error offers authorised Retry with a fresh signed URL',
      (tester) async {
        client.fail = true;
        await show(tester);
        expect(find.text('Retry image'), findsOneWidget);
        expect(repo.signs, 1);
        client.fail = false;
        await tester.tap(find.text('Retry image'));
        await tester.pump();
        await decodeImages(tester);
        expect(repo.gets, 2);
        expect(repo.signs, 2);
        expect(find.text('Retry image'), findsNothing);
        expect(find.bySemanticsLabel('Enlarge resource image'), findsOneWidget);
        debugNetworkImageHttpClientProvider = null;
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
    testWidgets(
      'unpaid detail never creates Image or signs a URL; PDF keeps file action',
      (tester) async {
        repo.entitled = false;
        await show(tester);
        expect(find.byType(Image), findsNothing);
        expect(repo.signs, 0);
        expect(client.reads, 0);
        repo.entitled = true;
        repo.value = uploaded(extension: 'pdf');
        await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Open reading file'), findsOneWidget);
        expect(find.byType(ResourceImagePreview), findsNothing);
        debugNetworkImageHttpClientProvider = null;
      },
    );
    testWidgets('image error and retry fit narrow screens with large text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      repo.failSign = true;
      await show(tester, textScale: 2);
      expect(find.text('Retry image'), findsOneWidget);
      expect(tester.takeException(), isNull);
      repo.failSign = false;
      await tester.ensureVisible(find.text('Retry image'));
      await tester.tap(find.text('Retry image'));
      await tester.pump();
      await decodeImages(tester);
      await tester.scrollUntilVisible(
        find.byType(ResourceImagePreview),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await decodeImages(tester);
      expect(find.bySemanticsLabel('Enlarge resource image'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugNetworkImageHttpClientProvider = null;
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
    testWidgets(
      'signout while enlarged removes viewer and clears protected content',
      (tester) async {
        await show(tester);
        await tester.tap(find.bySemanticsLabel('Enlarge resource image'));
        await tester.pump();
        await decodeImages(tester);
        repo.userId = '';
        repo.changes.add(null);
        await tester.pumpAndSettle();
        expect(find.byType(InteractiveViewer), findsNothing);
        expect(find.text('Protected notes'), findsNothing);
        expect(tester.takeException(), isNull);
        debugNetworkImageHttpClientProvider = null;
      },
    );
  });
}
