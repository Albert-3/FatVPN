namespace FatVpn.Bff.Domain;

public class Token
{
    public Guid Id { get; set; }
    public string ShortToken { get; set; } = string.Empty;
    public string RemnawaveSubscriptionId { get; set; } = string.Empty;
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    /// Salted hash of the device that first redeemed this key, back when a key
    /// was one phone's alone. Superseded by <see cref="TokenDevice"/> and no
    /// longer read — kept so rolling back to the previous image finds the column
    /// it expects. Still cleared on reissue for that same reason.
    public string? BoundDeviceKeyHash { get; set; }

    /// The <see cref="Account"/> this key belongs to, when the bot told us whose
    /// it is. Set by <c>/internal/tokens</c>; null for keys registered by a bot
    /// build that predates it, and for trial keys (which have no Telegram user).
    ///
    /// A bound key stops being a session identity of its own: <c>/auth/token</c>
    /// makes it the account's active subscription and issues an account session,
    /// so an extension the bot pushes later reaches the app instead of stopping
    /// at this row — which is what used to leave a renewed subscriber staring at
    /// the "expired" screen.
    public Guid? AccountId { get; set; }
}
