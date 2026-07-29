using System.Net;
using System.Text;
using FatVpn.Bff.Infrastructure.Remnawave;
using Xunit;

namespace FatVpn.Bff.Tests;

/// <summary>
/// The panel-facing HTTP details of fetching a subscription. These exist because
/// of 2026-07-29: an auth portal appeared in front of the panel's browser route
/// <c>/sub/{id}</c>, the redirect was followed to a login page, and a 200 of HTML
/// travelled all the way to the app as "this subscription has no servers".
/// </summary>
public class RemnawaveClientTests
{
    private const string Base64Subscription = "dmxlc3M6Ly9leGFtcGxlCg==";

    private static RemnawaveClient NewClient(StubHandler handler) =>
        new(new HttpClient(handler) { BaseAddress = new Uri("https://panel.example") },
            TestHelpers.Opt(new RemnawaveOptions { BaseUrl = "https://panel.example", ApiToken = "t" }));

    [Fact]
    public async Task GetSubscriptionConfig_asks_the_api_route_not_the_browser_route()
    {
        var handler = new StubHandler((_, _) => Text(Base64Subscription));
        var client = NewClient(handler);

        var (content, _) = await client.GetSubscriptionConfigAsync("MFsUvfCH02q_bcAF");

        Assert.Equal(Base64Subscription, content);
        Assert.Equal("/api/sub/MFsUvfCH02q_bcAF", Assert.Single(handler.Paths));
    }

    [Fact]
    public async Task GetSubscriptionConfig_falls_back_to_the_browser_route_on_404()
    {
        var handler = new StubHandler((path, _) => path.StartsWith("/api/sub", StringComparison.Ordinal)
            ? new HttpResponseMessage(HttpStatusCode.NotFound)
            : Text(Base64Subscription));
        var client = NewClient(handler);

        var (content, _) = await client.GetSubscriptionConfigAsync("MFsUvfCH02q_bcAF");

        Assert.Equal(Base64Subscription, content);
        Assert.Equal(["/api/sub/MFsUvfCH02q_bcAF", "/sub/MFsUvfCH02q_bcAF"], handler.Paths);
    }

    [Theory]
    // A login portal: HTML, and honest about being HTML.
    [InlineData("text/html", "<!DOCTYPE html><html><body>Sign In</body></html>")]
    // The same page from a front that mislabels it — the body still gives it away.
    [InlineData("text/plain", "<html><body>Attention Required! | Cloudflare</body></html>")]
    public async Task GetSubscriptionConfig_refuses_an_html_page(string contentType, string body)
    {
        var client = NewClient(new StubHandler((_, _) => Text(body, contentType)));

        var ex = await Assert.ThrowsAsync<RemnawaveException>(
            () => client.GetSubscriptionConfigAsync("MFsUvfCH02q_bcAF"));
        Assert.Contains("HTML page", ex.Message);
    }

    [Fact]
    public async Task GetSubscriptionConfig_rejects_a_redirect()
    {
        // With AllowAutoRedirect off in Program.cs, a portal's 302 reaches us as
        // the response itself. It is not success, so it must not be handed on.
        var redirect = new HttpResponseMessage(HttpStatusCode.Found);
        redirect.Headers.Location = new Uri("https://panel.example/r?redirect_url=x");
        var client = NewClient(new StubHandler((_, _) => redirect));

        await Assert.ThrowsAsync<RemnawaveException>(
            () => client.GetSubscriptionConfigAsync("MFsUvfCH02q_bcAF"));
    }

    [Fact]
    public async Task GetSubscriptionConfig_rejects_a_malformed_id_without_calling_the_panel()
    {
        var handler = new StubHandler((_, _) => Text(Base64Subscription));
        var client = NewClient(handler);

        await Assert.ThrowsAsync<RemnawaveException>(
            () => client.GetSubscriptionConfigAsync("../api/users"));
        Assert.Empty(handler.Paths);
    }

    private static HttpResponseMessage Text(string body, string contentType = "text/plain") =>
        new(HttpStatusCode.OK)
        {
            Content = new StringContent(body, Encoding.UTF8, contentType),
        };

    private sealed class StubHandler(Func<string, HttpRequestMessage, HttpResponseMessage> respond)
        : HttpMessageHandler
    {
        public List<string> Paths { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var path = request.RequestUri!.AbsolutePath;
            Paths.Add(path);
            return Task.FromResult(respond(path, request));
        }
    }
}
