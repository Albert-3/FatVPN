using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Bot;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("internal/account")]
public class InternalAccountController(FatVpnDbContext db, IOptions<BotOptions> botOptions) : ControllerBase
{
    /// <summary>
    /// Bot pushes the account's current subscription whenever the active key
    /// changes (create/change/extend). Keeps the app session valid across
    /// bot-side key rotations.
    /// </summary>
    [HttpPost("subscription")]
    public async Task<IActionResult> UpsertSubscription([FromBody] UpsertSubscriptionRequest request, CancellationToken ct)
    {
        if (!BotSecretValidator.IsValid(Request.Headers[BotSecretValidator.HeaderName], botOptions.Value.Secret))
        {
            return Unauthorized();
        }

        await AccountUpsert.UpsertAsync(
            db, request.TelegramUserId, request.SubscriptionId, request.ExpiresAt, ct);

        await db.SaveChangesAsync(ct);
        return Ok();
    }
}

public sealed record UpsertSubscriptionRequest(
    long TelegramUserId, string SubscriptionId, DateTimeOffset ExpiresAt);
