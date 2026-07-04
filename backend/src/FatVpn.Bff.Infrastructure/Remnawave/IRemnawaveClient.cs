namespace FatVpn.Bff.Infrastructure.Remnawave;

public interface IRemnawaveClient
{
    Task<IReadOnlyList<ServerCountry>> GetNodesAsync(CancellationToken ct = default);

    Task<(string Content, string ContentType)> GetSubscriptionConfigAsync(string subscriptionId, CancellationToken ct = default);
}

public sealed record ServerCountry(string Country, string Flag, int NodeCount, IReadOnlyList<ServerNode> Nodes);

public sealed record ServerNode(string Id, string Name, string Address, int Port, int UsersOnline);
