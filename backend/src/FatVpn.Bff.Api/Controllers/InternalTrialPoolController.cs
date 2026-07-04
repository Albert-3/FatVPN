using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Bot;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("internal/trial-pool")]
public class InternalTrialPoolController(FatVpnDbContext db, IOptions<BotOptions> botOptions) : ControllerBase
{
    [HttpPost]
    public async Task<IActionResult> AddSlots([FromBody] AddTrialSlotsRequest request, CancellationToken ct)
    {
        if (!BotSecretValidator.IsValid(Request.Headers[BotSecretValidator.HeaderName], botOptions.Value.Secret))
        {
            return Unauthorized();
        }

        var existingIds = await db.TrialSubscriptionSlots
            .Select(s => s.RemnawaveSubscriptionId)
            .ToListAsync(ct);
        var existingSet = existingIds.ToHashSet();

        var now = DateTimeOffset.UtcNow;
        var added = 0;
        foreach (var id in request.RemnawaveSubscriptionIds.Distinct())
        {
            if (!existingSet.Add(id))
            {
                continue;
            }

            db.TrialSubscriptionSlots.Add(new TrialSubscriptionSlot
            {
                Id = Guid.NewGuid(),
                RemnawaveSubscriptionId = id,
                CreatedAt = now,
            });
            added++;
        }

        await db.SaveChangesAsync(ct);
        return StatusCode(StatusCodes.Status201Created, new { added });
    }

    [HttpGet]
    public async Task<IActionResult> GetStatus(CancellationToken ct)
    {
        if (!BotSecretValidator.IsValid(Request.Headers[BotSecretValidator.HeaderName], botOptions.Value.Secret))
        {
            return Unauthorized();
        }

        var total = await db.TrialSubscriptionSlots.CountAsync(ct);
        var available = await db.TrialSubscriptionSlots.CountAsync(s => !s.IsAssigned, ct);
        return Ok(new { total, available });
    }
}

public sealed record AddTrialSlotsRequest(IReadOnlyList<string> RemnawaveSubscriptionIds);
