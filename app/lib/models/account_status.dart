class AccountStatus {
  const AccountStatus({required this.status, required this.expiresAt});

  factory AccountStatus.fromJson(Map<String, dynamic> json) {
    return AccountStatus(
      status: json['status'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }

  final String status;
  final DateTime expiresAt;

  bool get isActive => status == 'active';
}
