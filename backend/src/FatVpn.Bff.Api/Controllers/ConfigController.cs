using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Remnawave;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("config")]
[Authorize]
public class ConfigController(
    FatVpnDbContext db,
    IRemnawaveClient remnawaveClient,
    IOptions<RemnawaveOptions> remnawaveOptions) : ControllerBase
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
            // Remnawave doesn't render our Hysteria2 (FR/US/FI "H2") nodes into the
            // subscription, so we can splice them in for the app. Off by default —
            // the synthesized links bring the tunnel up but carry no traffic, which
            // the app can't tell apart from a working server. See
            // RemnawaveOptions.AugmentHysteria before turning this on.
            if (remnawaveOptions.Value.AugmentHysteria)
            {
                content = SubscriptionAugmenter.AppendHysteriaHosts(content);
            }
            return Content(content, contentType);
        }
        catch (HttpRequestException)
        {
            return StatusCode(StatusCodes.Status502BadGateway);
        }
    }
}
