using System.ComponentModel.DataAnnotations;
using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("internal/trial-pool")]
[Authorize(Policy = BotSecretRequirement.PolicyName)]
public class InternalTrialPoolController(FatVpnDbContext db) : ControllerBase
{
    /// <summary>Bounds one call's work; the list was previously unlimited.</summary>
    private const int MaxSlotsPerCall = 500;

    [HttpPost]
    public async Task<IActionResult> AddSlots([FromBody] AddTrialSlotsRequest request, CancellationToken ct)
    {
        var requested = request.RemnawaveSubscriptionIds.Distinct().ToList();
        if (requested.Count > MaxSlotsPerCall)
        {
            return BadRequest(new { message = $"At most {MaxSlotsPerCall} ids per call" });
        }

        // Only the ids actually asked about, rather than the whole table: this
        // used to pull every slot into memory to check a handful of them.
        var existingSet = (await db.TrialSubscriptionSlots
                .Where(s => requested.Contains(s.RemnawaveSubscriptionId))
                .Select(s => s.RemnawaveSubscriptionId)
                .ToListAsync(ct))
            .ToHashSet();

        var now = DateTimeOffset.UtcNow;
        var added = 0;
        foreach (var id in requested)
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
        var total = await db.TrialSubscriptionSlots.CountAsync(ct);
        var available = await db.TrialSubscriptionSlots.CountAsync(s => !s.IsAssigned, ct);
        return Ok(new { total, available });
    }
}

public sealed record AddTrialSlotsRequest(
    [property: MaxLength(500)] IReadOnlyList<string> RemnawaveSubscriptionIds);
