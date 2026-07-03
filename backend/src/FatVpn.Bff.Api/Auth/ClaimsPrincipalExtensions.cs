using System.Security.Claims;
using FatVpn.Bff.Domain;

namespace FatVpn.Bff.Api.Auth;

public static class ClaimsPrincipalExtensions
{
    public static Guid GetTokenId(this ClaimsPrincipal user)
    {
        var value = user.FindFirstValue(FatVpnClaimTypes.TokenId)
            ?? throw new InvalidOperationException("Missing token id claim.");
        return Guid.Parse(value);
    }
}
