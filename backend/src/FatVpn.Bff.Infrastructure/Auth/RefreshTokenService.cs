using System.Security.Cryptography;
using System.Text;
using FatVpn.Bff.Domain;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Infrastructure.Auth;

public interface IRefreshTokenService
{
    /// <summary>Mints a new refresh token. Returns the raw secret to hand to the
    /// client once, plus the entity (hashed) for the caller to persist.</summary>
    (string RawToken, RefreshToken Entity) Create(Guid? accountId, Guid? tokenId);

    /// <summary>Hashes a raw token for a constant-shape DB lookup.</summary>
    string Hash(string rawToken);
}

public sealed class RefreshTokenService(IOptions<JwtOptions> options) : IRefreshTokenService
{
    public (string RawToken, RefreshToken Entity) Create(Guid? accountId, Guid? tokenId)
    {
        var raw = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        var now = DateTimeOffset.UtcNow;
        var entity = new RefreshToken
        {
            Id = Guid.NewGuid(),
            TokenHash = Hash(raw),
            AccountId = accountId,
            TokenId = tokenId,
            ExpiresAt = now + options.Value.RefreshTokenLifetime,
            CreatedAt = now,
        };
        return (raw, entity);
    }

    public string Hash(string rawToken) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(rawToken)));
}
