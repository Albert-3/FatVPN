using System.Security.Cryptography;
using System.Text;
using FatVpn.Bff.Domain;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Infrastructure.Auth;

public interface IRefreshTokenService
{
    /// <summary>Mints a new refresh token. Returns the raw secret to hand to the
    /// client once, plus the entity (hashed) for the caller to persist.
    /// <paramref name="sessionStartedAt"/> carries the session's original start
    /// across rotations; pass null when this token starts a new session.
    /// <paramref name="familyId"/> likewise carries the rotation chain — pass the
    /// rotated token's family, or null to start a new one.</summary>
    (string RawToken, RefreshToken Entity) Create(
        Guid? accountId, Guid? tokenId, DateTimeOffset? sessionStartedAt = null, Guid? familyId = null);

    /// <summary>Hashes a raw token for a constant-shape DB lookup.</summary>
    string Hash(string rawToken);
}

public sealed class RefreshTokenService(IOptions<JwtOptions> options) : IRefreshTokenService
{
    public (string RawToken, RefreshToken Entity) Create(
        Guid? accountId, Guid? tokenId, DateTimeOffset? sessionStartedAt = null, Guid? familyId = null)
    {
        var raw = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        var now = DateTimeOffset.UtcNow;
        var sessionStart = sessionStartedAt ?? now;
        var entity = new RefreshToken
        {
            Id = Guid.NewGuid(),
            TokenHash = Hash(raw),
            AccountId = accountId,
            TokenId = tokenId,
            ExpiresAt = CapToSession(now + options.Value.RefreshTokenLifetime, sessionStart),
            CreatedAt = now,
            SessionStartedAt = sessionStart,
            // A token with no family given starts one: this is a fresh sign-in,
            // not a rotation, and it must not inherit another device's chain.
            FamilyId = familyId is null || familyId == Guid.Empty ? Guid.NewGuid() : familyId.Value,
        };
        return (raw, entity);
    }

    public string Hash(string rawToken) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(rawToken)));

    /// <summary>
    /// Rotation grants a full lifetime every time, so an app opened once a week
    /// never has to re-authenticate. When an absolute lifetime is configured, no
    /// rotation can push the session past it.
    /// </summary>
    private DateTimeOffset CapToSession(DateTimeOffset expiresAt, DateTimeOffset sessionStart)
    {
        var absolute = options.Value.AbsoluteSessionLifetime;
        if (absolute <= TimeSpan.Zero || sessionStart == default)
        {
            return expiresAt;
        }

        var ceiling = sessionStart + absolute;
        return expiresAt < ceiling ? expiresAt : ceiling;
    }
}
