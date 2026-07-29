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
    IOptions<AuthOptions> authOptions,
    ILogger<AuthController> logger) : ControllerBase
{
    /// <summary>Returned in the 409 body when a key has no device slots left, so
    /// the app can say "already on N devices" instead of the old "bound to
    /// another phone" — which stopped being true once a key held several.</summary>
    public const string DeviceLimitError = "device_limit";

    [HttpPost("token")]
    public async Task<IActionResult> ExchangeToken([FromBody] ExchangeTokenRequest request, CancellationToken ct)
    {
        var token = await db.Tokens.AsNoTracking()
            .SingleOrDefaultAsync(t => t.ShortToken == request.ShortToken, ct);
        if (token is null)
        {
            // No audit trail existed on this endpoint at all, so a key being
            // brute-forced looked exactly like normal traffic in the logs.
            logger.LogWarning("Rejected /auth/token: unknown key");
            return NotFound();
        }

        // Tracked, not AsNoTracking: pasting a code is the user picking which of
        // their keys the app runs on, so this row is about to be written.
        var account = token.AccountId is null
            ? null
            : await db.Accounts.FirstOrDefaultAsync(a => a.Id == token.AccountId.Value, ct);

        // Extensions land on the account, never on the key row — the bot only
        // rewrites the latter when it reissues a code. So for the key that is
        // already the account's active one, the account holds the fresher
        // expiry, and reading the stale row here is what used to refuse a
        // renewed subscriber their own key with a flat 404.
        var expiresAt = token.ExpiresAt;
        if (account is not null
            && account.CurrentSubscriptionId == token.RemnawaveSubscriptionId
            && account.ExpiresAt > expiresAt)
        {
            expiresAt = account.ExpiresAt;
        }

        if (expiresAt <= DateTimeOffset.UtcNow)
        {
            logger.LogWarning("Rejected /auth/token: expired key");
            return NotFound();
        }

        // One key, up to Auth:MaxDevicesPerKey phones. Each distinct device takes
        // a slot; the device that already holds one re-enters freely. A missing/
        // empty attestation (older app builds) issues a session without taking a
        // slot at all, so existing clients keep working during rollout.
        if (!string.IsNullOrEmpty(request.AttestationToken))
        {
            var deviceHash = DeviceKeyHasher.Compute(request.AttestationToken, trialOptions.Value.DeviceKeySalt);
            if (!await TryAdmitDeviceAsync(token.Id, deviceHash, ct))
            {
                logger.LogWarning(
                    "Rejected /auth/token for {TokenId}: key already on its {Max} devices",
                    token.Id, authOptions.Value.MaxDevicesPerKey);
                return Conflict(new { error = DeviceLimitError });
            }
        }

        string accessToken;
        string refreshRaw;
        RefreshToken refreshEntity;
        if (account is not null)
        {
            // A key we know the owner of stops being an identity of its own: the
            // session is the account's, exactly as if the user had paired. That
            // is the whole point — a later extension or key change reaches the
            // app instead of dying on this row.
            account.CurrentSubscriptionId = token.RemnawaveSubscriptionId;
            account.CurrentKeyCode = token.ShortToken;
            account.ExpiresAt = expiresAt;
            account.UpdatedAt = DateTimeOffset.UtcNow;

            accessToken = jwtTokenService.CreateAccessTokenForAccount(account);
            (refreshRaw, refreshEntity) = refreshTokenService.Create(account.Id, tokenId: null);
        }
        else
        {
            accessToken = jwtTokenService.CreateAccessToken(token);
            (refreshRaw, refreshEntity) = refreshTokenService.Create(accountId: null, tokenId: token.Id);
        }

        db.RefreshTokens.Add(refreshEntity);
        await db.SaveChangesAsync(ct);

        return Ok(new
        {
            accessToken,
            refreshToken = refreshRaw,
            // expiresAt is the subscription's expiry and always has been; the two
            // explicit fields are additive so existing clients keep working while
            // new ones can stop refreshing on the wrong clock.
            expiresAt,
            subscriptionExpiresAt = expiresAt,
            accessTokenExpiresAt = DateTimeOffset.UtcNow + jwtOptions.Value.AccessTokenLifetime,
        });
    }

    /// <summary>Gives <paramref name="deviceHash"/> one of the key's device slots,
    /// or reports that they are all taken. Idempotent for a device that already
    /// holds one.</summary>
    private async Task<bool> TryAdmitDeviceAsync(Guid tokenId, string deviceHash, CancellationToken ct)
    {
        if (await HoldsASlotAsync(tokenId, deviceHash, ct))
        {
            return true;
        }

        // Take the lowest slot this device can get. Deciding from a count would
        // be a read followed by a write, and four phones redeeming the same key
        // at once all read "room for one more"; here the unique index on
        // (TokenId, SlotIndex) decides, and a loser simply tries the next slot.
        for (var slot = 0; slot < authOptions.Value.MaxDevicesPerKey; slot++)
        {
            var entry = db.TokenDevices.Add(new TokenDevice
            {
                Id = Guid.NewGuid(),
                TokenId = tokenId,
                SlotIndex = slot,
                DeviceKeyHash = deviceHash,
                BoundAt = DateTimeOffset.UtcNow,
            });

            try
            {
                // Its own SaveChanges: losing a slot is an ordinary outcome here
                // and must not take the session's refresh token down with it.
                await db.SaveChangesAsync(ct);
                return true;
            }
            catch (DbUpdateException)
            {
                // Either the slot went to someone else, or this same device is
                // already in and we collided with its own row. The writer we lost
                // to has committed by the time the violation surfaces, so asking
                // now gives a settled answer rather than a racy one.
                entry.State = EntityState.Detached;
                if (await HoldsASlotAsync(tokenId, deviceHash, ct))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private Task<bool> HoldsASlotAsync(Guid tokenId, string deviceHash, CancellationToken ct)
        => db.TokenDevices.AsNoTracking()
            .AnyAsync(d => d.TokenId == tokenId && d.DeviceKeyHash == deviceHash, ct);

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
            stored.AccountId, stored.TokenId, stored.SessionStartedAt, stored.FamilyId);
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

    /// <summary>Revokes every still-active refresh token in the same rotation
    /// chain as <paramref name="member"/>. Used on detected token reuse to
    /// invalidate a possibly-compromised session — that session only: a key may
    /// be running on three phones, and the other two did nothing wrong.</summary>
    private Task RevokeFamilyAsync(RefreshToken member, DateTimeOffset now, CancellationToken ct)
    {
        var revokedAt = (DateTimeOffset?)now;
        var familyId = member.FamilyId;
        if (familyId == Guid.Empty)
        {
            // A row the migration's backfill somehow missed. Matching on the empty
            // family would sweep up every other such row — across all accounts —
            // so revoke exactly the token that was replayed and nothing else.
            var hash = member.TokenHash;
            return db.RefreshTokens
                .Where(r => r.RevokedAt == null && r.TokenHash == hash)
                .ExecuteUpdateAsync(s => s.SetProperty(r => r.RevokedAt, revokedAt), ct);
        }

        return db.RefreshTokens
            .Where(r => r.RevokedAt == null && r.FamilyId == familyId)
            // One statement rather than materialising the family and updating it
            // row by row — this runs on the fastest-growing table in the schema.
            .ExecuteUpdateAsync(s => s.SetProperty(r => r.RevokedAt, revokedAt), ct);
    }
}

public sealed record ExchangeTokenRequest(
    [StringLength(128)] string ShortToken,
    [StringLength(512)] string? AttestationToken = null);

public sealed record RefreshRequest([StringLength(512)] string RefreshToken);
