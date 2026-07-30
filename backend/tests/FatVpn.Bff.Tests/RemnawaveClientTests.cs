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
    public async Task GetSubscriptionConfig_a_key_the_panel_does_not_have_is_reported_as_gone()
    {
        // The panel answered, and said there is no such subscription. That is an
        // entitlement that ended, not an outage — reporting it as one put
        // "ApiException(502): config_failed" on the home screen of a user whose
        // key had simply run out, with nothing said about their subscription.
        //
        // The browser route is deliberately not asked: it sits behind the
        // operator's login portal and answers 302, which is neither success nor
        // 404, and that is exactly how this became a 502.
        var handler = new StubHandler((_, _) => new HttpResponseMessage(HttpStatusCode.NotFound)
        {
            Content = new StringContent(
                """{"isFound":false,"statusCode":404,"message":"Resource not found"}"""),
        });
        var client = NewClient(handler);

        var error = await Assert.ThrowsAsync<SubscriptionGoneException>(
            () => client.GetSubscriptionConfigAsync("MFsUvfCH02q_bcAF"));

        Assert.Equal("MFsUvfCH02q_bcAF", error.SubscriptionId);
        Assert.Equal("/api/sub/MFsUvfCH02q_bcAF", Assert.Single(handler.Paths));
    }

    [Fact]
    public async Task GetSubscriptionConfig_an_unreachable_panel_is_still_an_upstream_failure()
    {
        // The distinction only works if the other direction holds: a panel that
        // errors must not be read as "your subscription is over".
        var handler = new StubHandler((_, _) => new HttpResponseMessage(HttpStatusCode.BadGateway));
        var client = NewClient(handler);

        var error = await Assert.ThrowsAsync<RemnawaveException>(
            () => client.GetSubscriptionConfigAsync("MFsUvfCH02q_bcAF"));

        Assert.IsNotType<SubscriptionGoneException>(error);
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

    [Fact]
    public async Task GetSubscriptionConfig_sends_a_user_agent()
    {
        // Without one the panel answers 404 "Resource not found" — it renders the
        // subscription per client — and HttpClient sends no User-Agent by itself.
        // That 404 is indistinguishable from "no such subscription", so it fell
        // through to the browser route and its portal: a 502 for every user.
        var handler = new StubHandler((_, _) => Text(Base64Subscription));
        var client = NewClient(handler);

        await client.GetSubscriptionConfigAsync("MFsUvfCH02q_bcAF");

        Assert.Equal("FatVpn.Bff/1.0", Assert.Single(handler.UserAgents));
    }

    [Fact]
    public async Task GetSubscriptionConfig_sends_a_user_agent_on_the_fallback_route_too()
    {
        var handler = new StubHandler((path, _) => path.StartsWith("/api/sub", StringComparison.Ordinal)
            ? new HttpResponseMessage(HttpStatusCode.NotFound)
            : Text(Base64Subscription));
        var client = NewClient(handler);

        await client.GetSubscriptionConfigAsync("MFsUvfCH02q_bcAF");

        Assert.Equal(["FatVpn.Bff/1.0", "FatVpn.Bff/1.0"], handler.UserAgents);
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

        /// One entry per request, null when it carried no User-Agent — which is
        /// the state the panel answers with 404.
        public List<string?> UserAgents { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var path = request.RequestUri!.AbsolutePath;
            Paths.Add(path);
            UserAgents.Add(request.Headers.UserAgent.Count == 0
                ? null
                : request.Headers.UserAgent.ToString());
            return Task.FromResult(respond(path, request));
        }
    }
}
