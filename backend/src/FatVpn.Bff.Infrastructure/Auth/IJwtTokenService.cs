using System.Security.Claims;
using FatVpn.Bff.Domain;

namespace FatVpn.Bff.Infrastructure.Auth;

public interface IJwtTokenService
{
    string CreateAccessToken(Token token);
    string CreateAccessTokenForAccount(Account account);

    /// <summary>Re-issues a token for the caller's existing identity with a fresh
    /// lifetime (rolling refresh). Returns null if no identity claim is present.</summary>
    string? Refresh(ClaimsPrincipal user);
}
