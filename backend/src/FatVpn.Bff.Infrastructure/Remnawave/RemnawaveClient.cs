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
