using System.Text.Json;

namespace FatVpn.Bff.Infrastructure.Remnawave;

public interface IRemnawaveClient
{
    Task<IReadOnlyList<ServerCountry>> GetNodesAsync(CancellationToken ct = default);

    Task<JsonDocument> GetSubscriptionConfigAsync(string subscriptionId, CancellationToken ct = default);
}

public sealed record ServerCountry(string Country, string Flag, int NodeCount, string PingHost);
