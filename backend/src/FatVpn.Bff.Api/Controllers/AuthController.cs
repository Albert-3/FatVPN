using System.ComponentModel.DataAnnotations;
using FatVpn.Bff.Api.Infrastructure;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using FatVpn.Bff.Infrastructure.TrialPool;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("auth")]
// Brute-force surface: short key codes on /token, opaque secrets on /refresh.
[EnableRateLimiting(RateLimitPolicies.Auth)]
public class AuthController(
    FatVpnDbContext db,
    IJwtTokenService jwtTokenService,
    IRefreshTokenService refreshTokenService,
    IOptions<TrialOptions> trialOptions,
    IOptions<JwtOptions> jwtOptions,
    ILogger<AuthController> logger) : ControllerBase
{
    [HttpPost("token")]
    public async Task<IActionResult> ExchangeToken([FromBody] ExchangeTokenRequest request, CancellationToken ct)
    {
        var token = await db.Tokens.AsNoTracking()
            .SingleOrDefaultAsync(t => t.ShortToken == request.ShortToken, ct);
        if (token is null || token.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            // No audit trail existed on this endpoint at all, so a key being
            // brute-forced looked exactly like normal traffic in the logs.
            logger.LogWarning("Rejected /auth/token: unknown or expired key");
            return NotFound();
        }

        // One key = one phone: the first device to redeem a key binds it; a
        // different device presenting the same key is refused (409). A missing/
        // empty attestation (older app builds) issues a session without binding
        // so existing clients keep working during rollout.
        if (!string.IsNullOrEmpty(request.AttestationToken))
        {
            var deviceHash = DeviceKeyHasher.Compute(request.AttestationToken, trialOptions.Value.DeviceKeySalt);
            // Bind in one statement: reading "unbound" and then writing let two
            // phones redeeming the same fresh key at once both bind and both walk
            // away with a session. The database decides who was first.
            var bound = await db.Tokens
                .Where(t => t.Id == token.Id
                    && (t.BoundDeviceKeyHash == null || t.BoundDeviceKeyHash == deviceHash))
                .ExecuteUpdateAsync(s => s.SetProperty(t => t.BoundDeviceKeyHash, deviceHash), ct);
            if (bound != 1)
            {
                logger.LogWarning("Rejected /auth/token for {TokenId}: key already bound to another device", token.Id);
                return Conflict();
            }
        }

        var accessToken = jwtTokenService.CreateAccessToken(token);
        var (refreshRaw, refreshEntity) = refreshTokenService.Create(accountId: null, tokenId: token.Id);
        db.RefreshTokens.Add(refreshEntity);
        await db.SaveChangesAsync(ct);

        return Ok(new
        {
            accessToken,
            refreshToken = refreshRaw,
            // expiresAt is the subscription's expiry and always has been; the two
            // explicit fields are additive so existing clients keep working while
            // new ones can stop refreshing on the wrong clock.
            expiresAt = token.ExpiresAt,
            subscriptionExpiresAt = token.ExpiresAt,
            accessTokenExpiresAt = DateTimeOffset.UtcNow + jwtOptions.Value.AccessTokenLifetime,
        });
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

        // Claim the token atomically instead of read-check-write: the app can
        // easily fire two /auth/refresh calls at once, and both used to see
        // RevokedAt == null and mint a session. Exactly one caller can flip it.
        // The cast keeps the value's type identical to the nullable column's;
        // without it EF builds a conversion node it cannot translate to SQL.
        var revokedAt = (DateTimeOffset?)now;
        // Expiry is checked below rather than in this predicate: an already-expired
        // token being marked revoked here is harmless (it was unusable anyway), and
        // keeping timestamps out of the UPDATE's WHERE keeps it translatable on
        // every provider the tests run against.
        var claimed = await db.RefreshTokens
            .Where(r => r.TokenHash == hash && r.RevokedAt == null)
            .ExecuteUpdateAsync(s => s.SetProperty(r => r.RevokedAt, revokedAt), ct);

        var stored = await db.RefreshTokens.AsNoTracking()
            .SingleOrDefaultAsync(r => r.TokenHash == hash, ct);
        if (stored is null)
        {
            return Unauthorized();
        }

        if (claimed == 1 && stored.ExpiresAt <= now)
        {
            // We claimed it, but it was past its lifetime — nothing to rotate.
            return Unauthorized();
        }

        if (claimed != 1)
        {
            // We did not get the token. Either it was already spent, or it expired.
            var rotatedAgo = stored.RevokedAt is null ? (TimeSpan?)null : now - stored.RevokedAt.Value;
            var benignRace = rotatedAgo is not null
                && rotatedAgo >= TimeSpan.Zero
                && rotatedAgo <= jwtOptions.Value.RefreshGraceWindow
                && stored.ExpiresAt > now;

            if (!benignRace)
            {
                // A revoked-but-unexpired token presented long after its rotation
                // means an already-spent secret is in play — likely stolen or
                // replayed. Revoke the whole family so the thief and the victim
                // both have to re-pair, rather than letting an attacker keep going.
                if (stored.RevokedAt is not null)
                {
                    logger.LogWarning(
                        "Refresh-token reuse detected {RotatedAgo} after rotation; revoking the session family",
                        rotatedAgo);
                    await RevokeFamilyAsync(stored, now, ct);
                }

                return Unauthorized();
            }

            // Inside the grace window this is the app racing itself, not theft.
            // Fall through and hand out another token for the same family. It is
            // a fresh secret rather than a replay of the one the winning call
            // returned — refresh tokens are only ever stored hashed, so the
            // original cannot be reconstructed here. Both belong to the same
            // client and the same family; whichever it keeps keeps working.
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

        // The presented token was already revoked by the atomic claim above. The
        // session's original start travels with the rotation so an absolute
        // lifetime, when configured, can't be reset by simply refreshing.
        var (refreshRaw, refreshEntity) = refreshTokenService.Create(
            stored.AccountId, stored.TokenId, stored.SessionStartedAt);
        db.RefreshTokens.Add(refreshEntity);
        await db.SaveChangesAsync(ct);

        return Ok(new
        {
            accessToken,
            refreshToken = refreshRaw,
            expiresAt,
            subscriptionExpiresAt = expiresAt,
            accessTokenExpiresAt = now + jwtOptions.Value.AccessTokenLifetime,
        });
    }

    /// <summary>Best-effort revocation of a refresh token on sign-out. Always
    /// returns 204 so a client can't probe which tokens exist.</summary>
    [HttpPost("logout")]
    public async Task<IActionResult> Logout([FromBody] RefreshRequest request, CancellationToken ct)
    {
        var hash = refreshTokenService.Hash(request.RefreshToken);
        var revokedAt = (DateTimeOffset?)DateTimeOffset.UtcNow;
        await db.RefreshTokens
            .Where(r => r.TokenHash == hash && r.RevokedAt == null)
            .ExecuteUpdateAsync(s => s.SetProperty(r => r.RevokedAt, revokedAt), ct);

        return NoContent();
    }

    /// <summary>Revokes every still-active refresh token belonging to the same
    /// session identity (account or legacy token) as <paramref name="member"/>.
    /// Used on detected token reuse to invalidate a possibly-compromised family.</summary>
    private Task RevokeFamilyAsync(RefreshToken member, DateTimeOffset now, CancellationToken ct)
    {
        var revokedAt = (DateTimeOffset?)now;
        return db.RefreshTokens
            .Where(r => r.RevokedAt == null
                && ((member.AccountId != null && r.AccountId == member.AccountId)
                    || (member.TokenId != null && r.TokenId == member.TokenId)))
            // One statement rather than materialising the family and updating it
            // row by row — this runs on the fastest-growing table in the schema.
            .ExecuteUpdateAsync(s => s.SetProperty(r => r.RevokedAt, revokedAt), ct);
    }
}

public sealed record ExchangeTokenRequest(
    [property: StringLength(128)] string ShortToken,
    [property: StringLength(512)] string? AttestationToken = null);

public sealed record RefreshRequest([property: StringLength(512)] string RefreshToken);
