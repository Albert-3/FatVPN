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
        var subscription = await db.ResolveSubscriptionAsync(User, ct);
        if (subscription is null || subscription.SubscriptionId is null)
        {
            // Unknown session — the token is valid but maps to no subscription.
            return Unauthorized();
        }

        if (!subscription.IsActive)
        {
            // Authenticated but the subscription has lapsed. 402 lets the app tell
            // "renew required" apart from a genuinely bad token (401).
            return StatusCode(StatusCodes.Status402PaymentRequired);
        }

        try
        {
            var (content, contentType) = await remnawaveClient.GetSubscriptionConfigAsync(subscription.SubscriptionId, ct);
            return Content(content, contentType);
        }
        catch (HttpRequestException)
        {
            return StatusCode(StatusCodes.Status502BadGateway);
        }
    }
}
