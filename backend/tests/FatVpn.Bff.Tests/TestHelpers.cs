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
    /// <summary>
    /// A fresh, empty database per test — SQLite in memory rather than the EF
    /// InMemory provider. InMemory is not a relational store: it silently ignores
    /// unique indexes and rejects ExecuteUpdate/ExecuteDelete, so it cannot
    /// exercise the atomic claim-and-rotate paths at all. SQLite enforces the
    /// constraints and speaks the same relational surface as Npgsql.
    /// </summary>
    public static FatVpnDbContext NewDb()
    {
        var options = new DbContextOptionsBuilder<FatVpnDbContext>()
            .UseSqlite("DataSource=:memory:")
            .Options;
        var db = new FatVpnDbContext(options);
        // The database lives only as long as the connection; hold it open for the
        // life of the context (EF owns it, so disposing the context closes it).
        db.Database.OpenConnection();
        db.Database.EnsureCreated();
        return db;
    }

    public static JwtOptions Jwt() => new()
    {
        Secret = "test-secret-that-is-long-enough-for-hmacsha256-signing",
        Issuer = "FatVpn.Bff",
        Audience = "FatVpn.App",
        AccessTokenLifetime = TimeSpan.FromMinutes(30),
        RefreshTokenLifetime = TimeSpan.FromDays(90),
    };

    /// <summary>Matches the shipped default (3 devices per key) unless a test
    /// wants a different ceiling.</summary>
    public static AuthOptions Auth(int maxDevicesPerKey = 3) => new() { MaxDevicesPerKey = maxDevicesPerKey };

    public static IOptions<T> Opt<T>(T value) where T : class => Options.Create(value);

    public static JwtTokenService JwtService() => new(Opt(Jwt()));

    public static RefreshTokenService RefreshService() => new(Opt(Jwt()));

    /// <summary>The device cap, wired to the same DbContext the controller under
    /// test uses — slots are shared state, so a second context would not see the
    /// rows a test just wrote.</summary>
    public static Api.Auth.DeviceSlots Slots(FatVpnDbContext db, int maxDevicesPerKey = 3)
        => new(db, Opt(Auth(maxDevicesPerKey)),
               Microsoft.Extensions.Logging.Abstractions.NullLogger<Api.Auth.DeviceSlots>.Instance);

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

    /// <summary>Panel users this fake was asked to delete — how a test asserts a
    /// failed trial compensated instead of orphaning a user in the panel.</summary>
    public List<string> DeletedUsers { get; } = [];

    public Task DeleteUserAsync(string uuid, CancellationToken ct = default)
    {
        DeletedUsers.Add(uuid);
        return Task.CompletedTask;
    }

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
