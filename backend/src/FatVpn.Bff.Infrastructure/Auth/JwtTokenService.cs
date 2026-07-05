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
        return CreateToken(
            new Claim(FatVpnClaimTypes.TokenId, token.Id.ToString()),
            token.ExpiresAt);
    }

    public string CreateAccessTokenForAccount(Account account)
    {
        return CreateToken(
            new Claim(FatVpnClaimTypes.AccountId, account.Id.ToString()),
            account.ExpiresAt);
    }

    private string CreateToken(Claim claim, DateTimeOffset expiresAt)
    {
        var opts = options.Value;
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(opts.Secret));
        var credentials = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);

        var jwt = new JwtSecurityToken(
            issuer: opts.Issuer,
            audience: opts.Audience,
            claims: [claim],
            expires: expiresAt.UtcDateTime,
            signingCredentials: credentials);

        return new JwtSecurityTokenHandler().WriteToken(jwt);
    }
}
