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

        // Deliberately not cached: unlike /servers this response is per-user and
        // carries the subscription's credentials, and it is fetched once per
        // connect rather than on every screen refresh.
        var (content, contentType) = await remnawaveClient.GetSubscriptionConfigAsync(subscription.SubscriptionId, ct);
        // Remnawave renders our Hysteria2 (FR/US/FI "H2") nodes only into its
        // xray-json output, never into the base64/sing-box/clash formats the app
        // consumes — so we splice them in ourselves. On by default; the links are
        // verified to carry traffic (see RemnawaveOptions.AugmentHysteria).
        if (remnawaveOptions.Value.AugmentHysteria)
        {
            content = SubscriptionAugmenter.AppendHysteriaHosts(content, remnawaveOptions.Value.HysteriaHosts);
        }

        return Content(content, contentType);
    }
}
