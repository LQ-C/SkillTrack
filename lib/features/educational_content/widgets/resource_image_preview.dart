import 'dart:async';
import 'package:flutter/material.dart';
import '../../../app/router/app_router.dart';
import '../../../app/app_theme.dart';
import '../viewmodels/resource_detail_view_model.dart';

class ResourceImagePreview extends StatefulWidget {
  const ResourceImagePreview({super.key, required this.model});
  final ResourceDetailViewModel model;
  @override
  State<ResourceImagePreview> createState() => _ResourceImagePreviewState();
}

class _ResourceImagePreviewState extends State<ResourceImagePreview> {
  Route<void>? _fullscreen;
  final _images = <ImageProvider>{};

  Future<void> _enlarge() async {
    if (_fullscreen != null) return;
    // Recheck RLS and refresh the signed URL before enlarging protected media.
    unawaited(widget.model.loadImage());
    final route = AppRouter.featureRoute<void>(
      builder: (context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          iconTheme: const IconThemeData(color: Colors.white),
          titleTextStyle: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(color: Colors.white),
          title: const Text('Image'),
          leading: IconButton(
            tooltip: 'Close image',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ),
        body: SafeArea(
          child: AnimatedBuilder(
            animation: widget.model,
            builder: (context, _) => InteractiveViewer(
              key: const ValueKey('resource-image-zoom'),
              minScale: 1,
              maxScale: 5,
              child: SizedBox.expand(
                child: _ResourceImage(
                  model: widget.model,
                  fullscreen: true,
                  remember: _images.add,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _fullscreen = route;
    await Navigator.of(context).push<void>(route);
    if (mounted) _fullscreen = null;
  }

  @override
  void dispose() {
    final route = _fullscreen;
    if (route != null && route.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    // Remove this page's protected decoded images from Flutter's shared cache.
    for (final provider in _images) {
      unawaited(provider.evict());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.model,
    builder: (context, _) => ClipRRect(
      borderRadius: AppTheme.cardRadius,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: _ResourceImage(
          model: widget.model,
          onEnlarge: _enlarge,
          remember: _images.add,
        ),
      ),
    ),
  );
}

class _ResourceImage extends StatelessWidget {
  const _ResourceImage({
    required this.model,
    required this.remember,
    this.fullscreen = false,
    this.onEnlarge,
  });
  final ResourceDetailViewModel model;
  final bool fullscreen;
  final VoidCallback? onEnlarge;
  final void Function(ImageProvider) remember;

  Widget _loading() => const SizedBox(
    height: 180,
    width: double.infinity,
    child: Center(
      child: CircularProgressIndicator(semanticsLabel: 'Loading image'),
    ),
  );
  Widget _failure(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image_outlined,
              color: fullscreen
                  ? Colors.white70
                  : Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              model.imageError ??
                  'Could not load this image. Retry to check access and refresh the image link.',
              textAlign: TextAlign.center,
              style: fullscreen ? const TextStyle(color: Colors.white) : null,
            ),
            TextButton(
              style: fullscreen
                  ? TextButton.styleFrom(foregroundColor: Colors.white)
                  : null,
              onPressed: model.imageLoading ? null : model.loadImage,
              child: const Text('Retry image'),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final url = model.imageUrl;
    if (model.imageLoading) return _loading();
    if (url == null) return _failure(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final pixels =
            (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(1, fullscreen ? 4096 : 2048);
        final provider = ResizeImage(
          NetworkImage(url),
          width: pixels,
          height:
              (constraints.maxHeight * MediaQuery.devicePixelRatioOf(context))
                  .round()
                  .clamp(1, fullscreen ? 4096 : 2048),
          policy: ResizeImagePolicy.fit,
        );
        remember(provider);
        return Image(
          key: ValueKey((url, fullscreen)),
          image: provider,
          fit: BoxFit.contain,
          width: double.infinity,
          semanticLabel: fullscreen
              ? 'Resource image. Pinch to zoom and drag to pan.'
              : 'Resource image',
          errorBuilder: (context, _, _) => _failure(context),
          frameBuilder: (context, child, frame, synchronous) {
            if (frame == null && !synchronous) return _loading();
            if (fullscreen) return child;
            return Semantics(
              button: true,
              label: 'Enlarge resource image',
              child: InkWell(onTap: onEnlarge, child: child),
            );
          },
        );
      },
    );
  }
}
