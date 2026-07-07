using FatVpn.Bff.Api.Pairing;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("pair")]
public class PairController(
    FatVpnDbContext db,
    IJwtTokenService jwtTokenService,
    IRefreshTokenService refreshTokenService) : ControllerBase
{
    private static readonly TimeSpan CodeLifetime = TimeSpan.FromMinutes(15);

    /// <summary>App starts a pairing attempt; shows the code/QR and opens the bot.</summary>
    [HttpPost("start")]
    public async Task<IActionResult> Start(CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;

        string code;
        var attempts = 0;
        do
        {
            code = PairingCodeGenerator.NewCode();
            attempts++;
        }
        while (await db.PairingCodes.AnyAsync(p => p.Code == code, ct) && attempts < 5);

        var pairing = new PairingCode
        {
            Id = Guid.NewGuid(),
            Code = code,
            PollToken = PairingCodeGenerator.NewPollToken(),
            Status = PairingStatus.Pending,
            CreatedAt = now,
            ExpiresAt = now + CodeLifetime,
        };
        db.PairingCodes.Add(pairing);
        await db.SaveChangesAsync(ct);

        return Ok(new
        {
            pairCode = pairing.Code,
            pollToken = pairing.PollToken,
            expiresAt = pairing.ExpiresAt,
        });
    }

    /// <summary>App polls with its pollToken until the bot completes pairing.</summary>
    [HttpGet("status")]
    public async Task<IActionResult> Status([FromQuery] string pollToken, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(pollToken))
        {
            return BadRequest();
        }

        var pairing = await db.PairingCodes.SingleOrDefaultAsync(p => p.PollToken == pollToken, ct);
        if (pairing is null)
        {
            return NotFound();
        }

        if (pairing.Status == PairingStatus.Completed && pairing.AccountId is not null)
        {
            var account = await db.Accounts.FindAsync([pairing.AccountId.Value], ct);
            if (account is null)
            {
                return Ok(new { status = "expired" });
            }

            var accessToken = jwtTokenService.CreateAccessTokenForAccount(account);
            var (refreshRaw, refreshEntity) = refreshTokenService.Create(account.Id, tokenId: null);
            db.RefreshTokens.Add(refreshEntity);
            await db.SaveChangesAsync(ct);

            return Ok(new { status = "completed", accessToken, refreshToken = refreshRaw, expiresAt = account.ExpiresAt });
        }

        if (pairing.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            return Ok(new { status = "expired" });
        }

        return Ok(new { status = "pending" });
    }
}
