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
public class InternalTokensController(FatVpnDbContext db) : ControllerBase
{
    [HttpPost]
    public async Task<IActionResult> RegisterToken([FromBody] RegisterTokenRequest request, CancellationToken ct)
    {
        var token = await db.Tokens.SingleOrDefaultAsync(t => t.ShortToken == request.ShortToken, ct);
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
        // Reissuing a key unbinds it, so a user who changed/reinstalled their
        // phone can re-activate on the new device ("Поменять ключ" in the bot).
        token.BoundDeviceKeyHash = null;

        await db.SaveChangesAsync(ct);
        // Always 201, including on update. Wrong by REST, but the Python bot lives
        // outside this repo and may well test for it — not worth breaking key
        // reissue to fix cosmetics.
        return StatusCode(StatusCodes.Status201Created);
    }
}

public sealed record RegisterTokenRequest(
    [property: StringLength(128)] string ShortToken,
    [property: StringLength(64)] string RemnawaveSubscriptionId,
    DateTimeOffset ExpiresAt);
