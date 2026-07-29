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
    /// <param name="makeActive">
    /// Whether the user actually chose this key. A user can hold several keys in
    /// the bot, and the account carries exactly one active subscription, so a
    /// call about some *other* key must not silently move the app onto it —
    /// extending key #2 used to switch a subscriber connected on key #1. Only an
    /// explicit choice (pairing, pasting the code, "поменять ключ") switches;
    /// everything else may refresh the key that is already active, and an
    /// account with no key yet adopts whatever arrives first.
    /// </param>
    /// <param name="replacesSubscriptionId">
    /// The subscription this one was created to replace, when the bot recreated
    /// a key rather than making a new one ("поменять ключ", and extending via
    /// re-issue — both delete the panel user and mint a fresh shortUuid). The
    /// app follows only if it was on the key that got replaced, which is the
    /// difference between "your key was renewed" and "you were moved onto
    /// someone else's".
    /// </param>
    public static async Task<Account> UpsertAsync(
        FatVpnDbContext db, long telegramUserId, string subscriptionId, DateTimeOffset expiresAt,
        string? keyCode, bool makeActive, string? replacesSubscriptionId, CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        var account = await EnsureAccountAsync(db, telegramUserId, now, ct);

        var isActiveKey = account.CurrentSubscriptionId == subscriptionId;
        var hasNoKey = string.IsNullOrEmpty(account.CurrentSubscriptionId);
        var replacesActiveKey = !string.IsNullOrEmpty(replacesSubscriptionId)
            && account.CurrentSubscriptionId == replacesSubscriptionId;
        // A subscription that has already run out is not worth protecting: the
        // app is sitting on the renew screen because of it. Whatever the bot
        // reports next is an improvement, so adopt it — this is the user who
        // let their key lapse and then bought a new one.
        var activeKeyLapsed = !hasNoKey && account.ExpiresAt <= now;

        if (!makeActive && !isActiveKey && !hasNoKey && !replacesActiveKey && !activeKeyLapsed)
        {
            // A different, still-live key of the same user. Nothing here belongs
            // to the active subscription, so writing any of it would be a lie.
            return account;
        }

        var switchingKey = account.CurrentSubscriptionId != subscriptionId;

        account.CurrentSubscriptionId = subscriptionId;
        // Only overwrite the displayed key code when the caller actually sent one,
        // so a bot build that predates this field doesn't wipe a good value.
        if (!string.IsNullOrEmpty(keyCode))
        {
            account.CurrentKeyCode = keyCode;
        }
        else if (switchingKey)
        {
            // Moving onto another key with no code to show for it: the code we
            // hold belongs to the key being left behind. Keeping it would put
            // someone else's code under "текущий ключ" in the app, and pasting
            // that on a second phone would land it on a different subscription.
            // No code at all is honest — the app falls back to the id.
            account.CurrentKeyCode = null;
        }

        // Npgsql only accepts a DateTimeOffset with a zero offset for
        // timestamptz. The bot sends Moscow time ("...+03:00"), which used to
        // make SaveChanges throw and the whole pairing fail with a 500.
        account.ExpiresAt = expiresAt.ToUniversalTime();
        account.UpdatedAt = now;

        return account;
    }

    /// <summary>
    /// Returns the user's account, creating it if this is the first we hear of
    /// them, without touching the active subscription. Used by
    /// <c>/internal/tokens</c>, which learns whose a key is but says nothing
    /// about which key the user wants to use.
    /// </summary>
    public static Task<Account> EnsureAsync(FatVpnDbContext db, long telegramUserId, CancellationToken ct) =>
        EnsureAccountAsync(db, telegramUserId, DateTimeOffset.UtcNow, ct);

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
