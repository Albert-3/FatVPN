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
        var token = await db.Tokens.FindAsync([User.GetTokenId()], ct);
        if (token is null || token.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            return Unauthorized();
        }

        try
        {
            using var config = await remnawaveClient.GetSubscriptionConfigAsync(token.RemnawaveSubscriptionId, ct);
            return Content(config.RootElement.GetRawText(), "application/json");
        }
        catch (HttpRequestException)
        {
            return StatusCode(StatusCodes.Status502BadGateway);
        }
    }
}
