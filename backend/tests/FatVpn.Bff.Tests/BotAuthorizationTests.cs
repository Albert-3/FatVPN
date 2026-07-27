using System.Security.Claims;
using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Infrastructure.Bot;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FatVpn.Bff.Tests;

/// <summary>
/// The bot secret guards every /internal/* endpoint. It used to be a copy-pasted
/// first line in each action; these cover the policy that replaced it.
/// </summary>
public class BotSecretAuthorizationHandlerTests
{
    private const string Secret = "bot-secret-value";

    private static async Task<bool> EvaluateAsync(string? providedHeader, string configuredSecret = Secret)
    {
        var httpContext = new DefaultHttpContext();
        if (providedHeader is not null)
        {
            httpContext.Request.Headers[BotSecretValidator.HeaderName] = providedHeader;
        }

        var accessor = new HttpContextAccessor { HttpContext = httpContext };
        var handler = new BotSecretAuthorizationHandler(
            accessor,
            TestHelpers.Opt(new BotOptions { Secret = configuredSecret }),
            NullLogger<BotSecretAuthorizationHandler>.Instance);

        var requirement = new BotSecretRequirement();
        var context = new AuthorizationHandlerContext(
            [requirement], new ClaimsPrincipal(new ClaimsIdentity()), resource: null);

        await handler.HandleAsync(context);
        return context.HasSucceeded;
    }

    [Fact]
    public async Task CorrectSecret_Succeeds() => Assert.True(await EvaluateAsync(Secret));

    [Fact]
    public async Task WrongSecret_Fails() => Assert.False(await EvaluateAsync("nope"));

    [Fact]
    public async Task MissingHeader_Fails() => Assert.False(await EvaluateAsync(null));

    [Fact]
    public async Task EmptyHeader_Fails() => Assert.False(await EvaluateAsync(""));

    [Fact]
    public async Task UnconfiguredSecret_RejectsEvenAMatchingEmptyHeader()
        => Assert.False(await EvaluateAsync("", configuredSecret: ""));

    [Fact]
    public async Task PrefixOfTheSecret_Fails() => Assert.False(await EvaluateAsync(Secret[..5]));
}
