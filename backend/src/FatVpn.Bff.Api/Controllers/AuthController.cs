using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using FatVpn.Bff.Infrastructure.TrialPool;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("auth")]
public class AuthController(
    FatVpnDbContext db,
    IJwtTokenService jwtTokenService,
    IRefreshTokenService refreshTokenService,
    IOptions<TrialOptions> trialOptions) : ControllerBase
{
    [HttpPost("token")]
    public async Task<IActionResult> ExchangeToken([FromBody] ExchangeTokenRequest request, CancellationToken ct)
    {
        var token = await db.Tokens.SingleOrDefaultAsync(t => t.ShortToken == request.ShortToken, ct);
        if (token is null || token.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            return NotFound();
        }

        // One key = one phone: the first device to redeem a key binds it; a
        // different device presenting the same key is refused (409). A missing/
        // empty attestation (older app builds) issues a session without binding
        // so existing clients keep working during rollout.
        if (!string.IsNullOrEmpty(request.AttestationToken))
        {
            var deviceHash = DeviceKeyHasher.Compute(request.AttestationToken, trialOptions.Value.DeviceKeySalt);
            if (token.BoundDeviceKeyHash is null)
            {
                token.BoundDeviceKeyHash = deviceHash;
            }
            else if (!string.Equals(token.BoundDeviceKeyHash, deviceHash, StringComparison.Ordinal))
            {
                return Conflict();
            }
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
        if (stored is null)
        {
            return Unauthorized();
        }

        if (!stored.IsActive(now))
        {
            // A revoked-but-unexpired token being presented means an already-rotated
            // (or logged-out) secret is in play — likely a stolen/replayed token.
            // Revoke the whole session family so the thief and the victim both have
            // to re-pair, rather than letting the attacker keep refreshing.
            if (stored.RevokedAt is not null)
            {
                await RevokeFamilyAsync(stored, now, ct);
            }
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

    /// <summary>Revokes every still-active refresh token belonging to the same
    /// session identity (account or legacy token) as <paramref name="member"/>.
    /// Used on detected token reuse to invalidate a possibly-compromised family.</summary>
    private async Task RevokeFamilyAsync(RefreshToken member, DateTimeOffset now, CancellationToken ct)
    {
        var family = await db.RefreshTokens
            .Where(r => r.RevokedAt == null
                && ((member.AccountId != null && r.AccountId == member.AccountId)
                    || (member.TokenId != null && r.TokenId == member.TokenId)))
            .ToListAsync(ct);

        foreach (var token in family)
        {
            token.RevokedAt = now;
        }

        if (family.Count > 0)
        {
            await db.SaveChangesAsync(ct);
        }
    }
}

public sealed record ExchangeTokenRequest(string ShortToken, string? AttestationToken = null);

public sealed record RefreshRequest(string RefreshToken);
