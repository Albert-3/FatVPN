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
        var expiresAt = await ResolveExpiryAsync(ct);
        if (expiresAt is null)
        {
            return NotFound();
        }

        var status = expiresAt > DateTimeOffset.UtcNow ? "active" : "expired";
        return Ok(new { status, expiresAt });
    }

    // Account-based sessions (pairing) resolve the current subscription through
    // the account; legacy deep-link tokens fall back to the token row.
    private async Task<DateTimeOffset?> ResolveExpiryAsync(CancellationToken ct)
    {
        var accountId = User.TryGetAccountId();
        if (accountId is not null)
        {
            var account = await db.Accounts.FindAsync([accountId.Value], ct);
            return account?.ExpiresAt;
        }

        var token = await db.Tokens.FindAsync([User.GetTokenId()], ct);
        return token?.ExpiresAt;
    }
}
