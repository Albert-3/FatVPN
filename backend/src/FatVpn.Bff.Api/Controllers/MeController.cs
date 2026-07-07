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
            return NotFound();
        }

        var status = subscription.IsActive ? "active" : "expired";
        return Ok(new { status, expiresAt = subscription.ExpiresAt });
    }
}
