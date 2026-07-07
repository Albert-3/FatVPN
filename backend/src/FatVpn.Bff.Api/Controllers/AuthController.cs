using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("auth")]
public class AuthController(
    FatVpnDbContext db,
    IJwtTokenService jwtTokenService,
    IRefreshTokenService refreshTokenService) : ControllerBase
{
    [HttpPost("token")]
    public async Task<IActionResult> ExchangeToken([FromBody] ExchangeTokenRequest request, CancellationToken ct)
    {
        var token = await db.Tokens.SingleOrDefaultAsync(t => t.ShortToken == request.ShortToken, ct);
        if (token is null || token.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            return NotFound();
        }

        var accessToken = jwtTokenService.CreateAccessToken(token);
        var (refreshRaw, refreshEntity) = refreshTokenService.Create(accountId: null, tokenId: token.Id);
        db.RefreshTokens.Add(refreshEntity);
        await db.SaveChangesAsync(ct);

        return Ok(new { accessToken, refreshToken = refreshRaw, expiresAt = token.ExpiresAt });
    }

    /// <summary>Exchanges a refresh token for a fresh access token, rotating the
    /// refresh token. Entitlement is not checked here — a lapsed subscription can
    /// still refresh so the app reaches its renew screen (and picks up an
    /// extension); /config and /servers gate on the live subscription.</summary>
    [HttpPost("refresh")]
    public async Task<IActionResult> Refresh([FromBody] RefreshRequest request, CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        var hash = refreshTokenService.Hash(request.RefreshToken);
        var stored = await db.RefreshTokens.SingleOrDefaultAsync(r => r.TokenHash == hash, ct);
        if (stored is null || !stored.IsActive(now))
        {
            return Unauthorized();
        }

        // Re-issue an access token for the same identity, if it still exists.
        string accessToken;
        DateTimeOffset expiresAt;
        if (stored.AccountId is not null)
        {
            var account = await db.Accounts.FindAsync([stored.AccountId.Value], ct);
            if (account is null)
            {
                return Unauthorized();
            }
            accessToken = jwtTokenService.CreateAccessTokenForAccount(account);
            expiresAt = account.ExpiresAt;
        }
        else if (stored.TokenId is not null)
        {
            var token = await db.Tokens.FindAsync([stored.TokenId.Value], ct);
            if (token is null)
            {
                return Unauthorized();
            }
            accessToken = jwtTokenService.CreateAccessToken(token);
            expiresAt = token.ExpiresAt;
        }
        else
        {
            return Unauthorized();
        }

        // Rotate: revoke the presented token and issue a fresh one.
        stored.RevokedAt = now;
        var (refreshRaw, refreshEntity) = refreshTokenService.Create(stored.AccountId, stored.TokenId);
        db.RefreshTokens.Add(refreshEntity);
        await db.SaveChangesAsync(ct);

        return Ok(new { accessToken, refreshToken = refreshRaw, expiresAt });
    }

    /// <summary>Best-effort revocation of a refresh token on sign-out. Always
    /// returns 204 so a client can't probe which tokens exist.</summary>
    [HttpPost("logout")]
    public async Task<IActionResult> Logout([FromBody] RefreshRequest request, CancellationToken ct)
    {
        var hash = refreshTokenService.Hash(request.RefreshToken);
        var stored = await db.RefreshTokens.SingleOrDefaultAsync(r => r.TokenHash == hash, ct);
        if (stored is not null && stored.RevokedAt is null)
        {
            stored.RevokedAt = DateTimeOffset.UtcNow;
            await db.SaveChangesAsync(ct);
        }

        return NoContent();
    }
}

public sealed record ExchangeTokenRequest(string ShortToken);

public sealed record RefreshRequest(string RefreshToken);
