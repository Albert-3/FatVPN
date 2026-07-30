namespace FatVpn.Bff.Infrastructure.Remnawave;

/// <summary>
/// The panel answered, and said it has no such subscription.
///
/// Kept apart from a plain <see cref="RemnawaveException"/> because the two mean
/// opposite things to a user. A panel that cannot be reached is a fault to wait
/// out; a subscription the panel does not know is an entitlement that is gone —
/// deleted, or reissued under a new id while our copy of the expiry still said
/// it was live. Reported as 402, so the app offers to renew instead of showing
/// "the server is unreachable" about a server that answered perfectly well.
/// </summary>
public sealed class SubscriptionGoneException(string subscriptionId)
    : RemnawaveException($"The panel has no subscription '{subscriptionId}'")
{
    public string SubscriptionId { get; } = subscriptionId;
}
