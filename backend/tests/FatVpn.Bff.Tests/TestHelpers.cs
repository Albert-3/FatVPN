using System.Security.Claims;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using FatVpn.Bff.Infrastructure.Remnawave;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Tests;

/// <summary>Shared fixtures for controller/service tests.</summary>
internal static class TestHelpers
{
    /// <summary>A fresh in-memory DbContext with a unique store per test.</summary>
    public static FatVpnDbContext NewDb()
    {
        var options = new DbContextOptionsBuilder<FatVpnDbContext>()
            .UseInMemoryDatabase(databaseName: Guid.NewGuid().ToString())
            .Options;
        return new FatVpnDbContext(options);
    }

    public static JwtOptions Jwt() => new()
    {
        Secret = "test-secret-that-is-long-enough-for-hmacsha256-signing",
        Issuer = "FatVpn.Bff",
        Audience = "FatVpn.App",
        AccessTokenLifetime = TimeSpan.FromMinutes(30),
        RefreshTokenLifetime = TimeSpan.FromDays(90),
    };

    public static IOptions<T> Opt<T>(T value) where T : class => Options.Create(value);

    public static JwtTokenService JwtService() => new(Opt(Jwt()));

    public static RefreshTokenService RefreshService() => new(Opt(Jwt()));

    /// <summary>Attaches an HttpContext carrying the given claims to a controller,
    /// so <c>User</c>/<c>Request.Headers</c> resolve inside the action.</summary>
    public static void WithUser(this ControllerBase controller, params Claim[] claims)
    {
        var identity = new ClaimsIdentity(claims, "TestAuth");
        controller.ControllerContext = new ControllerContext
        {
            HttpContext = new DefaultHttpContext { User = new ClaimsPrincipal(identity) },
        };
    }

    public static void WithHeader(this ControllerBase controller, string name, string value)
    {
        controller.ControllerContext ??= new ControllerContext { HttpContext = new DefaultHttpContext() };
        controller.ControllerContext.HttpContext ??= new DefaultHttpContext();
        controller.ControllerContext.HttpContext.Request.Headers[name] = value;
    }
}

/// <summary>Configurable fake so controller tests don't hit a real panel.</summary>
internal sealed class FakeRemnawaveClient : IRemnawaveClient
{
    public Func<DateTimeOffset, RemnawaveTrialUser>? OnCreateTrial { get; set; }
    public Func<(string, string)>? OnGetConfig { get; set; }
    public Func<IReadOnlyList<ServerCountry>>? OnGetNodes { get; set; }

    public Task<RemnawaveTrialUser> CreateTrialUserAsync(DateTimeOffset expiresAt, CancellationToken ct = default)
    {
        if (OnCreateTrial is null) throw new InvalidOperationException("OnCreateTrial not set");
        return Task.FromResult(OnCreateTrial(expiresAt));
    }

    public Task<(string Content, string ContentType)> GetSubscriptionConfigAsync(string subscriptionId, CancellationToken ct = default)
    {
        if (OnGetConfig is null) throw new InvalidOperationException("OnGetConfig not set");
        return Task.FromResult(OnGetConfig());
    }

    public Task<IReadOnlyList<ServerCountry>> GetNodesAsync(CancellationToken ct = default)
    {
        if (OnGetNodes is null) throw new InvalidOperationException("OnGetNodes not set");
        return Task.FromResult(OnGetNodes());
    }
}
