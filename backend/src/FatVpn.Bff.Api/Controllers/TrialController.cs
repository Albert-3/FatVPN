using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using FatVpn.Bff.Infrastructure.Remnawave;
using FatVpn.Bff.Infrastructure.TrialPool;
using Microsoft.AspNetCore.Mvc;
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
    [HttpPost]
    public async Task<IActionResult> GrantTrial([FromBody] TrialRequest request, CancellationToken ct)
    {
        var deviceKeyHash = DeviceKeyHasher.Compute(request.AttestationToken, trialOptions.Value.DeviceKeySalt);
        var now = DateTimeOffset.UtcNow;

        var device = await db.Devices.SingleOrDefaultAsync(d => d.DeviceKeyHash == deviceKeyHash, ct);
        if (device is not null)
        {
            var existingTrial = await db.Trials.SingleOrDefaultAsync(t => t.DeviceId == device.Id, ct);
            if (existingTrial is not null)
            {
                // Same device asking again (e.g. it signed out and lost its refresh
                // token). If the trial it already has is still running, reissue a
                // session for it instead of stranding the client with a bare 409 and
                // no way to know its remaining time. Only a genuinely exhausted trial
                // is refused.
                var existingToken = await db.Tokens.SingleOrDefaultAsync(t => t.Id == existingTrial.TokenId, ct);
                if (existingToken is null || existingToken.ExpiresAt <= now)
                {
                    return Conflict();
                }

                var resumedAccessToken = jwtTokenService.CreateAccessToken(existingToken);
                var (resumedRefreshRaw, resumedRefreshEntity) =
                    refreshTokenService.Create(accountId: null, tokenId: existingToken.Id);
                db.RefreshTokens.Add(resumedRefreshEntity);
                await db.SaveChangesAsync(ct);

                return Ok(new
                {
                    accessToken = resumedAccessToken,
                    refreshToken = resumedRefreshRaw,
                    expiresAt = existingToken.ExpiresAt,
                });
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
        catch (Exception ex)
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

        await db.SaveChangesAsync(ct);

        return Ok(new { accessToken, refreshToken = refreshRaw, expiresAt = created.ExpiresAt });
    }
}

public sealed record TrialRequest(string AttestationToken, string Platform);
