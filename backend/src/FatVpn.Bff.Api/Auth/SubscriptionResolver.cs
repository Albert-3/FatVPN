using System.Security.Claims;
using FatVpn.Bff.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Api.Auth;

/// <summary>Current subscription for an authenticated caller.</summary>
public sealed record SubscriptionInfo(DateTimeOffset ExpiresAt, string? SubscriptionId)
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
            var account = await db.Accounts.FindAsync([accountId.Value], ct);
            return account is null
                ? null
                : new SubscriptionInfo(account.ExpiresAt, account.CurrentSubscriptionId);
        }

        var token = await db.Tokens.FindAsync([user.GetTokenId()], ct);
        return token is null
            ? null
            : new SubscriptionInfo(token.ExpiresAt, token.RemnawaveSubscriptionId);
    }
}
