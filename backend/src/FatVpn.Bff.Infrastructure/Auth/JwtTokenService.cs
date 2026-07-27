using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using FatVpn.Bff.Domain;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;

namespace FatVpn.Bff.Infrastructure.Auth;

public sealed class JwtTokenService(IOptions<JwtOptions> options) : IJwtTokenService
{
    // Built once instead of per issued token: deriving the key and spinning up a
    // handler on every login and every refresh is pure waste on the hottest path.
    private readonly SigningCredentials _credentials = new(
        new SymmetricSecurityKey(Encoding.UTF8.GetBytes(options.Value.Secret)),
        SecurityAlgorithms.HmacSha256);

    private static readonly JwtSecurityTokenHandler Handler = new();

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
        var jwt = new JwtSecurityToken(
            issuer: opts.Issuer,
            audience: opts.Audience,
            claims: [claim],
            expires: (DateTimeOffset.UtcNow + opts.AccessTokenLifetime).UtcDateTime,
            signingCredentials: _credentials);

        return Handler.WriteToken(jwt);
    }
}
