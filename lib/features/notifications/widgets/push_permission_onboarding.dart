import '../../../app/router/navigation_observers.dart';
import '../../../core/constants/app_constants.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../viewmodels/push_notification_controller.dart';

/// Mounted inside AccountGate: authentication/recovery screens never prompt.
class PushPermissionOnboarding extends StatefulWidget {
  const PushPermissionOnboarding({
    super.key,
    required this.controller,
    required this.child,
  });
  final PushNotificationController controller;
  final Widget child;
  @override
  State<PushPermissionOnboarding> createState() =>
      _PushPermissionOnboardingState();
}

class _PushPermissionOnboardingState extends State<PushPermissionOnboarding>
    with WidgetsBindingObserver, RouteAware {
  DialogRoute<bool>? _dialog;
  ModalRoute<dynamic>? _mainRoute;
  bool _checked = false;
  PushPermissionOffer? _offer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _mainRoute) {
      videoRouteObserver.unsubscribe(this);
      _mainRoute = route;
      if (route != null) videoRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didPopNext() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _changed() {
    final offer = _offer, route = _dialog;
    if (offer != null &&
        route != null &&
        !widget.controller.isOfferCurrent(offer)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
  }

  Future<void> _check() async {
    if (!mounted ||
        _checked ||
        _dialog != null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _checked = true;
    final controller = widget.controller;
    final offer = await controller.prepareOnboarding();
    if (!mounted ||
        offer == null ||
        !controller.isOfferCurrent(offer) ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _offer = offer;
    final route = DialogRoute<bool>(
      context: context,
      barrierDismissible: false,
      settings: const RouteSettings(name: '/notifications/permission'),
      builder: (_) => PushPermissionExplanation(settings: offer.settings),
    );
    _dialog = route;
    final enable = await Navigator.of(context).push<bool>(route);
    _dialog = null;
    _offer = null;
    if (!mounted) return;
    if (enable == true) {
      await controller.acceptOffer(offer);
      if (mounted &&
          controller.errorMessage != null &&
          controller.isOfferCurrent(offer)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(controller.errorMessage!)));
      }
    } else {
      controller.dismissOffer(offer);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.controller.resumePermissionOnboarding());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    videoRouteObserver.unsubscribe(this);
    widget.controller.removeListener(_changed);
    final route = _dialog;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class PushPermissionExplanation extends StatelessWidget {
  const PushPermissionExplanation({super.key, required this.settings});
  final bool settings;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text(PushPermissionMessages.title),
    content: Text(
      settings
          ? PushPermissionMessages.settingsExplanation
          : PushPermissionMessages.explanation,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text(PushPermissionMessages.notNow),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        child: Text(
          settings
              ? PushPermissionMessages.settings
              : PushPermissionMessages.enable,
        ),
      ),
    ],
  );
}
