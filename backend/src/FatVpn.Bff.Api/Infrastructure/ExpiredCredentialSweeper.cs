using FatVpn.Bff.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Api.Infrastructure;

/// <summary>
/// Deletes credentials nobody can use any more. Rotation writes one refresh-token
/// row per /auth/refresh — roughly 48 per device per day — and /pair/start writes
/// a pairing code that is never cleaned up, so both tables grow without limit and
/// slow down the auth paths that scan them.
/// </summary>
public sealed class ExpiredCredentialSweeper(
    IServiceScopeFactory scopeFactory,
    ILogger<ExpiredCredentialSweeper> logger) : BackgroundService
{
    private static readonly TimeSpan Interval = TimeSpan.FromHours(24);

    /// <summary>Kept well past expiry so a support question ("why was I logged
    /// out?") can still be answered from the row rather than guessed at.</summary>
    private static readonly TimeSpan RefreshTokenRetention = TimeSpan.FromDays(30);

    private static readonly TimeSpan RevokedTokenRetention = TimeSpan.FromDays(7);
    private static readonly TimeSpan PairingCodeRetention = TimeSpan.FromDays(1);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        // Not on startup: a deploy restarts the container, and a rollout of
        // several instances would otherwise all sweep at once.
        using var timer = new PeriodicTimer(Interval);
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            try
            {
                await SweepAsync(stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                // Housekeeping failing is not a reason to take the API down with it.
                logger.LogError(ex, "Expired-credential sweep failed; will retry on the next tick");
            }
        }
    }

    private async Task SweepAsync(CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<FatVpnDbContext>();
        var now = DateTimeOffset.UtcNow;

        var expiredCutoff = now - RefreshTokenRetention;
        var revokedCutoff = now - RevokedTokenRetention;
        var refreshTokens = await db.RefreshTokens
            .Where(r => r.ExpiresAt < expiredCutoff
                || (r.RevokedAt != null && r.RevokedAt < revokedCutoff))
            .ExecuteDeleteAsync(ct);

        var pairingCutoff = now - PairingCodeRetention;
        var pairingCodes = await db.PairingCodes
            .Where(p => p.ExpiresAt < pairingCutoff)
            .ExecuteDeleteAsync(ct);

        if (refreshTokens > 0 || pairingCodes > 0)
        {
            logger.LogInformation(
                "Swept {RefreshTokens} spent refresh tokens and {PairingCodes} stale pairing codes",
                refreshTokens, pairingCodes);
        }
    }
}
