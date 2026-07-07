using System.Security.Cryptography;
using System.Text;
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
    IRemnawaveClient remnawaveClient,
    IOptions<TrialOptions> trialOptions,
    ILogger<TrialController> logger) : ControllerBase
{
    [HttpPost]
    public async Task<IActionResult> GrantTrial([FromBody] TrialRequest request, CancellationToken ct)
    {
        var deviceKeyHash = ComputeDeviceKeyHash(request.AttestationToken, trialOptions.Value.DeviceKeySalt);

        var device = await db.Devices.SingleOrDefaultAsync(d => d.DeviceKeyHash == deviceKeyHash, ct);
        if (device is not null && await db.Trials.AnyAsync(t => t.DeviceId == device.Id, ct))
        {
            return Conflict();
        }

        var now = DateTimeOffset.UtcNow;
        var requestedExpiry = now.AddDays(trialOptions.Value.DurationDays);

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
        });

        await db.SaveChangesAsync(ct);

        var accessToken = jwtTokenService.CreateAccessToken(token);
        return Ok(new { accessToken, expiresAt = created.ExpiresAt });
    }

    private static string ComputeDeviceKeyHash(string attestationToken, string salt)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(salt + attestationToken));
        return Convert.ToHexString(hash);
    }
}

public sealed record TrialRequest(string AttestationToken, string Platform);
