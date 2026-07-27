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

    /// <summary>
    /// How long after a refresh token is rotated out a second presentation of it
    /// still counts as a benign race rather than token theft. A mobile client
    /// that hits several 401s at once fires several /auth/refresh calls; without
    /// this window the loser of that race trips reuse-detection and the user is
    /// logged out of a paid subscription for no reason.
    /// </summary>
    public TimeSpan RefreshGraceWindow { get; set; } = TimeSpan.FromSeconds(30);

    /// <summary>
    /// Hard ceiling on a session regardless of rotation: past this, the user
    /// re-pairs. Off (<see cref="TimeSpan.Zero"/>) by default, because turning it
    /// on signs out every active install once they cross it — that is a product
    /// decision, not something to change silently under people.
    /// </summary>
    public TimeSpan AbsoluteSessionLifetime { get; set; } = TimeSpan.Zero;
}
