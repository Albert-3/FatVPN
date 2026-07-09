class AccountStatus {
  const AccountStatus({
    required this.status,
    required this.expiresAt,
    this.subscriptionId,
  });

  factory AccountStatus.fromJson(Map<String, dynamic> json) {
    return AccountStatus(
      status: json['status'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      subscriptionId: json['subscriptionId'] as String?,
    );
  }

  final String status;
  final DateTime expiresAt;

  /// Remnawave subscription id (shortUuid) of the connected key, or null when
  /// the session has no subscription yet. Shown in Settings so a user with
  /// several bought keys can tell which one is active.
  final String? subscriptionId;

  bool get isActive => status == 'active';
}
