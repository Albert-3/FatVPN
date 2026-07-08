using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("me")]
[Authorize]
public class MeController(FatVpnDbContext db) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetMe(CancellationToken ct)
    {
        var subscription = await db.ResolveSubscriptionAsync(User, ct);
        if (subscription is null)
        {
            // Token is valid but resolves to no session (account/token row gone).
            // Same 401 as /servers and /config so the app treats "session vanished"
            // uniformly and re-authenticates.
            return Unauthorized();
        }

        var status = subscription.IsActive ? "active" : "expired";
        return Ok(new { status, expiresAt = subscription.ExpiresAt });
    }
}
