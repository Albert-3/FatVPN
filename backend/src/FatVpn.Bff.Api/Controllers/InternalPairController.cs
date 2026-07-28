using System.ComponentModel.DataAnnotations;
using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("internal/pair")]
[Authorize(Policy = BotSecretRequirement.PolicyName)]
public class InternalPairController(FatVpnDbContext db) : ControllerBase
{
    /// <summary>Bot redeems a pairing code and binds the user's account to it.</summary>
    [HttpPost("complete")]
    public async Task<IActionResult> Complete([FromBody] CompletePairingRequest request, CancellationToken ct)
    {
        var pairing = await db.PairingCodes.SingleOrDefaultAsync(p => p.Code == request.PairCode, ct);
        if (pairing is null)
        {
            return NotFound();
        }

        if (pairing.Status != PairingStatus.Pending)
        {
            // Already completed or consumed — a code binds exactly one account, once.
            return Conflict();
        }

        if (pairing.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            return NotFound();
        }

        // Pairing is the user picking a key in the bot and pointing the app at
        // it, so it always switches the account onto that key.
        var account = await AccountUpsert.UpsertAsync(
            db, request.TelegramUserId, request.SubscriptionId, request.ExpiresAt, request.KeyCode,
            makeActive: true, replacesSubscriptionId: null, ct);

        pairing.AccountId = account.Id;
        pairing.Status = PairingStatus.Completed;

        await db.SaveChangesAsync(ct);
        return Ok();
    }
}

public sealed record CompletePairingRequest(
    [property: StringLength(32)] string PairCode,
    long TelegramUserId,
    [property: StringLength(64)] string SubscriptionId,
    DateTimeOffset ExpiresAt,
    [property: StringLength(64)] string? KeyCode = null);
