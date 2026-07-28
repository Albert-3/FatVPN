namespace FatVpn.Bff.Domain;

public class Token
{
    public Guid Id { get; set; }
    public string ShortToken { get; set; } = string.Empty;
    public string RemnawaveSubscriptionId { get; set; } = string.Empty;
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    /// Salted hash of the device that first redeemed this key. Null until first
    /// use; a different device presenting the same key is refused (one key = one
    /// phone). Reset by <c>/internal/tokens</c> reissue so a new phone can claim it.
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
