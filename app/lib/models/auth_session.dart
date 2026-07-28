import 'dart:convert';

class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.accessTokenExpiresAt,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final accessToken = json['accessToken'] as String;
    final rawAccessExpiry = json['accessTokenExpiresAt'] as String?;
    return AuthSession(
      accessToken: accessToken,
      // Tolerate a missing refresh token (e.g. an older stored session) — an
      // empty value forces a fresh sign-in rather than a crash.
      refreshToken: json['refreshToken'] as String? ?? '',
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      // Only /auth/token and /auth/refresh report it; /trial and /pair/status
      // don't, so fall back to the JWT's own `exp`.
      accessTokenExpiresAt:
          (rawAccessExpiry != null ? DateTime.tryParse(rawAccessExpiry) : null) ??
              _jwtExpiry(accessToken),
    );
  }

  final String accessToken;

  /// Long-lived, revocable, rotating secret exchanged at `/auth/refresh` for a
  /// fresh [accessToken]. Empty when unknown (legacy sessions).
  final String refreshToken;

  /// Subscription expiry (not the JWT's own lifetime) — drives whether the
  /// subscription is still active.
  final DateTime expiresAt;

  /// When [accessToken] itself stops being accepted. Null only for a session
  /// stored by an older build. Lets the app refresh because the token is about
  /// to lapse rather than on a fixed schedule — each refresh rotates the
  /// refresh token, and every rotation is a chance to lose the session.
  final DateTime? accessTokenExpiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get hasRefreshToken => refreshToken.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'expiresAt': expiresAt.toIso8601String(),
        if (accessTokenExpiresAt != null)
          'accessTokenExpiresAt': accessTokenExpiresAt!.toIso8601String(),
      };

  /// `exp` out of a JWT payload, or null if [token] isn't one we can read. Not
  /// a validation — the signature is the server's business; this only asks when
  /// the server said it would stop honouring the token.
  static DateTime? _jwtExpiry(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64.decode(base64.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final exp = payload['exp'];
      if (exp is! int) return null;
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    } catch (_) {
      return null;
    }
  }
}
