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
        bool collides;
        do
        {
            code = PairingCodeGenerator.NewCode();
            attempts++;
            collides = await db.PairingCodes.AnyAsync(p => p.Code == code, ct);
        }
        while (collides && attempts < 5);

        if (collides)
        {
            // Five straight collisions is astronomically unlikely (32^8 space); if it
            // happens, fail loudly rather than insert a dup and hit the unique index.
            return StatusCode(StatusCodes.Status503ServiceUnavailable);
        }

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
            // Single-use: burn the code so a repeated poll can't mint another session.
            pairing.Status = PairingStatus.Consumed;
            await db.SaveChangesAsync(ct);

            return Ok(new { status = "completed", accessToken, refreshToken = refreshRaw, expiresAt = account.ExpiresAt });
        }

        // Already delivered (or expired): the app captured its tokens on the first
        // "completed" and stopped polling; anything else must re-pair.
        if (pairing.Status == PairingStatus.Consumed || pairing.ExpiresAt <= DateTimeOffset.UtcNow)
        {
            return Ok(new { status = "expired" });
        }

        return Ok(new { status = "pending" });
    }
}
