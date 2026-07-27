using System.Security.Claims;
using FatVpn.Bff.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Api.Auth;

/// <summary>Current subscription for an authenticated caller.</summary>
public sealed record SubscriptionInfo(DateTimeOffset ExpiresAt, string? SubscriptionId, string? KeyCode = null)
{
    public bool IsActive => ExpiresAt > DateTimeOffset.UtcNow;
}

public static class SubscriptionResolver
{
    /// <summary>
    /// Resolves the caller's current subscription. Account-based sessions
    /// (pairing) resolve through the account so key changes/extensions are
    /// picked up live; legacy deep-link tokens fall back to the token row.
    /// Returns null when the session is unknown (no matching row).
    /// </summary>
    public static async Task<SubscriptionInfo?> ResolveSubscriptionAsync(
        this FatVpnDbContext db, ClaimsPrincipal user, CancellationToken ct)
    {
        var accountId = user.TryGetAccountId();
        if (accountId is not null)
        {
            // AsNoTracking on both branches: this runs on /me, /servers and
            // /config — the three hottest endpoints — and none of them writes.
            var account = await db.Accounts.AsNoTracking()
                .FirstOrDefaultAsync(a => a.Id == accountId.Value, ct);
            return account is null
                ? null
                : new SubscriptionInfo(
                    account.ExpiresAt,
                    NullIfEmpty(account.CurrentSubscriptionId),
                    NullIfEmpty(account.CurrentKeyCode ?? string.Empty));
        }

        var tokenId = user.TryGetTokenId();
        if (tokenId is null)
        {
            // Signed by us, but carrying neither claim — treat as an unknown
            // session (401) rather than blowing up with a 500.
            return null;
        }

        var token = await db.Tokens.AsNoTracking().FirstOrDefaultAsync(t => t.Id == tokenId.Value, ct);
        return token is null
            ? null
            : new SubscriptionInfo(token.ExpiresAt, NullIfEmpty(token.RemnawaveSubscriptionId));
    }

    // Subscription ids default to "" on a freshly-created row; treat that as "no
    // subscription yet" so /config returns 401 instead of proxying an empty id.
    private static string? NullIfEmpty(string value) =>
        string.IsNullOrEmpty(value) ? null : value;
}
