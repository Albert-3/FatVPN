using System.Globalization;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Infrastructure.Remnawave;

public sealed class RemnawaveClient(HttpClient httpClient, IOptions<RemnawaveOptions> options) : IRemnawaveClient
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    /// <summary>
    /// Ceiling on how much of a panel answer is read into memory, applied to the
    /// injected <see cref="HttpClient"/> where the rest of its policy lives
    /// (<c>Program.cs</c>, next to the timeout).
    /// <para>
    /// Every call here buffers the whole body (<c>ReadAsStringAsync</c> /
    /// <c>ReadFromJsonAsync</c>), and HttpClient's own default ceiling is 2 GB —
    /// so a panel that is hostile, wedged, or fronted by something that answers
    /// with a stream (a login portal in front of <c>/sub</c> was exactly that
    /// kind of surprise) could take the container out of memory with one
    /// request. 4 MB is two orders of magnitude above the largest real body: a
    /// base64 subscription is single-digit KB per link.
    /// </para>
    /// Going over it surfaces as <see cref="HttpRequestException"/>, which
    /// <c>CallAsync</c> already translates into <see cref="RemnawaveException"/>
    /// — i.e. a 502, not a 500.
    /// </summary>
    public const long MaxResponseBytes = 4L * 1024 * 1024;

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

        var id = Uri.EscapeDataString(subscriptionId);
        return await CallAsync(async () =>
        {
            // `/api/sub/{id}`, not `/sub/{id}`: the browser-facing route is the
            // one an operator puts behind an auth portal, and on 2026-07-29 that
            // is exactly what happened — Caddy started answering `/sub/*` with a
            // 302 to a caddy-security login page, which followed to a 200 page of
            // HTML. Every app then saw a subscription with no links in it and
            // said "no servers on this subscription". The `/api` route serves the
            // same body and is the one the panel's own API surface lives on.
            var response = await GetSubscriptionAsync($"/api/sub/{id}", ct);
            if (response.StatusCode is System.Net.HttpStatusCode.NotFound
                or System.Net.HttpStatusCode.MethodNotAllowed)
            {
                var body = await response.Content.ReadAsStringAsync(ct);
                response.Dispose();

                // Two different 404s arrive here and they mean opposite things.
                // "No such subscription" is the panel answering about the key —
                // deleted, or reissued under a new id while our copy of the
                // expiry still called it live. Falling through to the browser
                // route on that one is how a spent key reached the user as
                // "ApiException(502): config_failed", with nothing said about
                // their subscription: /sub/{id} sits behind the operator's login
                // portal and answers 302, which is neither success nor 404.
                if (SaysNoSuchSubscription(body))
                {
                    throw new SubscriptionGoneException(subscriptionId);
                }

                // The other 404 is "no such route" — an older panel that predates
                // /api/sub. Fall back rather than strand every user on a 502.
                response = await GetSubscriptionAsync($"/sub/{id}", ct);
                if (response.StatusCode is System.Net.HttpStatusCode.NotFound)
                {
                    response.Dispose();
                    throw new SubscriptionGoneException(subscriptionId);
                }
            }

            using (response)
            {
                response.EnsureSuccessStatusCode();

                var content = await response.Content.ReadAsStringAsync(ct);
                var contentType = response.Content.Headers.ContentType?.ToString() ?? "text/plain";
                EnsureNotAWebPage(content, contentType);
                return (content, contentType);
            }
        }, "Fetching subscription config", ct);
    }

    /// <summary>
    /// Whether a 404 body is the panel saying it has no such subscription, as
    /// opposed to no such route.
    /// <para>
    /// A missing subscription answers <c>{"isFound":false,"statusCode":404,
    /// "message":"Resource not found"}</c>; a missing route answers
    /// <c>{"message":"Cannot GET /api/…","error":"Not Found",…}</c>. The
    /// <c>isFound</c> field is the panel talking about a subscription at all,
    /// which is the whole distinction — and matching on it rather than on the
    /// message text keeps this working if the wording is ever localized.
    /// </para>
    /// </summary>
    private static bool SaysNoSuchSubscription(string body) =>
        body.Contains("\"isFound\"", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// User-Agent sent with a subscription request. Remnawave picks the rendering
    /// template by client, and answers a request that carries no User-Agent at all
    /// with 404 <c>{"isFound":false,"message":"Resource not found"}</c> — which
    /// HttpClient does by default, since it sends no User-Agent of its own. That
    /// is how <c>/api/sub</c> 404'd for the BFF while the same URL served 17 links
    /// to curl a minute earlier; the 404 then fell through to <c>/sub</c> and its
    /// login portal, and every app got a 502.
    /// <para>
    /// Deliberately a name the panel does not recognize: a known client's
    /// User-Agent (Happ, v2rayNG, …) switches the body to that client's own
    /// format, and what the app parses is the default base64 list of links.
    /// </para>
    /// </summary>
    private const string SubscriptionUserAgent = "FatVpn.Bff/1.0";

    /// <summary>
    /// GETs a subscription route with the header the panel requires — see
    /// <see cref="SubscriptionUserAgent"/>. Caller owns the response.
    /// </summary>
    private async Task<HttpResponseMessage> GetSubscriptionAsync(string path, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, path);
        request.Headers.UserAgent.ParseAdd(SubscriptionUserAgent);
        return await httpClient.SendAsync(request, ct);
    }

    /// <summary>
    /// Rejects a "subscription" that is really an HTML page — a login portal, a
    /// CDN interstitial, a panel error page. Such a body is a perfectly valid 200
    /// as far as HTTP is concerned, and passing it through cost us a day of
    /// "the app shows no servers": downstream it parses to zero links, which is
    /// indistinguishable from a subscription that genuinely has none. Failing
    /// here turns it into a 502 the user reads as "the server is unreachable".
    /// </summary>
    private static void EnsureNotAWebPage(string content, string contentType)
    {
        var looksLikeHtml = contentType.Contains("text/html", StringComparison.OrdinalIgnoreCase)
            || content.AsSpan().TrimStart().StartsWith("<", StringComparison.Ordinal);
        if (looksLikeHtml)
        {
            throw new RemnawaveException(
                "The panel answered the subscription request with an HTML page "
                + $"(content-type '{contentType}') instead of a subscription — "
                + "is /api/sub behind an auth portal?");
        }
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
