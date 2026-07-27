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
            db, request.TelegramUserId, request.SubscriptionId, request.ExpiresAt, request.KeyCode, ct);

        await db.SaveChangesAsync(ct);
        return Ok();
    }
}

public sealed record UpsertSubscriptionRequest(
    long TelegramUserId,
    [property: StringLength(64)] string SubscriptionId,
    DateTimeOffset ExpiresAt,
    [property: StringLength(64)] string? KeyCode = null);
