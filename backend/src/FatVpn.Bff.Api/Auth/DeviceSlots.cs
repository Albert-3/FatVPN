using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Api.Auth;

/// <summary>
/// The "one key, up to N devices" cap, shared by every way a device can start
/// using a subscription. It lives here rather than in a controller because both
/// routes in have to obey it: pasting a code (<c>/auth/token</c>) and pairing
/// through the bot (<c>/pair/status</c>). While only the first counted, the cap
/// was advisory — the same user could connect any number of phones by pressing
/// "Подключить через Telegram" instead.
/// </summary>
public sealed class DeviceSlots(
    FatVpnDbContext db,
    IOptions<AuthOptions> authOptions,
    ILogger<DeviceSlots> logger)
{
    /// <summary>
    /// Gives <paramref name="deviceHash"/> one of the subscription's slots,
    /// evicting the device that has gone longest without being heard from if they
    /// are all taken. Idempotent for a device that already holds one. False only
    /// when there is genuinely no way in — no slots configured, or a racing
    /// arrival took the one we just freed.
    /// </summary>
    public async Task<bool> TryAdmitAsync(string subscriptionId, string deviceHash, CancellationToken ct)
    {
        if (string.IsNullOrEmpty(subscriptionId) || string.IsNullOrEmpty(deviceHash))
        {
            // Nothing to hang a slot on — an app build that sends no attestation,
            // or an account with no subscription yet. Let the caller through
            // without a slot, exactly as before device limits existed.
            return true;
        }

        if (await TryTakeFreeSlotAsync(subscriptionId, deviceHash, ct))
        {
            return true;
        }

        // Every slot is taken, so the phone that has gone longest without being
        // heard from gives one up. Exactly one eviction per attempt: a queue of
        // new phones would otherwise take turns throwing each other out.
        if (!await EvictLeastRecentlySeenAsync(subscriptionId, ct))
        {
            return false;
        }

        return await TryTakeFreeSlotAsync(subscriptionId, deviceHash, ct);
    }

    /// <summary>Records that a device is still in use, on every slot it holds.
    /// Keyed by the device rather than by one subscription, because that is all a
    /// refresh token identifies — and a phone heard from at all is a phone heard
    /// from for each of its subscriptions.</summary>
    public Task MarkSeenAsync(string deviceKeyHash, CancellationToken ct)
    {
        var now = DateTimeOffset.UtcNow;
        return db.TokenDevices
            .Where(d => d.DeviceKeyHash == deviceKeyHash)
            .ExecuteUpdateAsync(s => s.SetProperty(d => d.LastSeenAt, now), ct);
    }

    /// <summary>Gives back every slot a device holds — it has signed out.</summary>
    public Task ReleaseDeviceAsync(string deviceKeyHash, CancellationToken ct)
        => db.TokenDevices.Where(d => d.DeviceKeyHash == deviceKeyHash).ExecuteDeleteAsync(ct);

    /// <summary>Frees every slot of a subscription that no longer exists — the bot
    /// replaced it, so nobody is connected to it any more.</summary>
    public Task ReleaseSubscriptionAsync(string subscriptionId, CancellationToken ct)
        => db.TokenDevices.Where(d => d.SubscriptionId == subscriptionId).ExecuteDeleteAsync(ct);

    private async Task<bool> TryTakeFreeSlotAsync(string subscriptionId, string deviceHash, CancellationToken ct)
    {
        if (await HoldsASlotAsync(subscriptionId, deviceHash, ct))
        {
            // Coming back on a slot it already holds still counts as being seen:
            // without this a phone that only ever re-pastes its key, never
            // refreshing, would look abandoned and be first out.
            await MarkSeenAsync(deviceHash, ct);
            return true;
        }

        // Take the lowest slot this device can get. Deciding from a count would be
        // a read followed by a write, and four phones redeeming the same key at
        // once all read "room for one more"; here the unique index on
        // (SubscriptionId, SlotIndex) decides, and a loser tries the next slot.
        for (var slot = 0; slot < authOptions.Value.MaxDevicesPerKey; slot++)
        {
            var now = DateTimeOffset.UtcNow;
            var entry = db.TokenDevices.Add(new TokenDevice
            {
                Id = Guid.NewGuid(),
                SubscriptionId = subscriptionId,
                SlotIndex = slot,
                DeviceKeyHash = deviceHash,
                BoundAt = now,
                LastSeenAt = now,
            });

            try
            {
                // Its own SaveChanges: losing a slot is an ordinary outcome here
                // and must not take the caller's session down with it.
                await db.SaveChangesAsync(ct);
                return true;
            }
            catch (DbUpdateException)
            {
                // Either the slot went to someone else, or this same device is
                // already in and we collided with its own row. The writer we lost
                // to has committed by the time the violation surfaces, so asking
                // now gives a settled answer rather than a racy one.
                entry.State = EntityState.Detached;
                if (await HoldsASlotAsync(subscriptionId, deviceHash, ct))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private Task<bool> HoldsASlotAsync(string subscriptionId, string deviceHash, CancellationToken ct)
        => db.TokenDevices.AsNoTracking()
            .AnyAsync(d => d.SubscriptionId == subscriptionId && d.DeviceKeyHash == deviceHash, ct);

    /// <summary>
    /// Frees the slot of the device that has gone longest without being heard
    /// from, and ends its sessions so the slot count and reality agree — a phone
    /// left holding a 90-day refresh token would otherwise keep working after
    /// losing its place. Returns false when there was nothing to evict.
    /// </summary>
    private async Task<bool> EvictLeastRecentlySeenAsync(string subscriptionId, CancellationToken ct)
    {
        // AsNoTracking, deliberately: LastSeenAt is written with ExecuteUpdate,
        // which goes round the change tracker, so a tracked read would hand back
        // the stale value it loaded earlier and evict the wrong phone.
        //
        // Ordered in memory rather than in SQL: the set is capped at
        // MaxDevicesPerKey rows, so there is nothing to gain — and SQLite, which
        // the unit tests run on, cannot ORDER BY a DateTimeOffset at all.
        var devices = await db.TokenDevices.AsNoTracking()
            .Where(d => d.SubscriptionId == subscriptionId).ToListAsync(ct);
        var stalest = devices
            // LastSeenAt is zero on rows written before the column existed and
            // missed by the backfill; they sort first, which is the right answer
            // for a slot of unknown age.
            .OrderBy(d => d.LastSeenAt).ThenBy(d => d.BoundAt)
            .FirstOrDefault();
        if (stalest is null)
        {
            return false;
        }

        var evictedHash = stalest.DeviceKeyHash;
        var evictedId = stalest.Id;
        await db.TokenDevices.Where(d => d.Id == evictedId).ExecuteDeleteAsync(ct);

        var revokedAt = (DateTimeOffset?)DateTimeOffset.UtcNow;
        await db.RefreshTokens
            .Where(r => r.RevokedAt == null && r.DeviceKeyHash == evictedHash)
            .ExecuteUpdateAsync(s => s.SetProperty(r => r.RevokedAt, revokedAt), ct);

        logger.LogInformation(
            "Evicted the least recently seen device from subscription {SubscriptionId}", subscriptionId);
        return true;
    }
}
