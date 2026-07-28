import 'auth_session.dart';

/// Result of `POST /pair/start` — the code shown to the user and the secret
/// [pollToken] the app polls with.
class PairingStart {
  const PairingStart({
    required this.pairCode,
    required this.pollToken,
    required this.expiresAt,
  });

  factory PairingStart.fromJson(Map<String, dynamic> json) {
    return PairingStart(
      pairCode: json['pairCode'] as String,
      pollToken: json['pollToken'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }

  final String pairCode;
  final String pollToken;
  final DateTime expiresAt;

  /// Persisted so an attempt survives the process being killed while the user
  /// is over in Telegram — otherwise the app comes back, mints a *new* code and
  /// waits on it forever while the bot has already completed the old one.
  Map<String, dynamic> toJson() => {
        'pairCode': pairCode,
        'pollToken': pollToken,
        'expiresAt': expiresAt.toIso8601String(),
      };
}

enum PairingState { pending, completed, expired }

/// Result of `GET /pair/status` — either still pending, expired, or completed
/// (in which case [session] carries the issued JWT).
class PairingStatus {
  const PairingStatus(this.state, {this.session});

  factory PairingStatus.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String;
    switch (status) {
      case 'completed':
        return PairingStatus(PairingState.completed, session: AuthSession.fromJson(json));
      case 'expired':
        return const PairingStatus(PairingState.expired);
      default:
        return const PairingStatus(PairingState.pending);
    }
  }

  final PairingState state;
  final AuthSession? session;
}
