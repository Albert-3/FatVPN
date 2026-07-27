using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Api.Controllers;

/// <summary>
/// Shared upsert of an <see cref="Account"/> by Telegram id. Creating a missing
/// row is committed on its own (see <c>EnsureAccountAsync</c>); the field
/// updates are left pending for the caller's unit of work.
/// </summary>
internal static class AccountUpsert
{
    public static async Task<Account> UpsertAsync(
        FatVpnDbContext db, long telegramUserId, string subscriptionId, DateTimeOffset expiresAt,
        string? keyCode, CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        var account = await EnsureAccountAsync(db, telegramUserId, now, ct);

        account.CurrentSubscriptionId = subscriptionId;
        // Only overwrite the displayed key code when the caller actually sent one,
        // so a bot build that predates this field doesn't wipe a good value.
        if (!string.IsNullOrEmpty(keyCode))
        {
            account.CurrentKeyCode = keyCode;
        }

        // Npgsql only accepts a DateTimeOffset with a zero offset for
        // timestamptz. The bot sends Moscow time ("...+03:00"), which used to
        // make SaveChanges throw and the whole pairing fail with a 500.
        account.ExpiresAt = expiresAt.ToUniversalTime();
        account.UpdatedAt = now;

        return account;
    }

    /// <summary>
    /// Returns the account, creating it if it is missing. "Bought a key and
    /// paired straight away" fires /internal/pair/complete and
    /// /internal/account/subscription at the same moment; a read-then-write let
    /// both decide to insert and the second one died on the unique index. Let
    /// the index pick the winner and adopt whatever it chose.
    /// </summary>
    private static async Task<Account> EnsureAccountAsync(
        FatVpnDbContext db, long telegramUserId, DateTimeOffset now, CancellationToken ct)
    {
        var account = await db.Accounts.SingleOrDefaultAsync(a => a.TelegramUserId == telegramUserId, ct);
        if (account is not null)
        {
            return account;
        }

        account = new Account
        {
            Id = Guid.NewGuid(),
            TelegramUserId = telegramUserId,
            CreatedAt = now,
        };
        db.Accounts.Add(account);

        try
        {
            await db.SaveChangesAsync(ct);
            return account;
        }
        catch (DbUpdateException)
        {
            db.Entry(account).State = EntityState.Detached;
            var winner = await db.Accounts.SingleOrDefaultAsync(a => a.TelegramUserId == telegramUserId, ct);
            if (winner is null)
            {
                // No winner means this was some other write failure, not the race.
                throw;
            }

            return winner;
        }
    }
}
