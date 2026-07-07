using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using FatVpn.Bff.Domain;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;

namespace FatVpn.Bff.Infrastructure.Auth;

public sealed class JwtTokenService(IOptions<JwtOptions> options) : IJwtTokenService
{
    public string CreateAccessToken(Token token)
    {
        return CreateToken(new Claim(FatVpnClaimTypes.TokenId, token.Id.ToString()));
    }

    public string CreateAccessTokenForAccount(Account account)
    {
        return CreateToken(new Claim(FatVpnClaimTypes.AccountId, account.Id.ToString()));
    }

    // Re-issues a token carrying the same identity claim as the caller's, with a
    // fresh lifetime. Used by /me as a rolling refresh so a session stays alive
    // (and picks up subscription extensions) as long as the app is opened within
    // the token window. Returns null if the principal has no identity claim.
    public string? Refresh(ClaimsPrincipal user)
    {
        var accountId = user.FindFirst(FatVpnClaimTypes.AccountId)?.Value;
        if (accountId is not null)
        {
            return CreateToken(new Claim(FatVpnClaimTypes.AccountId, accountId));
        }

        var tokenId = user.FindFirst(FatVpnClaimTypes.TokenId)?.Value;
        if (tokenId is not null)
        {
            return CreateToken(new Claim(FatVpnClaimTypes.TokenId, tokenId));
        }

        return null;
    }

    // The token's own lifetime is deliberately independent of the subscription
    // expiry — entitlement is enforced live per request against the account/token
    // row, not by the JWT's exp claim.
    private string CreateToken(Claim claim)
    {
        var opts = options.Value;
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(opts.Secret));
        var credentials = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);

        var jwt = new JwtSecurityToken(
            issuer: opts.Issuer,
            audience: opts.Audience,
            claims: [claim],
            expires: (DateTimeOffset.UtcNow + opts.AccessTokenLifetime).UtcDateTime,
            signingCredentials: credentials);

        return new JwtSecurityTokenHandler().WriteToken(jwt);
    }
}
