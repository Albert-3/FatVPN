using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Api.Controllers;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure.Remnawave;
using FatVpn.Bff.Infrastructure.TrialPool;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FatVpn.Bff.Tests;

public class TrialControllerTests
{
    private static TrialController NewController(
        Infrastructure.FatVpnDbContext db, IRemnawaveClient remna, TrialOptions? opts = null)
        => new(db, TestHelpers.JwtService(), TestHelpers.RefreshService(), remna,
               TestHelpers.Opt(opts ?? new TrialOptions { DurationDays = 2, DeviceKeySalt = "salt" }),
               NullLogger<TrialController>.Instance);

    private static FakeRemnawaveClient OkRemna() => new()
    {
        OnCreateTrial = expiry => new RemnawaveTrialUser("short-uuid", expiry),
    };

    /// Real clients send a 64-char hex per-install key. The controller now
    /// enforces a minimum length (an empty token used to hash to one shared
    /// device identity), so fixtures have to look like the real thing.
    private static string DeviceKey(string seed) => seed.PadRight(32, '0');

    [Fact]
    public async Task GrantTrial_NewDevice_CreatesTrialTokenAndDevice()
    {
        using var db = TestHelpers.NewDb();
        var result = await NewController(db, OkRemna())
            .GrantTrial(new TrialRequest(DeviceKey("attest-abc"), "android"), default);

        Assert.IsType<OkObjectResult>(result);
        Assert.Equal(1, await db.Devices.CountAsync());
        Assert.Equal(1, await db.Trials.CountAsync());
        Assert.Equal(1, await db.Tokens.CountAsync());
        Assert.Equal(1, await db.RefreshTokens.CountAsync());
        Assert.StartsWith("TRIAL-", (await db.Tokens.SingleAsync()).ShortToken);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("too-short")]
    public async Task GrantTrial_MalformedAttestation_BadRequest_NoPanelCall(string attestation)
    {
        // An empty token hashes to SHA256(salt) — the same device identity for
        // everyone — so the first caller's trial would be resumed for every later
        // caller. The panel must not even be contacted.
        using var db = TestHelpers.NewDb();
        var remna = new FakeRemnawaveClient
        {
            OnCreateTrial = _ => throw new InvalidOperationException("panel must not be called"),
        };

        var result = await NewController(db, remna)
            .GrantTrial(new TrialRequest(attestation, "android"), default);

        Assert.IsType<BadRequestObjectResult>(result);
        Assert.Equal(0, await db.Devices.CountAsync());
        Assert.Equal(0, await db.Trials.CountAsync());
    }

    [Fact]
    public async Task GrantTrial_SameDeviceTwice_StillRunning_ResumesSession()
    {
        // e.g. the device signed out and lost its refresh token while its trial
        // was still running — a repeat request should hand back a fresh session
        // for the same trial instead of a bare 409 that strands the client.
        using var db = TestHelpers.NewDb();
        var remna = OkRemna();
        await NewController(db, remna).GrantTrial(new TrialRequest(DeviceKey("dup-device"), "android"), default);

        var second = await NewController(db, remna).GrantTrial(new TrialRequest(DeviceKey("dup-device"), "android"), default);

        Assert.IsType<OkObjectResult>(second);
        Assert.Equal(1, await db.Trials.CountAsync()); // no second trial granted
        Assert.Equal(1, await db.Tokens.CountAsync()); // same underlying token reused
        Assert.Equal(2, await db.RefreshTokens.CountAsync()); // a fresh refresh token was issued
    }

    [Fact]
    public async Task GrantTrial_SameDeviceTwice_TrialExpired_Conflict()
    {
        using var db = TestHelpers.NewDb();
        // Panel-reported expiry already in the past, regardless of what was requested.
        var remna = new FakeRemnawaveClient
        {
            OnCreateTrial = _ => new RemnawaveTrialUser("short-uuid", DateTimeOffset.UtcNow.AddMinutes(-5)),
        };
        await NewController(db, remna).GrantTrial(new TrialRequest(DeviceKey("dup-device-expired"), "android"), default);

        var second = await NewController(db, remna).GrantTrial(new TrialRequest(DeviceKey("dup-device-expired"), "android"), default);

        Assert.IsType<ConflictResult>(second);
        Assert.Equal(1, await db.Trials.CountAsync()); // no second trial granted
    }

    [Fact]
    public async Task GrantTrial_SameSalt_SameAttestation_HashesEqual()
    {
        // Different attestation tokens must not collide; same one must.
        using var db1 = TestHelpers.NewDb();
        await NewController(db1, OkRemna()).GrantTrial(new TrialRequest(DeviceKey("device-A"), "android"), default);
        await NewController(db1, OkRemna()).GrantTrial(new TrialRequest(DeviceKey("device-B"), "android"), default);
        Assert.Equal(2, await db1.Devices.CountAsync()); // distinct devices
    }

    [Fact]
    public async Task GrantTrial_RemnawaveFails_ReturnsBadGateway_NoRowsWritten()
    {
        using var db = TestHelpers.NewDb();
        var remna = new FakeRemnawaveClient
        {
            OnCreateTrial = _ => throw new HttpRequestException("panel down"),
        };

        var result = await NewController(db, remna).GrantTrial(new TrialRequest(DeviceKey("dev"), "android"), default);

        var status = Assert.IsType<ObjectResult>(result);
        Assert.Equal(StatusCodes.Status502BadGateway, status.StatusCode);
        Assert.Equal(0, await db.Devices.CountAsync()); // nothing persisted on failure
        Assert.Equal(0, await db.Trials.CountAsync());
    }

    [Fact]
    public async Task GrantTrial_UsesRemnawaveExpiry_NotRequested()
    {
        using var db = TestHelpers.NewDb();
        var panelExpiry = DateTimeOffset.UtcNow.AddDays(7); // panel disagrees with requested
        var remna = new FakeRemnawaveClient { OnCreateTrial = _ => new RemnawaveTrialUser("uuid", panelExpiry) };

        await NewController(db, remna).GrantTrial(new TrialRequest(DeviceKey("dev"), "android"), default);

        Assert.Equal(panelExpiry, (await db.Tokens.SingleAsync()).ExpiresAt);
        Assert.Equal(panelExpiry, (await db.Trials.SingleAsync()).ExpiresAt);
    }
}

public class SubscriptionResolverTests
{
    [Fact]
    public async Task Resolve_AccountSession_UsesAccountSubscription()
    {
        using var db = TestHelpers.NewDb();
        var account = new Account
        {
            Id = Guid.NewGuid(), CurrentSubscriptionId = "acc-sub",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(5),
        };
        db.Accounts.Add(account);
        await db.SaveChangesAsync();

        var user = Principal(FatVpnClaimTypes.AccountId, account.Id.ToString());
        var info = await db.ResolveSubscriptionAsync(user, default);

        Assert.NotNull(info);
        Assert.Equal("acc-sub", info!.SubscriptionId);
        Assert.True(info.IsActive);
    }

    [Fact]
    public async Task Resolve_TokenSession_UsesTokenSubscription()
    {
        using var db = TestHelpers.NewDb();
        var token = new Token
        {
            Id = Guid.NewGuid(), RemnawaveSubscriptionId = "tok-sub",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(-1),
        };
        db.Tokens.Add(token);
        await db.SaveChangesAsync();

        var user = Principal(FatVpnClaimTypes.TokenId, token.Id.ToString());
        var info = await db.ResolveSubscriptionAsync(user, default);

        Assert.NotNull(info);
        Assert.Equal("tok-sub", info!.SubscriptionId);
        Assert.False(info.IsActive); // expired
    }

    [Fact]
    public async Task Resolve_UnknownAccount_ReturnsNull()
    {
        using var db = TestHelpers.NewDb();
        var user = Principal(FatVpnClaimTypes.AccountId, Guid.NewGuid().ToString());
        Assert.Null(await db.ResolveSubscriptionAsync(user, default));
    }

    [Fact]
    public async Task Resolve_UnknownToken_ReturnsNull()
    {
        using var db = TestHelpers.NewDb();
        var user = Principal(FatVpnClaimTypes.TokenId, Guid.NewGuid().ToString());
        Assert.Null(await db.ResolveSubscriptionAsync(user, default));
    }

    private static System.Security.Claims.ClaimsPrincipal Principal(string type, string value)
        => new(new System.Security.Claims.ClaimsIdentity(
            [new System.Security.Claims.Claim(type, value)], "Test"));
}

public class ProtectedEndpointTests
{
    private static System.Security.Claims.Claim AccountClaim(Guid id)
        => new(FatVpnClaimTypes.AccountId, id.ToString());

    /// Options for /config. Hysteria augmentation is forced off here (production
    /// defaults it on) so these tests can assert the subscription is proxied
    /// through unchanged; the splicing itself is covered by
    /// <see cref="SubscriptionAugmenterTests"/>.
    /// A cache per controller, so one test's node list can't answer another's.
    private static Microsoft.Extensions.Caching.Memory.IMemoryCache NewCache()
        => new Microsoft.Extensions.Caching.Memory.MemoryCache(
            new Microsoft.Extensions.Caching.Memory.MemoryCacheOptions());

    private static Microsoft.Extensions.Options.IOptions<RemnawaveOptions> RemnawaveOptionsFor(
        bool augmentHysteria = false)
        => Microsoft.Extensions.Options.Options.Create(
            new RemnawaveOptions { AugmentHysteria = augmentHysteria });

    [Fact]
    public async Task Me_ActiveSubscription_ReturnsActive()
    {
        using var db = TestHelpers.NewDb();
        var account = new Account { Id = Guid.NewGuid(), CurrentSubscriptionId = "s", ExpiresAt = DateTimeOffset.UtcNow.AddDays(3) };
        db.Accounts.Add(account);
        await db.SaveChangesAsync();

        var controller = new MeController(db);
        controller.WithUser(AccountClaim(account.Id));

        var ok = Assert.IsType<OkObjectResult>(await controller.GetMe(default));
        Assert.Contains("active", System.Text.Json.JsonSerializer.Serialize(ok.Value));
    }

    [Fact]
    public async Task Me_ReturnsAccountKeyCode()
    {
        // The bot-pushed "Код для FatVPN App" is surfaced on /me so a pairing
        // session (which never pastes a code) can display the same key the bot shows.
        using var db = TestHelpers.NewDb();
        var account = new Account
        {
            Id = Guid.NewGuid(),
            CurrentSubscriptionId = "sub-abc",
            CurrentKeyCode = "GALH7WU63B8HAD80",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(3),
        };
        db.Accounts.Add(account);
        await db.SaveChangesAsync();

        var controller = new MeController(db);
        controller.WithUser(AccountClaim(account.Id));

        var ok = Assert.IsType<OkObjectResult>(await controller.GetMe(default));
        var json = System.Text.Json.JsonSerializer.Serialize(ok.Value);
        Assert.Contains("GALH7WU63B8HAD80", json);
    }

    [Fact]
    public async Task Me_NoKeyCode_ReturnsNullKeyCode()
    {
        // Legacy account without a pushed key code — keyCode is null, not "".
        using var db = TestHelpers.NewDb();
        var account = new Account { Id = Guid.NewGuid(), CurrentSubscriptionId = "s", ExpiresAt = DateTimeOffset.UtcNow.AddDays(3) };
        db.Accounts.Add(account);
        await db.SaveChangesAsync();

        var controller = new MeController(db);
        controller.WithUser(AccountClaim(account.Id));

        var ok = Assert.IsType<OkObjectResult>(await controller.GetMe(default));
        var json = System.Text.Json.JsonSerializer.Serialize(ok.Value);
        Assert.Contains("\"keyCode\":null", json);
    }

    [Fact]
    public async Task Me_UnknownSession_Unauthorized()
    {
        // Unknown session resolves the same 401 across /me, /servers, /config.
        using var db = TestHelpers.NewDb();
        var controller = new MeController(db);
        controller.WithUser(AccountClaim(Guid.NewGuid()));
        Assert.IsType<UnauthorizedResult>(await controller.GetMe(default));
    }

    [Fact]
    public async Task Config_AccountWithNoSubscription_Unauthorized()
    {
        // CurrentSubscriptionId is "" on a fresh account — treated as "no sub" (401),
        // not proxied to Remnawave as an empty id.
        using var db = TestHelpers.NewDb();
        var account = new Account { Id = Guid.NewGuid(), CurrentSubscriptionId = "", ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);
        await db.SaveChangesAsync();

        var controller = new ConfigController(db, new FakeRemnawaveClient(), RemnawaveOptionsFor());
        controller.WithUser(AccountClaim(account.Id));

        Assert.IsType<UnauthorizedResult>(await controller.GetConfig(default));
    }

    [Fact]
    public async Task Servers_LapsedSubscription_Returns402()
    {
        using var db = TestHelpers.NewDb();
        var account = new Account { Id = Guid.NewGuid(), CurrentSubscriptionId = "s", ExpiresAt = DateTimeOffset.UtcNow.AddDays(-1) };
        db.Accounts.Add(account);
        await db.SaveChangesAsync();

        var controller = new ServersController(db, new FakeRemnawaveClient(), NewCache());
        controller.WithUser(AccountClaim(account.Id));

        var result = Assert.IsType<StatusCodeResult>(await controller.GetServers(default));
        Assert.Equal(StatusCodes.Status402PaymentRequired, result.StatusCode);
    }

    [Fact]
    public async Task Servers_Active_ReturnsNodes()
    {
        using var db = TestHelpers.NewDb();
        var account = new Account { Id = Guid.NewGuid(), CurrentSubscriptionId = "s", ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);
        await db.SaveChangesAsync();

        var remna = new FakeRemnawaveClient
        {
            OnGetNodes = () => new List<ServerCountry> { new("DE", "🇩🇪", 1, new List<ServerNode>()) },
        };
        var controller = new ServersController(db, remna, NewCache());
        controller.WithUser(AccountClaim(account.Id));

        Assert.IsType<OkObjectResult>(await controller.GetServers(default));
    }

    [Fact]
    public async Task Config_Lapsed_Returns402()
    {
        using var db = TestHelpers.NewDb();
        var account = new Account { Id = Guid.NewGuid(), CurrentSubscriptionId = "s", ExpiresAt = DateTimeOffset.UtcNow.AddDays(-1) };
        db.Accounts.Add(account);
        await db.SaveChangesAsync();

        var controller = new ConfigController(db, new FakeRemnawaveClient(), RemnawaveOptionsFor());
        controller.WithUser(AccountClaim(account.Id));

        var result = Assert.IsType<StatusCodeResult>(await controller.GetConfig(default));
        Assert.Equal(StatusCodes.Status402PaymentRequired, result.StatusCode);
    }

    [Fact]
    public async Task Config_Active_ProxiesContent()
    {
        using var db = TestHelpers.NewDb();
        var account = new Account { Id = Guid.NewGuid(), CurrentSubscriptionId = "sub-xyz", ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);
        await db.SaveChangesAsync();

        var remna = new FakeRemnawaveClient { OnGetConfig = () => ("base64payload", "text/plain") };
        var controller = new ConfigController(db, remna, RemnawaveOptionsFor());
        controller.WithUser(AccountClaim(account.Id));

        var content = Assert.IsType<ContentResult>(await controller.GetConfig(default));
        Assert.Equal("base64payload", content.Content);
    }
}
