using System.Security.Claims;
using FatVpn.Bff.Domain;

namespace FatVpn.Bff.Api.Auth;

public static class ClaimsPrincipalExtensions
{
    /// <summary>
    /// The legacy deep-link / trial session id, or null when the JWT carries no
    /// usable one. Never throws: a token that is valid by signature but missing
    /// or malformed in its claims is an authentication problem (401), not a
    /// server fault (500).
    /// </summary>
    public static Guid? TryGetTokenId(this ClaimsPrincipal user) =>
        Parse(user.FindFirstValue(FatVpnClaimTypes.TokenId));

    /// <summary>The pairing-session account id, or null when this is not an account session.</summary>
    public static Guid? TryGetAccountId(this ClaimsPrincipal user) =>
        Parse(user.FindFirstValue(FatVpnClaimTypes.AccountId));

    private static Guid? Parse(string? value) =>
        Guid.TryParse(value, out var parsed) ? parsed : null;
}
