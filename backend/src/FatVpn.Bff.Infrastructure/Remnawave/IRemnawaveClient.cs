namespace FatVpn.Bff.Infrastructure.Remnawave;

public interface IRemnawaveClient
{
    Task<IReadOnlyList<ServerCountry>> GetNodesAsync(CancellationToken ct = default);

    Task<(string Content, string ContentType)> GetSubscriptionConfigAsync(string subscriptionId, CancellationToken ct = default);

    /// Creates a fresh Remnawave user for a trial, expiring at [expiresAt], and
    /// returns its subscription short-uuid. Used to provision trials on demand
    /// instead of drawing from a pre-filled pool.
    Task<RemnawaveTrialUser> CreateTrialUserAsync(DateTimeOffset expiresAt, CancellationToken ct = default);

    /// Deletes a panel user. Only used to compensate a trial that was provisioned
    /// in the panel and then failed to persist here — without it the orphan stays
    /// in the panel forever, unreferenced and unfindable.
    Task DeleteUserAsync(string uuid, CancellationToken ct = default);
}

/// <param name="Uuid">The panel's internal id, needed to delete the user again;
/// distinct from the subscription short-uuid the app consumes.</param>
public sealed record RemnawaveTrialUser(string ShortUuid, DateTimeOffset ExpiresAt, string Uuid = "");

public sealed record ServerCountry(string Country, string Flag, int NodeCount, IReadOnlyList<ServerNode> Nodes);

public sealed record ServerNode(string Id, string Name, string Address, int Port, int UsersOnline);
