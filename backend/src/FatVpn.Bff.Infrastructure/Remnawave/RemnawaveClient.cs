using System.Globalization;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Infrastructure.Remnawave;

public sealed class RemnawaveClient(HttpClient httpClient, IOptions<RemnawaveOptions> options) : IRemnawaveClient
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    /// <summary>Remnawave short uuids are url-safe base62-ish; anything else is
    /// either a bug or an attempt to steer the request at another panel path.</summary>
    private static bool IsWellFormedSubscriptionId(string value) =>
        value.Length is >= 4 and <= 64 && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');

    public async Task<IReadOnlyList<ServerCountry>> GetNodesAsync(CancellationToken ct = default)
    {
        return await CallAsync(async () =>
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, "/api/nodes");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", options.Value.ApiToken);

            using var response = await httpClient.SendAsync(request, ct);
            response.EnsureSuccessStatusCode();

            var body = await response.Content.ReadFromJsonAsync<RemnawaveNodesResponse>(JsonOptions, ct);
            var nodes = body?.Response ?? [];

            return (IReadOnlyList<ServerCountry>)nodes
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
        }, "Listing panel nodes", ct);
    }

    public async Task<(string Content, string ContentType)> GetSubscriptionConfigAsync(string subscriptionId, CancellationToken ct = default)
    {
        // The id reaches us from the bot; without this an id of "../api/users"
        // would silently retarget the request at another panel endpoint.
        if (!IsWellFormedSubscriptionId(subscriptionId))
        {
            throw new RemnawaveException($"Malformed subscription id '{subscriptionId}'");
        }

        return await CallAsync(async () =>
        {
            using var response = await httpClient.GetAsync($"/sub/{Uri.EscapeDataString(subscriptionId)}", ct);
            response.EnsureSuccessStatusCode();

            var content = await response.Content.ReadAsStringAsync(ct);
            var contentType = response.Content.Headers.ContentType?.ToString() ?? "text/plain";
            return (content, contentType);
        }, "Fetching subscription config", ct);
    }

    public async Task<RemnawaveTrialUser> CreateTrialUserAsync(DateTimeOffset expiresAt, CancellationToken ct = default)
    {
        // trial_ + 16 hex chars — unique, well within Remnawave's username length/charset limits.
        var username = $"trial_{Guid.NewGuid():N}"[..22];
        var payload = new
        {
            username,
            status = "ACTIVE",
            // Invariant culture: ':' is a culture-sensitive time separator, and a
            // container with a non-invariant locale would render "00.00.00".
            expireAt = expiresAt.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture),
            trafficLimitBytes = 0,
            trafficLimitStrategy = "NO_RESET",
            activeInternalSquads = new[] { options.Value.TrialSquadUuid },
        };

        return await CallAsync(async () =>
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, "/api/users")
            {
                Content = JsonContent.Create(payload, options: JsonOptions),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", options.Value.ApiToken);

            using var response = await httpClient.SendAsync(request, ct);
            response.EnsureSuccessStatusCode();

            var body = await response.Content.ReadFromJsonAsync<RemnawaveUserResponse>(JsonOptions, ct);
            var user = body?.Response ?? throw new RemnawaveException("Empty Remnawave create-user response");
            return new RemnawaveTrialUser(user.ShortUuid, user.ExpireAt.ToUniversalTime(), user.Uuid);
        }, "Creating trial user", ct);
    }

    public async Task DeleteUserAsync(string uuid, CancellationToken ct = default)
    {
        await CallAsync(async () =>
        {
            using var request = new HttpRequestMessage(HttpMethod.Delete, $"/api/users/{Uri.EscapeDataString(uuid)}");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", options.Value.ApiToken);

            using var response = await httpClient.SendAsync(request, ct);
            response.EnsureSuccessStatusCode();
            return true;
        }, "Deleting user", ct);
    }

    /// <summary>
    /// Runs a panel call and translates every way it can fail into
    /// <see cref="RemnawaveException"/>, so controllers answer 502 rather than
    /// leaking an unhandled exception as 500. A cancellation that came from the
    /// caller (client hung up) is deliberately re-thrown untouched — it is not
    /// an upstream failure.
    /// </summary>
    private static async Task<T> CallAsync<T>(Func<Task<T>> call, string what, CancellationToken ct)
    {
        try
        {
            return await call();
        }
        catch (RemnawaveException)
        {
            throw;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new RemnawaveException($"{what}: the panel did not answer in time");
        }
        catch (HttpRequestException ex)
        {
            throw new RemnawaveException($"{what}: {ex.Message}", ex);
        }
        catch (JsonException ex)
        {
            throw new RemnawaveException($"{what}: the panel returned a non-JSON body", ex);
        }
        catch (NotSupportedException ex)
        {
            throw new RemnawaveException($"{what}: unexpected content type from the panel", ex);
        }
    }
}

internal sealed class RemnawaveUserResponse
{
    public RemnawaveUserDto Response { get; set; } = new();
}

internal sealed class RemnawaveUserDto
{
    public string Uuid { get; set; } = string.Empty;
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
