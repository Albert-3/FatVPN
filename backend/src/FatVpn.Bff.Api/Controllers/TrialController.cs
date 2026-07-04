using System.Security.Cryptography;
using System.Text;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using FatVpn.Bff.Infrastructure.TrialPool;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("trial")]
public class TrialController(FatVpnDbContext db, IJwtTokenService jwtTokenService, IOptions<TrialOptions> trialOptions) : ControllerBase
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

        var slot = await db.TrialSubscriptionSlots.FirstOrDefaultAsync(s => !s.IsAssigned, ct);
        if (slot is null)
        {
            return StatusCode(StatusCodes.Status503ServiceUnavailable, new { message = "No trial capacity available" });
        }

        var now = DateTimeOffset.UtcNow;

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

        var expiresAt = now.AddDays(trialOptions.Value.DurationDays);

        slot.IsAssigned = true;
        slot.AssignedDeviceId = device.Id;
        slot.AssignedAt = now;

        var token = new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = $"TRIAL-{Guid.NewGuid():N}",
            RemnawaveSubscriptionId = slot.RemnawaveSubscriptionId,
            ExpiresAt = expiresAt,
            CreatedAt = now,
        };
        db.Tokens.Add(token);

        db.Trials.Add(new Trial
        {
            Id = Guid.NewGuid(),
            DeviceId = device.Id,
            GrantedAt = now,
            ExpiresAt = expiresAt,
        });

        await db.SaveChangesAsync(ct);

        var accessToken = jwtTokenService.CreateAccessToken(token);
        return Ok(new { accessToken, expiresAt });
    }

    private static string ComputeDeviceKeyHash(string attestationToken, string salt)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(salt + attestationToken));
        return Convert.ToHexString(hash);
    }
}

public sealed record TrialRequest(string AttestationToken, string Platform);
