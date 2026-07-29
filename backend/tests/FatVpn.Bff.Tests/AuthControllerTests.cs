using FatVpn.Bff.Api.Controllers;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure.TrialPool;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace FatVpn.Bff.Tests;

public class AuthControllerTests
{
    private static AuthController NewController(
        Infrastructure.FatVpnDbContext db,
        Infrastructure.Auth.JwtOptions? jwt = null,
        int maxDevicesPerKey = 3)
        => new(db, TestHelpers.JwtService(), TestHelpers.RefreshService(),
               TestHelpers.Opt(new TrialOptions()), TestHelpers.Opt(jwt ?? TestHelpers.Jwt()),
               TestHelpers.Opt(TestHelpers.Auth(maxDevicesPerKey)),
               Microsoft.Extensions.Logging.Abstractions.NullLogger<AuthController>.Instance);

    [Fact]
    public async Task ExchangeToken_ValidShortToken_ReturnsAccessAndRefresh()
    {
        using var db = TestHelpers.NewDb();
        var token = new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "SHORT123",
            RemnawaveSubscriptionId = "sub-1",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(10),
        };
        db.Tokens.Add(token);
        await db.SaveChangesAsync();

        var result = await NewController(db).ExchangeToken(new ExchangeTokenRequest("SHORT123"), default);

        var ok = Assert.IsType<OkObjectResult>(result);
        Assert.NotNull(ok.Value);
        Assert.Single(db.RefreshTokens); // a refresh token was persisted
    }

    [Fact]
    public async Task ExchangeToken_UnknownToken_ReturnsNotFound()
    {
        using var db = TestHelpers.NewDb();
        var result = await NewController(db).ExchangeToken(new ExchangeTokenRequest("nope"), default);
        Assert.IsType<NotFoundResult>(result);
    }

    [Fact]
    public async Task ExchangeToken_ExpiredToken_ReturnsNotFound()
    {
        using var db = TestHelpers.NewDb();
        db.Tokens.Add(new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "OLD",
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1),
        });
        await db.SaveChangesAsync();

        var result = await NewController(db).ExchangeToken(new ExchangeTokenRequest("OLD"), default);
        Assert.IsType<NotFoundResult>(result);
    }

    [Fact]
    public async Task ExchangeToken_FirstDevice_BindsKeyToThatDevice()
    {
        using var db = TestHelpers.NewDb();
        db.Tokens.Add(new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "K",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(5),
        });
        await db.SaveChangesAsync();

        var result = await NewController(db).ExchangeToken(new ExchangeTokenRequest("K", "device-A"), default);

        Assert.IsType<OkObjectResult>(result);
        var token = await db.Tokens.AsNoTracking().SingleAsync(t => t.ShortToken == "K");
        var slot = Assert.Single(await db.TokenDevices.AsNoTracking().Where(d => d.TokenId == token.Id).ToListAsync());
        Assert.Equal(0, slot.SlotIndex);
    }

    [Fact]
    public async Task ExchangeToken_SameDeviceReentersKey_SucceedsWithoutTakingASecondSlot()
    {
        using var db = TestHelpers.NewDb();
        db.Tokens.Add(new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "K",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(5),
        });
        await db.SaveChangesAsync();

        await NewController(db).ExchangeToken(new ExchangeTokenRequest("K", "device-A"), default);
        var result = await NewController(db).ExchangeToken(new ExchangeTokenRequest("K", "device-A"), default);

        Assert.IsType<OkObjectResult>(result);
        // Re-entering a key on the same phone (reinstall, sign-out, second paste)
        // must not eat one of the other phones' slots.
        Assert.Single(await db.TokenDevices.AsNoTracking().ToListAsync());
    }

    [Fact]
    public async Task ExchangeToken_ThreeDevices_AllSucceedAndTheFourthConflicts()
    {
        using var db = TestHelpers.NewDb();
        db.Tokens.Add(new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "K",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(5),
        });
        await db.SaveChangesAsync();

        foreach (var device in new[] { "device-A", "device-B", "device-C" })
        {
            Assert.IsType<OkObjectResult>(
                await NewController(db).ExchangeToken(new ExchangeTokenRequest("K", device), default));
        }

        var result = await NewController(db).ExchangeToken(new ExchangeTokenRequest("K", "device-D"), default);

        var conflict = Assert.IsType<ConflictObjectResult>(result);
        // The app tells "already on 3 devices" from "bound to another phone" by
        // this code, so it must survive refactors of the response shape.
        Assert.Contains(AuthController.DeviceLimitError, conflict.Value!.ToString());
        Assert.Equal(3, await db.TokenDevices.CountAsync());
    }

    [Fact]
    public async Task RegisterToken_Reissue_FreesEveryDeviceSlot()
    {
        // "Поменять ключ" in the bot is how a user who replaced their phones gets
        // back in, so a reissue has to release all three slots, not just one.
        using var db = TestHelpers.NewDb();
        db.Tokens.Add(new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "K",
            RemnawaveSubscriptionId = "sub-1",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(5),
        });
        await db.SaveChangesAsync();

        foreach (var device in new[] { "device-A", "device-B", "device-C" })
        {
            await NewController(db).ExchangeToken(new ExchangeTokenRequest("K", device), default);
        }
        Assert.IsType<ConflictObjectResult>(
            await NewController(db).ExchangeToken(new ExchangeTokenRequest("K", "device-D"), default));

        await new InternalTokensController(db).RegisterToken(
            new RegisterTokenRequest("K", "sub-1", DateTimeOffset.UtcNow.AddDays(30)), default);

        Assert.Empty(await db.TokenDevices.AsNoTracking().ToListAsync());
        Assert.IsType<OkObjectResult>(
            await NewController(db).ExchangeToken(new ExchangeTokenRequest("K", "device-D"), default));
    }

    [Fact]
    public async Task ExchangeToken_SecondDevice_ConflictsWhenTheLimitIsOne()
    {
        // The old "one key = one phone" rule is now just Auth:MaxDevicesPerKey = 1.
        using var db = TestHelpers.NewDb();
        db.Tokens.Add(new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "K",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(5),
        });
        await db.SaveChangesAsync();

        await NewController(db, maxDevicesPerKey: 1)
            .ExchangeToken(new ExchangeTokenRequest("K", "device-A"), default);
        var result = await NewController(db, maxDevicesPerKey: 1)
            .ExchangeToken(new ExchangeTokenRequest("K", "device-B"), default);

        Assert.IsType<ConflictObjectResult>(result);
    }

    [Fact]
    public async Task ExchangeToken_NoAttestation_IssuesWithoutTakingASlot()
    {
        // Older app builds send no attestation; the session is still issued and
        // every slot stays free so real devices can claim them later.
        using var db = TestHelpers.NewDb();
        db.Tokens.Add(new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "K",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(5),
        });
        await db.SaveChangesAsync();

        var result = await NewController(db).ExchangeToken(new ExchangeTokenRequest("K"), default);

        Assert.IsType<OkObjectResult>(result);
        Assert.Empty(await db.TokenDevices.AsNoTracking().ToListAsync());
    }

    [Fact]
    public async Task ExchangeToken_UnboundKey_StaysALegacyTokenSession()
    {
        // A key the bot never told us the owner of: nothing to resolve through,
        // so the session identity is still the key row itself.
        using var db = TestHelpers.NewDb();
        var token = new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "K",
            RemnawaveSubscriptionId = "sub-1",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(5),
        };
        db.Tokens.Add(token);
        await db.SaveChangesAsync();

        Assert.IsType<OkObjectResult>(
            await NewController(db).ExchangeToken(new ExchangeTokenRequest("K"), default));

        var refresh = await db.RefreshTokens.AsNoTracking().SingleAsync();
        Assert.Equal(token.Id, refresh.TokenId);
        Assert.Null(refresh.AccountId);
    }

    [Fact]
    public async Task ExchangeToken_AccountBoundKey_IssuesAnAccountSessionAndMakesThatKeyActive()
    {
        // Pasting a code is the user choosing which of their keys the app runs
        // on: the account switches to it, and the session is the account's, so
        // later extensions reach the app instead of dying on the key row.
        using var db = TestHelpers.NewDb();
        var account = new Account
        {
            Id = Guid.NewGuid(),
            TelegramUserId = 42,
            CurrentSubscriptionId = "sub-other",
            CurrentKeyCode = "OTHERCODE",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(30),
        };
        db.Accounts.Add(account);
        db.Tokens.Add(new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "CHOSEN",
            RemnawaveSubscriptionId = "sub-chosen",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(5),
            AccountId = account.Id,
        });
        await db.SaveChangesAsync();

        Assert.IsType<OkObjectResult>(
            await NewController(db).ExchangeToken(new ExchangeTokenRequest("CHOSEN"), default));

        var stored = await db.Accounts.AsNoTracking().SingleAsync();
        Assert.Equal("sub-chosen", stored.CurrentSubscriptionId);
        Assert.Equal("CHOSEN", stored.CurrentKeyCode);

        var refresh = await db.RefreshTokens.AsNoTracking().SingleAsync();
        Assert.Equal(account.Id, refresh.AccountId);
        Assert.Null(refresh.TokenId);
    }

    [Fact]
    public async Task ExchangeToken_KeyExtendedOnTheAccount_IsNotRefusedAsExpired()
    {
        // The bot rewrites the key row only when it reissues a code; an
        // extension lands on the account. Reading the stale row here is what
        // used to answer a renewed subscriber's own key with a flat 404.
        using var db = TestHelpers.NewDb();
        var account = new Account
        {
            Id = Guid.NewGuid(),
            TelegramUserId = 42,
            CurrentSubscriptionId = "sub-1",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(30), // extended in the bot
        };
        db.Accounts.Add(account);
        db.Tokens.Add(new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "K",
            RemnawaveSubscriptionId = "sub-1",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(-2), // what the bot registered back then
            AccountId = account.Id,
        });
        await db.SaveChangesAsync();

        Assert.IsType<OkObjectResult>(
            await NewController(db).ExchangeToken(new ExchangeTokenRequest("K"), default));
        Assert.Equal(1, await db.RefreshTokens.CountAsync());
    }

    [Fact]
    public async Task ExchangeToken_AccountBoundKeyGenuinelyExpired_ReturnsNotFound()
    {
        // The rescue above applies only to the key the account is actually on.
        // A different, spent key is still spent.
        using var db = TestHelpers.NewDb();
        var account = new Account
        {
            Id = Guid.NewGuid(),
            TelegramUserId = 42,
            CurrentSubscriptionId = "sub-live",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(30),
        };
        db.Accounts.Add(account);
        db.Tokens.Add(new Token
        {
            Id = Guid.NewGuid(),
            ShortToken = "SPENT",
            RemnawaveSubscriptionId = "sub-spent",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(-2),
            AccountId = account.Id,
        });
        await db.SaveChangesAsync();

        Assert.IsType<NotFoundResult>(
            await NewController(db).ExchangeToken(new ExchangeTokenRequest("SPENT"), default));
    }

    [Fact]
    public async Task Refresh_ValidAccountToken_RotatesAndRevokesOld()
    {
        using var db = TestHelpers.NewDb();
        var refreshSvc = TestHelpers.RefreshService();
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);
        var (raw, entity) = refreshSvc.Create(account.Id, tokenId: null);
        db.RefreshTokens.Add(entity);
        await db.SaveChangesAsync();

        var result = await NewController(db).Refresh(new RefreshRequest(raw), default);

        Assert.IsType<OkObjectResult>(result);
        // AsNoTracking throughout: the rotation is a single UPDATE statement, so
        // the change tracker's copy of the row is stale by design.
        var stored = await db.RefreshTokens.AsNoTracking().SingleAsync(r => r.Id == entity.Id);
        Assert.NotNull(stored.RevokedAt); // old token revoked (rotation)
        Assert.Equal(2, await db.RefreshTokens.CountAsync()); // old + new
    }

    [Fact]
    public async Task Refresh_LapsedSubscription_StillRefreshes()
    {
        // A lapsed subscription must still refresh so the app reaches its renew screen.
        using var db = TestHelpers.NewDb();
        var refreshSvc = TestHelpers.RefreshService();
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(-3) };
        db.Accounts.Add(account);
        var (raw, entity) = refreshSvc.Create(account.Id, null);
        db.RefreshTokens.Add(entity);
        await db.SaveChangesAsync();

        var result = await NewController(db).Refresh(new RefreshRequest(raw), default);
        Assert.IsType<OkObjectResult>(result);
    }

    [Fact]
    public async Task Refresh_RevokedToken_ReturnsUnauthorized()
    {
        using var db = TestHelpers.NewDb();
        var refreshSvc = TestHelpers.RefreshService();
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);
        var (raw, entity) = refreshSvc.Create(account.Id, null);
        // Well outside the grace window, so this is reuse rather than the app
        // racing itself (see Refresh_JustRotatedToken_InsideGraceWindow_...).
        entity.RevokedAt = DateTimeOffset.UtcNow.AddMinutes(-10);
        db.RefreshTokens.Add(entity);
        await db.SaveChangesAsync();

        var result = await NewController(db).Refresh(new RefreshRequest(raw), default);
        Assert.IsType<UnauthorizedResult>(result);
    }

    [Fact]
    public async Task Refresh_ReusedRotatedToken_RevokesWholeFamily()
    {
        // Reusing an already-rotated (revoked, unexpired) token signals theft:
        // every active refresh token in that rotation chain must be revoked.
        using var db = TestHelpers.NewDb();
        var refreshSvc = TestHelpers.RefreshService();
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);

        var (staleRaw, stale) = refreshSvc.Create(account.Id, null);
        stale.RevokedAt = DateTimeOffset.UtcNow.AddMinutes(-10); // rotated out long ago
        db.RefreshTokens.Add(stale);
        // What that rotation handed back — same session, so same family.
        var (_, live) = refreshSvc.Create(account.Id, null, stale.SessionStartedAt, stale.FamilyId);
        db.RefreshTokens.Add(live);
        await db.SaveChangesAsync();

        var result = await NewController(db).Refresh(new RefreshRequest(staleRaw), default);

        Assert.IsType<UnauthorizedResult>(result);
        Assert.NotNull((await db.RefreshTokens.AsNoTracking().SingleAsync(r => r.Id == live.Id)).RevokedAt); // family nuked
        Assert.False(await db.RefreshTokens.AnyAsync(r => r.RevokedAt == null));
    }

    [Fact]
    public async Task Refresh_JustRotatedToken_InsideGraceWindow_IsNotTreatedAsTheft()
    {
        // The app fires several /auth/refresh calls the moment its access token
        // expires. The loser of that race presents a token that was rotated out
        // milliseconds ago — that is the client racing itself, not a thief, and
        // logging it out of a paid subscription would be the worse failure.
        using var db = TestHelpers.NewDb();
        var refreshSvc = TestHelpers.RefreshService();
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);

        var (raw, entity) = refreshSvc.Create(account.Id, null);
        entity.RevokedAt = DateTimeOffset.UtcNow.AddSeconds(-2);
        db.RefreshTokens.Add(entity);
        var (_, live) = refreshSvc.Create(account.Id, null); // what the winner handed back
        db.RefreshTokens.Add(live);
        await db.SaveChangesAsync();

        var result = await NewController(db).Refresh(new RefreshRequest(raw), default);

        Assert.IsType<OkObjectResult>(result);
        // The family survives: the token the winning call returned still works.
        Assert.Null((await db.RefreshTokens.AsNoTracking().SingleAsync(r => r.Id == live.Id)).RevokedAt);
    }

    [Fact]
    public async Task Refresh_JustRotatedToken_GraceWindowDisabled_RevokesFamily()
    {
        // With the window closed the old behaviour stands, so the trade-off is a
        // configuration decision rather than something baked into the code.
        using var db = TestHelpers.NewDb();
        var refreshSvc = TestHelpers.RefreshService();
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);

        var (raw, entity) = refreshSvc.Create(account.Id, null);
        entity.RevokedAt = DateTimeOffset.UtcNow.AddSeconds(-2);
        db.RefreshTokens.Add(entity);
        var (_, live) = refreshSvc.Create(account.Id, null, entity.SessionStartedAt, entity.FamilyId);
        db.RefreshTokens.Add(live);
        await db.SaveChangesAsync();

        var jwt = TestHelpers.Jwt();
        jwt.RefreshGraceWindow = TimeSpan.Zero;
        var result = await NewController(db, jwt).Refresh(new RefreshRequest(raw), default);

        Assert.IsType<UnauthorizedResult>(result);
        Assert.NotNull((await db.RefreshTokens.AsNoTracking().SingleAsync(r => r.Id == live.Id)).RevokedAt);
    }

    [Fact]
    public async Task Refresh_ExpiredToken_Unauthorized_WithoutRevokingFamily()
    {
        using var db = TestHelpers.NewDb();
        var refreshSvc = TestHelpers.RefreshService();
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);

        var (raw, entity) = refreshSvc.Create(account.Id, null);
        entity.ExpiresAt = DateTimeOffset.UtcNow.AddDays(-1);
        db.RefreshTokens.Add(entity);
        var (_, live) = refreshSvc.Create(account.Id, null);
        db.RefreshTokens.Add(live);
        await db.SaveChangesAsync();

        var result = await NewController(db).Refresh(new RefreshRequest(raw), default);

        Assert.IsType<UnauthorizedResult>(result);
        // Simply running out of time is not evidence of theft.
        Assert.Null((await db.RefreshTokens.AsNoTracking().SingleAsync(r => r.Id == live.Id)).RevokedAt);
        Assert.Equal(2, await db.RefreshTokens.CountAsync()); // nothing new minted
    }

    [Fact]
    public async Task Refresh_AbsoluteLifetimeConfigured_RotationCannotOutliveIt()
    {
        // Rotation grants a full refresh lifetime each time, so a session that is
        // used regularly never ends. With a ceiling configured, the session start
        // travels across rotations and caps every successor.
        using var db = TestHelpers.NewDb();
        var jwt = TestHelpers.Jwt();
        jwt.AbsoluteSessionLifetime = TimeSpan.FromDays(120);

        var refreshSvc = new Infrastructure.Auth.RefreshTokenService(TestHelpers.Opt(jwt));
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);

        var sessionStart = DateTimeOffset.UtcNow.AddDays(-100); // 20 days of session left
        var (raw, entity) = refreshSvc.Create(account.Id, null, sessionStart);
        db.RefreshTokens.Add(entity);
        await db.SaveChangesAsync();

        var controller = new AuthController(db, TestHelpers.JwtService(), refreshSvc,
            TestHelpers.Opt(new TrialOptions()), TestHelpers.Opt(jwt), TestHelpers.Opt(TestHelpers.Auth()),
            Microsoft.Extensions.Logging.Abstractions.NullLogger<AuthController>.Instance);
        Assert.IsType<OkObjectResult>(await controller.Refresh(new RefreshRequest(raw), default));

        var issued = await db.RefreshTokens.AsNoTracking()
            .SingleAsync(r => r.Id != entity.Id);
        Assert.Equal(sessionStart, issued.SessionStartedAt);
        // The 90-day default would have run past the 120-day ceiling.
        Assert.True(issued.ExpiresAt <= sessionStart + jwt.AbsoluteSessionLifetime);
        Assert.True(issued.ExpiresAt < DateTimeOffset.UtcNow.AddDays(30));
    }

    [Fact]
    public async Task Refresh_NoAbsoluteLifetime_KeepsTheFullRefreshWindow()
    {
        using var db = TestHelpers.NewDb();
        var refreshSvc = TestHelpers.RefreshService();
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);

        var (raw, entity) = refreshSvc.Create(account.Id, null, DateTimeOffset.UtcNow.AddDays(-300));
        db.RefreshTokens.Add(entity);
        await db.SaveChangesAsync();

        Assert.IsType<OkObjectResult>(await NewController(db).Refresh(new RefreshRequest(raw), default));

        var issued = await db.RefreshTokens.AsNoTracking().SingleAsync(r => r.Id != entity.Id);
        Assert.True(issued.ExpiresAt > DateTimeOffset.UtcNow.AddDays(89));
    }

    [Fact]
    public async Task Refresh_UnknownToken_ReturnsUnauthorized()
    {
        using var db = TestHelpers.NewDb();
        var result = await NewController(db).Refresh(new RefreshRequest("deadbeef"), default);
        Assert.IsType<UnauthorizedResult>(result);
    }

    [Fact]
    public async Task Refresh_AccountDeleted_ReturnsUnauthorized()
    {
        using var db = TestHelpers.NewDb();
        var refreshSvc = TestHelpers.RefreshService();
        var (raw, entity) = refreshSvc.Create(Guid.NewGuid(), null); // account id points nowhere
        db.RefreshTokens.Add(entity);
        await db.SaveChangesAsync();

        var result = await NewController(db).Refresh(new RefreshRequest(raw), default);
        Assert.IsType<UnauthorizedResult>(result);
    }

    [Fact]
    public async Task Logout_RevokesToken_ReturnsNoContent()
    {
        using var db = TestHelpers.NewDb();
        var refreshSvc = TestHelpers.RefreshService();
        var (raw, entity) = refreshSvc.Create(null, Guid.NewGuid());
        db.RefreshTokens.Add(entity);
        await db.SaveChangesAsync();

        var result = await NewController(db).Logout(new RefreshRequest(raw), default);

        Assert.IsType<NoContentResult>(result);
        Assert.NotNull((await db.RefreshTokens.AsNoTracking().SingleAsync(r => r.Id == entity.Id)).RevokedAt);
    }

    [Fact]
    public async Task Logout_UnknownToken_StillReturnsNoContent()
    {
        // Always 204 so a client can't probe which tokens exist.
        using var db = TestHelpers.NewDb();
        var result = await NewController(db).Logout(new RefreshRequest("nope"), default);
        Assert.IsType<NoContentResult>(result);
    }
}
