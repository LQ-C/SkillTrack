import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/mentor_payment.dart';
import '../repositories/tutor_repository.dart';
import '../viewmodels/tutor_view_model.dart';

class DemoCheckoutScreen extends StatefulWidget {
  const DemoCheckoutScreen({
    super.key,
    required this.repository,
    required this.order,
  });
  final TutorRepository repository;
  final MentorPaymentOrder order;
  @override
  State<DemoCheckoutScreen> createState() => _DemoCheckoutScreenState();
}

class _DemoCheckoutScreenState extends State<DemoCheckoutScreen> {
  final cardForm = GlobalKey<FormState>();
  MentorPaymentOrder get order => widget.order;
  bool busy = false;
  String? method;
  String? error;

  Widget cardField(
    String label,
    RegExp format,
    String errorMessage, {
    int? maxLength,
    TextInputType keyboardType = TextInputType.number,
    bool obscure = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      enabled: !busy,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: keyboardType,
      obscureText: obscure,
      maxLength: maxLength,
      decoration: InputDecoration(labelText: label),
      validator: (value) {
        final input = (value ?? '').replaceAll(' ', '');
        return format.hasMatch(input) ? null : errorMessage;
      },
    ),
  );

  Future<void> pay() async {
    if (method == 'Debit card' && !cardForm.currentState!.validate()) return;
    if (method == 'Touch ’n Go eWallet') {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Touch ’n Go eWallet'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  order.price,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: 184,
                  height: 184,
                  child: QrImageView(
                    data:
                        'SkillTrack practice payment for ${order.price}. No funds are transferred.',
                    padding: const EdgeInsets.all(16),
                    backgroundColor: Colors.white,
                    semanticsLabel: 'Practice payment QR code',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Scan with a QR reader to see the practice payment message, then approve here. No funds are transferred.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Approve payment'),
            ),
          ],
        ),
      );
      if (!mounted || approved != true) return;
    }
    await finish('success');
  }

  Future<void> finish(String outcome) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repository.completeDemoPayment(order.id, outcome);
      if (!mounted) return;
      Navigator.pop(context, outcome == 'success');
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Checkout')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              order.mentorName,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              order.price,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text(order.itemLabel),
            if (order.isSession)
              const Text('Payment confirms the selected session.'),
            const SizedBox(height: 20),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Text(
              'Payment method',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              children: [
                for (final option in const [
                  'Debit card',
                  'Touch ’n Go eWallet',
                ])
                  ChoiceChip(
                    label: Text(option),
                    selected: method == option,
                    onSelected: busy
                        ? null
                        : (selected) {
                            setState(() => method = selected ? option : null);
                          },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (method == 'Debit card')
              Form(
                key: cardForm,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Use fictitious card details. No funds are transferred.',
                    ),
                    const SizedBox(height: 12),
                    cardField(
                      'Card number',
                      RegExp(r'^\d{13,19}$'),
                      'Enter 13 to 19 digits.',
                    ),
                    cardField(
                      'Expiry (MM/YY)',
                      RegExp(r'^(0[1-9]|1[0-2])/\d{2}$'),
                      'Enter a month and year in MM/YY format.',
                      keyboardType: TextInputType.datetime,
                      maxLength: 5,
                    ),
                    cardField(
                      'CVC',
                      RegExp(r'^\d{3,4}$'),
                      'Enter 3 or 4 digits.',
                      maxLength: 4,
                      obscure: true,
                    ),
                  ],
                ),
              ),
            FilledButton(
              onPressed: busy || method == null ? null : pay,
              child: Text(busy ? 'Processing…' : 'Pay ${order.price}'),
            ),
            TextButton(
              onPressed: busy ? null : () => finish('cancelled'),
              child: const Text('Cancel payment'),
            ),
          ],
        ),
      ),
    ),
  );
}
