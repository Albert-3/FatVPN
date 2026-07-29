using System.ComponentModel.DataAnnotations;
using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("internal/tokens")]
[Authorize(Policy = BotSecretRequirement.PolicyName)]
public class InternalTokensController(FatVpnDbContext db, Auth.DeviceSlots deviceSlots) : ControllerBase
{
    [HttpPost]
    public async Task<IActionResult> RegisterToken([FromBody] RegisterTokenRequest request, CancellationToken ct)
    {
        var token = await db.Tokens.SingleOrDefaultAsync(t => t.ShortToken == request.ShortToken, ct);
        var replacedSubscriptionId = token?.RemnawaveSubscriptionId;
        if (token is null)
        {
            token = new Token
            {
                Id = Guid.NewGuid(),
                ShortToken = request.ShortToken,
                CreatedAt = DateTimeOffset.UtcNow,
            };
            db.Tokens.Add(token);
        }

        token.RemnawaveSubscriptionId = request.RemnawaveSubscriptionId;
        // Npgsql rejects a non-zero offset on timestamptz; the bot sends Moscow time.
        token.ExpiresAt = request.ExpiresAt.ToUniversalTime();
        // The legacy single-slot column is cleared too — it is no longer read, but
        // a rollback to the previous image would read it again.
        token.BoundDeviceKeyHash = null;

        // "Поменять ключ" mints a fresh subscription and points this code at it;
        // whoever was connected to the old one is connected to nothing now, so its
        // slots go back. Only when the subscription actually changed: the bot also
        // re-posts a code unchanged (to expire it, say), and that used to free
        // every slot of a key nobody had touched.
        if (!string.IsNullOrEmpty(replacedSubscriptionId)
            && replacedSubscriptionId != request.RemnawaveSubscriptionId)
        {
            await deviceSlots.ReleaseSubscriptionAsync(replacedSubscriptionId, ct);
        }

        // Whose key this is, when the bot says so. Deliberately does NOT touch
        // the account's active subscription: handing the user a code to look at
        // is not the same as the user choosing to connect with it — that
        // happens in /auth/token, when they actually paste it.
        if (request.TelegramUserId is not null)
        {
            var account = await AccountUpsert.EnsureAsync(db, request.TelegramUserId.Value, ct);
            token.AccountId = account.Id;
        }

        await db.SaveChangesAsync(ct);
        // Always 201, including on update. Wrong by REST, but the Python bot lives
        // outside this repo and may well test for it — not worth breaking key
        // reissue to fix cosmetics.
        return StatusCode(StatusCodes.Status201Created);
    }
}

public sealed record RegisterTokenRequest(
    [StringLength(128)] string ShortToken,
    [StringLength(64)] string RemnawaveSubscriptionId,
    DateTimeOffset ExpiresAt,
    // Optional: the key's owner. Without it the key stays a session identity of
    // its own and misses every later extension — see Token.AccountId.
    long? TelegramUserId = null);
