import 'package:flutter/material.dart';
import '../models/mentor_payment.dart';
import '../repositories/tutor_repository.dart';
import '../viewmodels/tutor_view_model.dart';

class MentorPaymentsScreen extends StatefulWidget {
  const MentorPaymentsScreen({super.key, required this.repository});
  final TutorRepository repository;
  @override
  State<MentorPaymentsScreen> createState() => _MentorPaymentsScreenState();
}

class _MentorPaymentsScreenState extends State<MentorPaymentsScreen> {
  final price = TextEditingController();
  final form = GlobalKey<FormState>();
  bool loading = true, busy = false, mentor = false;
  String? error, success;
  List<MentorPaymentOrder> orders = [];
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    price.dispose();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final role = await widget.repository.role();
      final offer = role == 'mentor'
          ? await widget.repository.paymentOffer(widget.repository.userId)
          : null;
      final rows = await widget.repository.paymentOrders();
      if (mounted) {
        setState(() {
          mentor = role == 'mentor';
          orders = rows;
          if (offer != null) {
            price.text = (offer.amount / 100).toStringAsFixed(2);
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
      success = null;
    });
    try {
      final parts = price.text.trim().split('.');
      final amount =
          int.parse(parts.first) * 100 +
          (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
      await widget.repository.savePaymentOffer(amount);
      if (mounted) {
        setState(() => success = 'Materials price saved.');
      }
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.repository.refreshPayments();
      if (mounted) await load();
    } catch (e) {
      if (mounted) setState(() => error = tutorError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Payments')),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Payment history for test transactions.',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          if (loading) const Center(child: CircularProgressIndicator()),
          if (error != null) ...[
            Text(error!),
            TextButton(
              onPressed: busy ? null : load,
              child: const Text('Try again'),
            ),
          ],
          if (success != null) Text(success!),
          if (!loading && mentor) ...[
            const Text(
              'Set your materials price',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Form(
              key: form,
              child: TextFormField(
                controller: price,
                enabled: !busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Materials price (RM)',
                  prefixText: 'RM ',
                ),
                validator: (value) {
                  final v = value?.trim() ?? '';
                  final n = double.tryParse(v);
                  return !RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(v) ||
                          n == null ||
                          n < 2 ||
                          n > 10000
                      ? 'Enter RM2.00–RM10,000.00, with up to two decimal places.'
                      : null;
                },
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : save,
              child: const Text('Save materials price'),
            ),
          ],
          if (!loading && !mentor)
            TextButton(
              onPressed: busy ? null : refresh,
              child: const Text('Refresh payment status'),
            ),
          const SizedBox(height: 24),
          const Text(
            'Payment history',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          if (!loading && orders.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('No payments yet.'),
            ),
          for (final order in orders)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      order.mentorId == widget.repository.userId
                          ? 'Student: ${order.learnerName}'
                          : 'Mentor: ${order.mentorName}',
                    ),
                    Text(
                      '${order.itemLabel} · ${order.price} · ${order.status}',
                    ),
                    Text(
                      MaterialLocalizations.of(
                        context,
                      ).formatFullDate(order.created),
                    ),
                    SelectableText(
                      'Order: ${order.id}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
