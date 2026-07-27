using FatVpn.Bff.Api.Infrastructure;
using FatVpn.Bff.Api.Pairing;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
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
    [EnableRateLimiting(RateLimitPolicies.Auth)]
    public async Task<IActionResult> Start(CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;

        // Let the unique index detect a collision instead of pre-checking: the
        // old loop cost up to five database round trips on every /pair/start, and
        // a collision in a 32^8 space is astronomically unlikely anyway. Retrying
        // twice covers it without ever inserting a duplicate.
        for (var attempt = 0; ; attempt++)
        {
            var pairing = new PairingCode
            {
                Id = Guid.NewGuid(),
                Code = PairingCodeGenerator.NewCode(),
                PollToken = PairingCodeGenerator.NewPollToken(),
                Status = PairingStatus.Pending,
                CreatedAt = now,
                ExpiresAt = now + CodeLifetime,
            };
            db.PairingCodes.Add(pairing);

            try
            {
                await db.SaveChangesAsync(ct);
            }
            catch (DbUpdateException) when (attempt < 2)
            {
                db.Entry(pairing).State = EntityState.Detached;
                continue;
            }

            return Ok(new
            {
                pairCode = pairing.Code,
                pollToken = pairing.PollToken,
                expiresAt = pairing.ExpiresAt,
            });
        }
    }

    /// <summary>App polls with its pollToken until the bot completes pairing.</summary>
    /// <summary>Header alternative to the <c>pollToken</c> query parameter. The
    /// token is a bearer secret, and a query string ends up in proxy access logs
    /// and APM traces. The query form stays supported so shipped app builds keep
    /// working; new clients should send the header.</summary>
    public const string PollTokenHeader = "X-Pair-Poll-Token";

    [HttpGet("status")]
    // Looser than the rest of the auth surface: the app polls this every 2 s
    // while the user is over in Telegram.
    [EnableRateLimiting(RateLimitPolicies.PairStatus)]
    public async Task<IActionResult> Status([FromQuery] string? pollToken, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(pollToken))
        {
            pollToken = HttpContext?.Request.Headers[PollTokenHeader].ToString();
        }

        if (string.IsNullOrEmpty(pollToken))
        {
            return BadRequest();
        }

        var pairing = await db.PairingCodes.AsNoTracking()
            .SingleOrDefaultAsync(p => p.PollToken == pollToken, ct);
        if (pairing is null)
        {
            return NotFound();
        }

        if (pairing.Status == PairingStatus.Completed && pairing.AccountId is not null)
        {
            // Single-use, and it has to be a single atomic step: the app polls in a
            // loop, so a retry or a doubled request used to let two callers both
            // read "Completed" and both mint a 90-day session off one code. Only
            // the request that actually flips the status wins; the loser is told to
            // re-pair. The transaction ties the refresh-token insert to that flip,
            // so a failure here doesn't burn the code for nothing.
            await using var transaction = await db.Database.BeginTransactionAsync(ct);

            var claimed = await db.PairingCodes
                .Where(p => p.Id == pairing.Id && p.Status == PairingStatus.Completed)
                .ExecuteUpdateAsync(s => s.SetProperty(p => p.Status, PairingStatus.Consumed), ct);
            if (claimed != 1)
            {
                await transaction.RollbackAsync(ct);
                return Ok(new { status = "expired" });
            }

            var account = await db.Accounts.FindAsync([pairing.AccountId.Value], ct);
            if (account is null)
            {
                // The account vanished under a completed code. The code stays
                // consumed on purpose — otherwise the app polls this forever.
                await transaction.CommitAsync(ct);
                return Ok(new { status = "expired" });
            }

            var accessToken = jwtTokenService.CreateAccessTokenForAccount(account);
            var (refreshRaw, refreshEntity) = refreshTokenService.Create(account.Id, tokenId: null);
            db.RefreshTokens.Add(refreshEntity);
            await db.SaveChangesAsync(ct);
            await transaction.CommitAsync(ct);

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
