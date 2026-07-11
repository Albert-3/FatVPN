using FatVpn.Bff.Api.Controllers;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure.TrialPool;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace FatVpn.Bff.Tests;

public class AuthControllerTests
{
    private static AuthController NewController(Infrastructure.FatVpnDbContext db)
        => new(db, TestHelpers.JwtService(), TestHelpers.RefreshService(), TestHelpers.Opt(new TrialOptions()));

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
        var token = await db.Tokens.SingleAsync(t => t.ShortToken == "K");
        Assert.NotNull(token.BoundDeviceKeyHash);
    }

    [Fact]
    public async Task ExchangeToken_SameDeviceReentersKey_Succeeds()
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
    }

    [Fact]
    public async Task ExchangeToken_DifferentDevice_ReturnsConflict()
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
        var result = await NewController(db).ExchangeToken(new ExchangeTokenRequest("K", "device-B"), default);

        Assert.IsType<ConflictResult>(result);
    }

    [Fact]
    public async Task ExchangeToken_NoAttestation_IssuesWithoutBinding()
    {
        // Older app builds send no attestation; the session is still issued and
        // the key stays unbound so a real device can claim it later.
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
        var token = await db.Tokens.SingleAsync(t => t.ShortToken == "K");
        Assert.Null(token.BoundDeviceKeyHash);
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
        var stored = await db.RefreshTokens.FindAsync(entity.Id);
        Assert.NotNull(stored!.RevokedAt); // old token revoked (rotation)
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
        entity.RevokedAt = DateTimeOffset.UtcNow;
        db.RefreshTokens.Add(entity);
        await db.SaveChangesAsync();

        var result = await NewController(db).Refresh(new RefreshRequest(raw), default);
        Assert.IsType<UnauthorizedResult>(result);
    }

    [Fact]
    public async Task Refresh_ReusedRotatedToken_RevokesWholeFamily()
    {
        // Reusing an already-rotated (revoked, unexpired) token signals theft:
        // every active refresh token for the same account must be revoked.
        using var db = TestHelpers.NewDb();
        var refreshSvc = TestHelpers.RefreshService();
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(5) };
        db.Accounts.Add(account);

        var (staleRaw, stale) = refreshSvc.Create(account.Id, null);
        stale.RevokedAt = DateTimeOffset.UtcNow; // already rotated out
        db.RefreshTokens.Add(stale);
        var (_, live) = refreshSvc.Create(account.Id, null); // the current live token
        db.RefreshTokens.Add(live);
        await db.SaveChangesAsync();

        var result = await NewController(db).Refresh(new RefreshRequest(staleRaw), default);

        Assert.IsType<UnauthorizedResult>(result);
        Assert.NotNull((await db.RefreshTokens.FindAsync(live.Id))!.RevokedAt); // family nuked
        Assert.False(await db.RefreshTokens.AnyAsync(r => r.RevokedAt == null));
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
        Assert.NotNull((await db.RefreshTokens.FindAsync(entity.Id))!.RevokedAt);
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
