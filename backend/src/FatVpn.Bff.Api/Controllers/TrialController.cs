using System.ComponentModel.DataAnnotations;
using FatVpn.Bff.Api.Infrastructure;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using FatVpn.Bff.Infrastructure.Remnawave;
using FatVpn.Bff.Infrastructure.TrialPool;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("trial")]
public class TrialController(
    FatVpnDbContext db,
    IJwtTokenService jwtTokenService,
    IRefreshTokenService refreshTokenService,
    IRemnawaveClient remnawaveClient,
    IOptions<TrialOptions> trialOptions,
    ILogger<TrialController> logger) : ControllerBase
{
    /// <summary>Bounds on the per-install device key. The floor matters: an empty
    /// token hashes to SHA256(salt) — the same value for everybody — so the first
    /// caller's trial would be handed to every later caller by the resume branch
    /// below. [ApiController] rejects null but is happy with "".</summary>
    private const int MinAttestationLength = 16;
    private const int MaxAttestationLength = 512;

    [HttpPost]
    [EnableRateLimiting(RateLimitPolicies.Trial)]
    public async Task<IActionResult> GrantTrial([FromBody] TrialRequest request, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(request.AttestationToken)
            || request.AttestationToken.Length is < MinAttestationLength or > MaxAttestationLength)
        {
            return BadRequest(new { message = "attestationToken is missing or malformed" });
        }

        var deviceKeyHash = DeviceKeyHasher.Compute(request.AttestationToken, trialOptions.Value.DeviceKeySalt);
        var now = DateTimeOffset.UtcNow;

        var device = await db.Devices.AsNoTracking()
            .SingleOrDefaultAsync(d => d.DeviceKeyHash == deviceKeyHash, ct);
        if (device is not null)
        {
            var resumed = await TryResumeAsync(device.Id, now, ct);
            if (resumed is not null)
            {
                return resumed;
            }
        }

        // DurationMinutes (when set) wins over DurationDays — used for short test
        // trials without changing the day-based production default.
        var requestedExpiry = trialOptions.Value.DurationMinutes > 0
            ? now.AddMinutes(trialOptions.Value.DurationMinutes)
            : now.AddDays(trialOptions.Value.DurationDays);

        // Provision the trial subscription on demand instead of from a pool, so
        // it scales to every store install without manual replenishment.
        RemnawaveTrialUser created;
        try
        {
            created = await remnawaveClient.CreateTrialUserAsync(requestedExpiry, ct);
        }
        // A client that hung up mid-request also cancels ct; that is not a panel
        // failure and must not be logged as an error or answered with 502.
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            logger.LogError(ex, "Failed to provision trial subscription in Remnawave");
            return StatusCode(StatusCodes.Status502BadGateway, new { message = "Could not provision a trial subscription" });
        }

        if (device is null)
        {
            device = new Device
            {
                Id = Guid.NewGuid(),
                DeviceKeyHash = deviceKeyHash,
                Platform = request.Platform,
                CreatedAt = now,
            };
            db.Devices.Add(device);
        }

        var token = new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = $"TRIAL-{Guid.NewGuid():N}",
            RemnawaveSubscriptionId = created.ShortUuid,
            ExpiresAt = created.ExpiresAt,
            CreatedAt = now,
        };
        db.Tokens.Add(token);

        db.Trials.Add(new Trial
        {
            Id = Guid.NewGuid(),
            DeviceId = device.Id,
            GrantedAt = now,
            ExpiresAt = created.ExpiresAt,
            TokenId = token.Id,
        });

        var accessToken = jwtTokenService.CreateAccessToken(token);
        var (refreshRaw, refreshEntity) = refreshTokenService.Create(accountId: null, tokenId: token.Id);
        db.RefreshTokens.Add(refreshEntity);

        try
        {
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateException ex)
        {
            // Two simultaneous /trial calls for the same device: the unique index
            // on Devices.DeviceKeyHash (or Trials.DeviceId) rejected the loser's
            // rows. The user in the panel has already been created, so hand it
            // back before adopting whatever the winner wrote — otherwise it sits
            // in the panel forever with nothing pointing at it.
            logger.LogWarning(ex, "Trial rows lost a race for device key; releasing the panel user");
            db.ChangeTracker.Clear();
            await ReleasePanelUserAsync(created);

            var winner = await db.Devices.AsNoTracking()
                .SingleOrDefaultAsync(d => d.DeviceKeyHash == deviceKeyHash, ct);
            var resumed = winner is null ? null : await TryResumeAsync(winner.Id, DateTimeOffset.UtcNow, ct);
            return resumed ?? Conflict();
        }

        return Ok(new { accessToken, refreshToken = refreshRaw, expiresAt = created.ExpiresAt });
    }

    /// <summary>
    /// Reissues a session for a device that already has a trial: 200 while the
    /// trial is still running (it signed out and lost its refresh token — a bare
    /// 409 would strand it with no way to see its remaining time), 409 once the
    /// trial is spent, and null when the device has no trial at all so the caller
    /// can provision one.
    /// </summary>
    private async Task<IActionResult?> TryResumeAsync(Guid deviceId, DateTimeOffset now, CancellationToken ct)
    {
        var trial = await db.Trials.AsNoTracking().SingleOrDefaultAsync(t => t.DeviceId == deviceId, ct);
        if (trial is null)
        {
            return null;
        }

        var token = await db.Tokens.AsNoTracking().SingleOrDefaultAsync(t => t.Id == trial.TokenId, ct);
        if (token is null)
        {
            // Rows backfilled by the AddTokenIdToTrial migration matched on
            // timestamp equality; whatever didn't match got Guid.Empty and can
            // never be resumed. Name it so support can tell this apart from a
            // device genuinely trying for a second trial.
            logger.LogWarning(
                "Trial {TrialId} for device {DeviceId} points at token {TokenId}, which does not exist",
                trial.Id, deviceId, trial.TokenId);
            return Conflict();
        }

        if (token.ExpiresAt <= now)
        {
            return Conflict();
        }

        var accessToken = jwtTokenService.CreateAccessToken(token);
        var (refreshRaw, refreshEntity) = refreshTokenService.Create(accountId: null, tokenId: token.Id);
        db.RefreshTokens.Add(refreshEntity);
        await db.SaveChangesAsync(ct);

        return Ok(new
        {
            accessToken,
            refreshToken = refreshRaw,
            expiresAt = token.ExpiresAt,
        });
    }

    /// <summary>Best-effort compensation. Deliberately not cancellable — the
    /// client hanging up is no reason to leak a panel user — and never allowed
    /// to turn a recoverable race into a failed request.</summary>
    private async Task ReleasePanelUserAsync(RemnawaveTrialUser created)
    {
        if (string.IsNullOrEmpty(created.Uuid))
        {
            logger.LogError(
                "Orphaned trial user {ShortUuid} in the panel: the create response carried no uuid to delete it by",
                created.ShortUuid);
            return;
        }

        try
        {
            await remnawaveClient.DeleteUserAsync(created.Uuid, CancellationToken.None);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Could not delete orphaned trial user {Uuid} from the panel", created.Uuid);
        }
    }
}

public sealed record TrialRequest(
    [property: StringLength(512, MinimumLength = 16)] string AttestationToken,
    [property: StringLength(32)] string Platform);
