namespace FatVpn.Bff.Infrastructure.Auth;

public sealed class JwtOptions
{
    public string Secret { get; set; } = string.Empty;
    public string Issuer { get; set; } = string.Empty;
    public string Audience { get; set; } = string.Empty;

    /// <summary>
    /// Lifetime of an access JWT, decoupled from the subscription expiry. Kept
    /// short so a leaked token is only usable briefly; the app silently renews
    /// it via a refresh token. Entitlement is enforced live per request, not by
    /// this claim.
    /// </summary>
    public TimeSpan AccessTokenLifetime { get; set; } = TimeSpan.FromMinutes(30);

    /// <summary>
    /// Lifetime of a refresh token. This is the real session length — how long
    /// the app can go between opens before re-pairing is required. Refresh
    /// tokens are stored hashed and revocable, and rotate on every use.
    /// </summary>
    public TimeSpan RefreshTokenLifetime { get; set; } = TimeSpan.FromDays(90);
}
