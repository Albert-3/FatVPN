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
