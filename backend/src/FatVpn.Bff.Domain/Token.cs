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
}
