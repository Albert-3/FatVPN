using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Remnawave;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("servers")]
[Authorize]
public class ServersController(FatVpnDbContext db, IRemnawaveClient remnawaveClient) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetServers(CancellationToken ct)
    {
        var subscription = await db.ResolveSubscriptionAsync(User, ct);
        if (subscription is null)
        {
            return Unauthorized();
        }

        if (!subscription.IsActive)
        {
            // Lapsed subscription — same 402 signal as /config so the app routes
            // to the renew screen instead of listing servers it can't connect to.
            return StatusCode(StatusCodes.Status402PaymentRequired);
        }

        try
        {
            var servers = await remnawaveClient.GetNodesAsync(ct);
            return Ok(servers);
        }
        catch (HttpRequestException)
        {
            return StatusCode(StatusCodes.Status502BadGateway);
        }
    }
}
