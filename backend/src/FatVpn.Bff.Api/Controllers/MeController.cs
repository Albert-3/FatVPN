using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("me")]
[Authorize]
public class MeController(FatVpnDbContext db, IJwtTokenService jwtTokenService) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetMe(CancellationToken ct)
    {
        var subscription = await db.ResolveSubscriptionAsync(User, ct);
        if (subscription is null)
        {
            return NotFound();
        }

        // Rolling refresh: hand back a token with a fresh lifetime so an app that
        // opens within the token window never gets stranded, and picks up a newly
        // extended subscription expiry without re-pairing.
        var accessToken = jwtTokenService.Refresh(User);
        var status = subscription.IsActive ? "active" : "expired";
        return Ok(new { status, expiresAt = subscription.ExpiresAt, accessToken });
    }
}
