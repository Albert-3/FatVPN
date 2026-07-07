class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      accessToken: json['accessToken'] as String,
      // Tolerate a missing refresh token (e.g. an older stored session) — an
      // empty value forces a fresh sign-in rather than a crash.
      refreshToken: json['refreshToken'] as String? ?? '',
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }

  final String accessToken;

  /// Long-lived, revocable, rotating secret exchanged at `/auth/refresh` for a
  /// fresh [accessToken]. Empty when unknown (legacy sessions).
  final String refreshToken;

  /// Subscription expiry (not the JWT's own lifetime) — drives whether the
  /// subscription is still active.
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get hasRefreshToken => refreshToken.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt.toIso8601String(),
      };
}
