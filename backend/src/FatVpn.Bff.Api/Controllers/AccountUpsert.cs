using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Api.Controllers;

/// <summary>
/// Shared upsert of an <see cref="Account"/> by Telegram id. Does not call
/// SaveChanges — the caller owns the unit of work.
/// </summary>
internal static class AccountUpsert
{
    public static async Task<Account> UpsertAsync(
        FatVpnDbContext db, long telegramUserId, string subscriptionId, DateTimeOffset expiresAt,
        string? keyCode, CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        var account = await db.Accounts.SingleOrDefaultAsync(a => a.TelegramUserId == telegramUserId, ct);

        if (account is null)
        {
            account = new Account
            {
                Id = Guid.NewGuid(),
                TelegramUserId = telegramUserId,
                CreatedAt = now,
            };
            db.Accounts.Add(account);
        }

        account.CurrentSubscriptionId = subscriptionId;
        // Only overwrite the displayed key code when the caller actually sent one,
        // so a bot build that predates this field doesn't wipe a good value.
        if (!string.IsNullOrEmpty(keyCode))
        {
            account.CurrentKeyCode = keyCode;
        }
        account.ExpiresAt = expiresAt;
        account.UpdatedAt = now;

        return account;
    }
}
