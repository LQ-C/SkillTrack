import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import '../../../app/app_theme.dart';
import '../repositories/content_repository.dart';
import '../viewmodels/pdf_reader_view_model.dart';
import '../widgets/content_notice.dart';

class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({
    super.key,
    required this.repository,
    required this.id,
    required this.title,
  });
  final ContentRepository repository;
  final String id, title;
  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  final viewer = PdfViewerController();
  late final model = PdfReaderViewModel(widget.repository, widget.id);
  @override
  void initState() {
    super.initState();
    model.addListener(_changed);
    model.load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final document = model.document;
    final version = model.version;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (model.loading)
              const Expanded(
                child: Center(
                  child: CircularProgressIndicator(
                    semanticsLabel: 'Loading PDF',
                  ),
                ),
              )
            else if (document == null)
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ContentNotice(
                            model.error ?? 'PDF unavailable.',
                            error: true,
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: model.load,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry PDF'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: PdfViewer(
                  PdfDocumentRefDirect(
                    document,
                    autoDispose: false,
                    key: PdfDocumentRefKey('pdf:${identityHashCode(document)}'),
                  ),
                  key: ValueKey(version),
                  controller: viewer,
                  params: PdfViewerParams(
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerLow,
                    textSelectionParams: const PdfTextSelectionParams(
                      enabled: false,
                    ),
                    linkHandlerParams: PdfLinkHandlerParams(onLinkTap: (_) {}),
                    onViewerReady: (document, _) =>
                        model.rendered(version, document.pages.length),
                    onPageChanged: (page) => model.pageChanged(version, page),
                    loadingBannerBuilder: (_, _, _) => const Center(
                      child: CircularProgressIndicator(
                        semanticsLabel: 'Rendering PDF',
                      ),
                    ),
                    errorBannerBuilder: (context, error, stack, ref) {
                      // Defer notifications until this build finishes; never display raw
                      // engine errors, which may include private data.
                      WidgetsBinding.instance.addPostFrameCallback(
                        (_) => model.renderFailed(version),
                      );
                      return const Center(child: Text('Unable to render PDF.'));
                    },
                  ),
                ),
              ),
            if (document != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    IconButton(
                      tooltip: 'Zoom out',
                      icon: const Icon(Icons.zoom_out),
                      onPressed: viewer.isReady
                          ? () {
                              if (viewer.isReady) {
                                viewer.zoomDown(
                                  duration: AppTheme.motionDuration(context),
                                );
                              }
                            }
                          : null,
                    ),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        model.pages == 0
                            ? 'Opening document…'
                            : 'Page ${model.page} of ${model.pages}',
                      ),
                    ),
                    IconButton(
                      tooltip: 'Zoom in',
                      icon: const Icon(Icons.zoom_in),
                      onPressed: viewer.isReady
                          ? () {
                              if (viewer.isReady) {
                                viewer.zoomUp(
                                  duration: AppTheme.motionDuration(context),
                                );
                              }
                            }
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
