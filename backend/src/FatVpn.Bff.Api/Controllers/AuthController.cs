using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("auth")]
public class AuthController(FatVpnDbContext db, IJwtTokenService jwtTokenService) : ControllerBase
{
    [HttpPost("token")]
    public async Task<IActionResult> ExchangeToken([FromBody] ExchangeTokenRequest request, CancellationToken ct)
    {
        var token = await db.Tokens.SingleOrDefaultAsync(t => t.ShortToken == request.ShortToken, ct);
        if (token is null || token.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            return NotFound();
        }

        var accessToken = jwtTokenService.CreateAccessToken(token);
        return Ok(new { accessToken, expiresAt = token.ExpiresAt });
    }
}

public sealed record ExchangeTokenRequest(string ShortToken);
