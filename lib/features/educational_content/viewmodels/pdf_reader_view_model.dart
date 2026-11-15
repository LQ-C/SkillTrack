import 'package:pdfrx/pdfrx.dart';
import 'dart:async';
import 'dart:typed_data';
import '../../../core/utils/view_model.dart';
import '../repositories/content_repository.dart';

class PdfReaderViewModel extends ViewModel {
  PdfReaderViewModel(
    this.repository,
    this.id, {
    Future<PdfDocument> Function(Uint8List)? openDocument,
  }) : _openDocument = openDocument ?? _open {
    _owner = _user;
    if (repository is ContentSessionSource) {
      _session = (repository as ContentSessionSource).userChanges.listen((
        user,
      ) {
        if (user == _owner || !isActive) return;
        _version++;
        _pending = null;
        update(() {
          final old = document;
          document = null;
          unawaited(old?.dispose());
          loading = false;
          error = 'Your account changed. Return to the resource and reopen it.';
        });
      });
    }
  }
  static Future<PdfDocument> _open(Uint8List bytes) async {
    await pdfrxFlutterInitialize();
    return PdfDocument.openData(bytes, passwordProvider: () => null);
  }

  final Future<PdfDocument> Function(Uint8List) _openDocument;
  final ContentRepository repository;
  final String id;
  String? _owner;
  StreamSubscription<String?>? _session;
  int _version = 0;
  int get version => _version;
  int page = 1, pages = 0;
  PdfDocument? document;
  bool loading = true;
  String? error;
  Future<void>? _pending;
  String? get _user {
    try {
      return repository.userId;
    } catch (_) {
      return null;
    }
  }

  bool _valid(int version) =>
      isActive && version == _version && _owner != null && _user == _owner;
  Future<void> load() {
    if (_pending != null) return _pending!;
    if (!_valid(_version)) return Future.value();
    late final Future<void> pending;
    pending = _load().whenComplete(() {
      if (identical(_pending, pending)) _pending = null;
    });
    return _pending = pending;
  }

  Future<void> _load() async {
    final version = ++_version;
    update(() {
      loading = true;
      error = null;
      final old = document;
      document = null;
      unawaited(old?.dispose());
      pages = 0;
      page = 1;
    });
    var downloading = true;
    try {
      if (repository is! ResourcePdfRepository) {
        throw StateError('PDF unavailable.');
      }
      final result = await (repository as ResourcePdfRepository)
          .downloadPdf(id)
          .timeout(const Duration(seconds: 50));
      if (!_valid(version)) return;
      downloading = false;
      var expired = false;
      final opened = await _openDocument(result)
          .then((document) {
            if (expired) unawaited(document.dispose());
            return document;
          })
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              expired = true;
              throw TimeoutException('PDF opening timed out.');
            },
          );
      if (!_valid(version)) {
        await opened.dispose();
        return;
      }
      if (opened.pages.isEmpty) {
        await opened.dispose();
        throw const FormatException('This PDF has no readable pages.');
      }
      update(() {
        document = opened;
        pages = opened.pages.length;
      });
    } catch (failure) {
      if (_valid(version)) {
        update(
          () => error = downloading && failure is FormatException
              ? failure.message
              : 'Could not open this PDF. Check access and connection. The file may be corrupt, unsupported or password-protected.',
        );
      }
    } finally {
      if (_valid(version)) update(() => loading = false);
    }
  }

  void rendered(int version, int count) {
    if (_valid(version)) update(() => pages = count);
  }

  void pageChanged(int version, int? value) {
    if (_valid(version) && value != null && value != page) {
      update(() => page = value);
    }
  }

  void renderFailed(int version) {
    if (!_valid(version)) return;
    update(() {
      final old = document;
      document = null;
      unawaited(old?.dispose());
      error =
          'This PDF cannot be displayed. It may be corrupt, unsupported or password-protected. Retry, or ask the mentor for an unlocked PDF.';
    });
  }

  @override
  void dispose() {
    _version++;
    final old = document;
    document = null;
    unawaited(old?.dispose());
    _session?.cancel();
    super.dispose();
  }
}
