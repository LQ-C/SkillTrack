import 'package:flutter/material.dart';
import '../services/account_service.dart';
import 'package:skilltrack/features/tutor_management/repositories/tutor_repository.dart';

// Qualification review is temporarily disabled. Email authentication still applies.
class MentorAccessGate extends StatelessWidget {
  const MentorAccessGate({
    super.key,
    required this.accounts,
    required this.tutors,
    required this.child,
  });
  final AccountService accounts;
  final TutorRepository tutors;
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}
