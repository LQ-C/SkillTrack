const sessionPaymentOffer = MentorPaymentOffer(300);

class MentorPaymentOffer {
  const MentorPaymentOffer(this.amount);
  final int amount;
  String get price => 'RM${(amount / 100).toStringAsFixed(2)}';
}

class MentorPaymentAccess {
  const MentorPaymentAccess({this.materials = false, this.credits = 0});
  final bool materials;
  final int credits;
}

class MentorPaymentOrder {
  MentorPaymentOrder.fromJson(Map<String, dynamic> row)
    : id = row['id'] as String,
      mentorId = row['mentor_id'] as String,
      mentorName = row['mentor_name'] as String,
      learnerName = row['learner_name'] as String,
      status = row['status'] as String,
      purchaseKind = row['purchase_kind'] as String? ?? 'legacy',
      amount = (row['amount'] as num).toInt(),
      created = DateTime.parse(row['created_at'] as String).toLocal();
  final String id, mentorId, mentorName, learnerName, status, purchaseKind;
  bool get isSession => purchaseKind == 'session';
  String get itemLabel => switch (purchaseKind) {
    'session' => 'Mentoring session',
    'materials' => 'Learning materials',
    _ => 'Mentor package',
  };
  final int amount;
  final DateTime created;
  String get price => 'RM${(amount / 100).toStringAsFixed(2)}';
}
