using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Bot;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("internal/pair")]
public class InternalPairController(FatVpnDbContext db, IOptions<BotOptions> botOptions) : ControllerBase
{
    /// <summary>Bot redeems a pairing code and binds the user's account to it.</summary>
    [HttpPost("complete")]
    public async Task<IActionResult> Complete([FromBody] CompletePairingRequest request, CancellationToken ct)
    {
        if (!BotSecretValidator.IsValid(Request.Headers[BotSecretValidator.HeaderName], botOptions.Value.Secret))
        {
            return Unauthorized();
        }

        var pairing = await db.PairingCodes.SingleOrDefaultAsync(p => p.Code == request.PairCode, ct);
        if (pairing is null)
        {
            return NotFound();
        }

        if (pairing.Status == PairingStatus.Completed)
        {
            return Conflict();
        }

        if (pairing.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            return NotFound();
        }

        var account = await AccountUpsert.UpsertAsync(
            db, request.TelegramUserId, request.SubscriptionId, request.ExpiresAt, ct);

        pairing.AccountId = account.Id;
        pairing.Status = PairingStatus.Completed;

        await db.SaveChangesAsync(ct);
        return Ok();
    }
}

public sealed record CompletePairingRequest(
    string PairCode, long TelegramUserId, string SubscriptionId, DateTimeOffset ExpiresAt);
