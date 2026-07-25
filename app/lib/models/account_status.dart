class AccountStatus {
  const AccountStatus({
    required this.status,
    required this.expiresAt,
    this.subscriptionId,
    this.keyCode,
  });

  factory AccountStatus.fromJson(Map<String, dynamic> json) {
    return AccountStatus(
      status: json['status'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      subscriptionId: json['subscriptionId'] as String?,
      keyCode: json['keyCode'] as String?,
    );
  }

  final String status;
  final DateTime expiresAt;

  /// Remnawave subscription id (shortUuid) of the connected key, or null when
  /// the session has no subscription yet. Shown in Settings so a user with
  /// several bought keys can tell which one is active.
  final String? subscriptionId;

  /// The "Код для FatVPN App" the bot shows for this account, kept in sync by
  /// the bot. Preferred over [subscriptionId] in Settings so a pairing session
  /// (where no code was pasted locally) still shows the exact code the bot
  /// presents. Null for legacy/token sessions or a bot that doesn't send it.
  final String? keyCode;

  bool get isActive => status == 'active';
}
