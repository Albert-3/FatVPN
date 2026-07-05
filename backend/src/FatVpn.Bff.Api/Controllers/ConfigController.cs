using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Remnawave;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("config")]
[Authorize]
public class ConfigController(FatVpnDbContext db, IRemnawaveClient remnawaveClient) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetConfig(CancellationToken ct)
    {
        var subscription = await ResolveSubscriptionAsync(ct);
        if (subscription is null)
        {
            return Unauthorized();
        }

        try
        {
            var (content, contentType) = await remnawaveClient.GetSubscriptionConfigAsync(subscription, ct);
            return Content(content, contentType);
        }
        catch (HttpRequestException)
        {
            return StatusCode(StatusCodes.Status502BadGateway);
        }
    }

    // Returns the current Remnawave subscription id for the caller, or null if
    // the session is expired/unknown. Account sessions (pairing) resolve through
    // the account; legacy deep-link tokens fall back to the token row.
    private async Task<string?> ResolveSubscriptionAsync(CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;

        var accountId = User.TryGetAccountId();
        if (accountId is not null)
        {
            var account = await db.Accounts.FindAsync([accountId.Value], ct);
            if (account is null || account.ExpiresAt <= now)
            {
                return null;
            }

            return account.CurrentSubscriptionId;
        }

        var token = await db.Tokens.FindAsync([User.GetTokenId()], ct);
        if (token is null || token.ExpiresAt <= now)
        {
            return null;
        }

        return token.RemnawaveSubscriptionId;
    }
}
