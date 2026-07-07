using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Infrastructure.Remnawave;

public sealed class RemnawaveClient(HttpClient httpClient, IOptions<RemnawaveOptions> options) : IRemnawaveClient
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);


    public async Task<IReadOnlyList<ServerCountry>> GetNodesAsync(CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "/api/nodes");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", options.Value.ApiToken);

        using var response = await httpClient.SendAsync(request, ct);
        response.EnsureSuccessStatusCode();

        var body = await response.Content.ReadFromJsonAsync<RemnawaveNodesResponse>(JsonOptions, ct);
        var nodes = body?.Response ?? [];

        return nodes
            .Where(n => n.IsConnected && !n.IsDisabled)
            .GroupBy(n => n.CountryCode)
            .Select(g => new ServerCountry(
                Country: g.Key,
                Flag: g.Key,
                NodeCount: g.Count(),
                Nodes: g.Select(n => new ServerNode(
                        Id: n.Uuid,
                        Name: n.Name,
                        Address: n.Address,
                        Port: n.Port,
                        UsersOnline: n.UsersOnline))
                    .ToList()))
            .ToList();
    }

    public async Task<(string Content, string ContentType)> GetSubscriptionConfigAsync(string subscriptionId, CancellationToken ct = default)
    {
        using var response = await httpClient.GetAsync($"/sub/{subscriptionId}", ct);
        response.EnsureSuccessStatusCode();

        var content = await response.Content.ReadAsStringAsync(ct);
        var contentType = response.Content.Headers.ContentType?.ToString() ?? "text/plain";
        return (content, contentType);
    }

    public async Task<RemnawaveTrialUser> CreateTrialUserAsync(DateTimeOffset expiresAt, CancellationToken ct = default)
    {
        // trial_ + 16 hex chars — unique, well within Remnawave's username length/charset limits.
        var username = $"trial_{Guid.NewGuid():N}"[..22];
        var payload = new
        {
            username,
            status = "ACTIVE",
            expireAt = expiresAt.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"),
            trafficLimitBytes = 0,
            trafficLimitStrategy = "NO_RESET",
            activeInternalSquads = new[] { options.Value.TrialSquadUuid },
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/users")
        {
            Content = JsonContent.Create(payload, options: JsonOptions),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", options.Value.ApiToken);

        using var response = await httpClient.SendAsync(request, ct);
        response.EnsureSuccessStatusCode();

        var body = await response.Content.ReadFromJsonAsync<RemnawaveUserResponse>(JsonOptions, ct);
        var user = body?.Response ?? throw new InvalidOperationException("Empty Remnawave create-user response");
        return new RemnawaveTrialUser(user.ShortUuid, user.ExpireAt);
    }
}

internal sealed class RemnawaveUserResponse
{
    public RemnawaveUserDto Response { get; set; } = new();
}

internal sealed class RemnawaveUserDto
{
    public string ShortUuid { get; set; } = string.Empty;
    public DateTimeOffset ExpireAt { get; set; }
}

internal sealed class RemnawaveNodesResponse
{
    public List<RemnawaveNodeDto> Response { get; set; } = [];
}

internal sealed class RemnawaveNodeDto
{
    public string Uuid { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string CountryCode { get; set; } = string.Empty;
    public string Address { get; set; } = string.Empty;
    public int Port { get; set; }
    public bool IsConnected { get; set; }
    public bool IsDisabled { get; set; }
    public int UsersOnline { get; set; }
}
