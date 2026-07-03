using System.Security.Cryptography;
using System.Text;
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
    private const string BotSecretHeader = "X-Bot-Secret";

    [HttpPost]
    public async Task<IActionResult> RegisterToken([FromBody] RegisterTokenRequest request, CancellationToken ct)
    {
        if (!IsValidBotSecret(Request.Headers[BotSecretHeader]))
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

        await db.SaveChangesAsync(ct);
        return StatusCode(StatusCodes.Status201Created);
    }

    private bool IsValidBotSecret(string? provided)
    {
        var expected = botOptions.Value.Secret;
        if (string.IsNullOrEmpty(provided) || string.IsNullOrEmpty(expected) || provided.Length != expected.Length)
        {
            return false;
        }

        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(provided),
            Encoding.UTF8.GetBytes(expected));
    }
}

public sealed record RegisterTokenRequest(string ShortToken, string RemnawaveSubscriptionId, DateTimeOffset ExpiresAt);
