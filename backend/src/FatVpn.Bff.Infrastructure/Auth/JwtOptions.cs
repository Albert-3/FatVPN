namespace FatVpn.Bff.Infrastructure.Auth;

public sealed class JwtOptions
{
    public string Secret { get; set; } = string.Empty;
    public string Issuer { get; set; } = string.Empty;
    public string Audience { get; set; } = string.Empty;

    /// <summary>
    /// Lifetime of an issued access token, decoupled from the subscription
    /// expiry. The JWT answers "who you are"; the subscription's own expiry
    /// (checked live per request) answers "are you entitled". A rolling refresh
    /// on <c>/me</c> keeps the token fresh as long as the app is used within
    /// this window, so extending a subscription never forces re-pairing.
    /// </summary>
    public TimeSpan AccessTokenLifetime { get; set; } = TimeSpan.FromDays(60);
}
