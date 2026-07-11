using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Bot;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("internal/tokens")]
public class InternalTokensController(FatVpnDbContext db, IOptions<BotOptions> botOptions) : ControllerBase
{
    [HttpPost]
    public async Task<IActionResult> RegisterToken([FromBody] RegisterTokenRequest request, CancellationToken ct)
    {
        if (!BotSecretValidator.IsValid(Request.Headers[BotSecretValidator.HeaderName], botOptions.Value.Secret))
        {
            return Unauthorized();
        }

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
        token.ExpiresAt = request.ExpiresAt;
        // Reissuing a key unbinds it, so a user who changed/reinstalled their
        // phone can re-activate on the new device ("Поменять ключ" in the bot).
        token.BoundDeviceKeyHash = null;

        await db.SaveChangesAsync(ct);
        return StatusCode(StatusCodes.Status201Created);
    }
}

public sealed record RegisterTokenRequest(string ShortToken, string RemnawaveSubscriptionId, DateTimeOffset ExpiresAt);
