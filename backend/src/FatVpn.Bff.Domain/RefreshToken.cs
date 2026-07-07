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

    /// <summary>Set when the token is rotated out or explicitly revoked; a
    /// non-null value means the token is no longer usable.</summary>
    public DateTimeOffset? RevokedAt { get; set; }

    public bool IsActive(DateTimeOffset now) => RevokedAt is null && ExpiresAt > now;
}
