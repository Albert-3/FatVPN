using System.ComponentModel.DataAnnotations;
using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("internal/account")]
[Authorize(Policy = BotSecretRequirement.PolicyName)]
public class InternalAccountController(FatVpnDbContext db) : ControllerBase
{
    /// <summary>
    /// Bot pushes the account's current subscription whenever the active key
    /// changes (create/change/extend). Keeps the app session valid across
    /// bot-side key rotations.
    /// </summary>
    [HttpPost("subscription")]
    public async Task<IActionResult> UpsertSubscription([FromBody] UpsertSubscriptionRequest request, CancellationToken ct)
    {
        await AccountUpsert.UpsertAsync(
            db, request.TelegramUserId, request.SubscriptionId, request.ExpiresAt, request.KeyCode,
            request.MakeActive, request.ReplacesSubscriptionId, ct);

        await db.SaveChangesAsync(ct);
        return Ok();
    }
}

public sealed record UpsertSubscriptionRequest(
    long TelegramUserId,
    [StringLength(64)] string SubscriptionId,
    DateTimeOffset ExpiresAt,
    [StringLength(64)] string? KeyCode = null,
    // True only when the user just chose this key for the app. Left false for a
    // routine extension, so extending a key the user is *not* connected on no
    // longer drags the app over to it.
    bool MakeActive = false,
    // Set when this key replaces one the bot just deleted (key change, or an
    // extension done by re-issue). The app follows only if it was on that key.
    [StringLength(64)] string? ReplacesSubscriptionId = null);
