import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:skilltrack/features/authentication/services/account_service.dart';
import 'package:skilltrack/features/authentication/views/auth_screen.dart';
import 'package:skilltrack/features/authentication/views/recovery_screen.dart';

import 'package:skilltrack/features/authentication/views/mentor_access_gate.dart';
import '../marketplace_dependencies.dart';

class AccountGate extends StatefulWidget {
  const AccountGate({
    super.key,
    required this.dependencies,
    required this.child,
  });
  final MarketplaceDependencies dependencies;
  final Widget child;
  @override
  State<AccountGate> createState() => _AccountGateState();
}

class _AccountGateState extends State<AccountGate> {
  late final AccountService service = widget.dependencies.accounts;
  StreamSubscription<AuthState>? subscription;
  bool recovery = false;
  String? linkError;
  @override
  void initState() {
    super.initState();
    subscription = service.client.auth.onAuthStateChange.listen(
      (state) {
        if (!mounted) return;
        setState(() {
          if (state.event == AuthChangeEvent.passwordRecovery) {
            recovery = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            });
          }
          if (state.event == AuthChangeEvent.signedOut) {
            recovery = false;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            });
          }
          linkError = null;
        });
      },
      onError: (Object error) {
        if (mounted) {
          setState(
            () => linkError =
                'This account link could not be opened. Request a new link.',
          );
        }
      },
    );
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (recovery && service.client.auth.currentSession != null) {
      return RecoveryScreen(
        service: service,
        onDone: () => setState(() => recovery = false),
      );
    }
    if (service.client.auth.currentSession == null) {
      return AuthScreen(service: service, initialMessage: linkError);
    }
    return MentorAccessGate(
      key: ValueKey(service.client.auth.currentUser!.id),
      accounts: service,
      tutors: widget.dependencies.tutors,
      child: KeyedSubtree(
        key: ValueKey(service.client.auth.currentUser!.id),
        child: widget.child,
      ),
    );
  }
}
