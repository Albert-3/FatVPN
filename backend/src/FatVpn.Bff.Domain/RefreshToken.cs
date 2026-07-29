namespace FatVpn.Bff.Domain;

/// <summary>
/// A long-lived, revocable session credential. The app exchanges it at
/// <c>/auth/refresh</c> for a short-lived access JWT, so the access token can
/// stay small (small leak window) while sessions survive long gaps without
/// re-pairing. Only the SHA-256 <see cref="TokenHash"/> is stored — the raw
/// secret is shown to the client once. Exactly one of <see cref="AccountId"/>
/// or <see cref="TokenId"/> is set, mirroring the access token's identity claim.
/// </summary>
public class RefreshToken
{
    public Guid Id { get; set; }
    public string TokenHash { get; set; } = string.Empty;
    public Guid? AccountId { get; set; }
    public Guid? TokenId { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    /// <summary>
    /// The chain of rotations this token belongs to — one per sign-in, carried
    /// across every rotation. Reuse-detection revokes a family, and that used to
    /// mean the whole account: with one key on three phones, a single phone
    /// replaying a spent token (restored backup, cloned install) would sign the
    /// other two out of a paid subscription. Scoping it here keeps the blast
    /// radius at the device that actually leaked.
    /// </summary>
    public Guid FamilyId { get; set; }

    /// <summary>
    /// When the session this token belongs to first started, carried across every
    /// rotation. Rotation used to hand out a full lifetime each time, so a phone
    /// that opened the app once a week stayed signed in forever; this is what
    /// <c>Jwt:AbsoluteSessionLifetime</c> measures against. Zero on rows written
    /// before the column existed — treated as "no known start", i.e. uncapped.
    /// </summary>
    public DateTimeOffset SessionStartedAt { get; set; }

    /// <summary>
    /// Which device this session belongs to, carried across every rotation. It is
    /// the same salted hash a <see cref="TokenDevice"/> slot is keyed by, which is
    /// what lets the server answer two questions it otherwise could not: when was
    /// this device last heard from (refresh moves the slot's clock), and which
    /// sessions must end when its slot is taken away. Null for sessions opened by
    /// pairing, by an app build that sends no attestation, or before this column
    /// existed — those hold no slot, so there is nothing to tie them to.
    /// </summary>
    public string? DeviceKeyHash { get; set; }

    /// <summary>Set when the token is rotated out or explicitly revoked; a
    /// non-null value means the token is no longer usable.</summary>
    public DateTimeOffset? RevokedAt { get; set; }

    /// <summary>
    /// Whether <see cref="RevokedAt"/> was set by an ordinary rotation, as
    /// opposed to a session someone ended: a device evicted from its slot, a
    /// sign-out, or a family revoked after detected reuse. Only a rotation may be
    /// forgiven inside <c>Jwt:RefreshGraceWindow</c> — without this distinction
    /// the window resurrected sessions that had just been revoked on purpose,
    /// because both look identical once the timestamp is set. Deciding it from
    /// "does the family still have a live token" cannot work: in a genuine race
    /// the losers may look before the winner has committed its successor.
    /// </summary>
    public bool RotatedOut { get; set; }

    public bool IsActive(DateTimeOffset now) => RevokedAt is null && ExpiresAt > now;
}
