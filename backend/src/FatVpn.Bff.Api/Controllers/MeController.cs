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
        var token = await db.Tokens.FindAsync([User.GetTokenId()], ct);
        if (token is null)
        {
            return NotFound();
        }

        var status = token.ExpiresAt > DateTimeOffset.UtcNow ? "active" : "expired";
        return Ok(new { status, expiresAt = token.ExpiresAt });
    }
}
