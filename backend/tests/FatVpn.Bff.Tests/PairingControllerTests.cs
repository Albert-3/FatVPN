using System.Text.Json;
using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Api.Controllers;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure.Bot;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace FatVpn.Bff.Tests;

public class PairControllerTests
{
    private static PairController NewController(Infrastructure.FatVpnDbContext db)
        => new(db, TestHelpers.JwtService(), TestHelpers.RefreshService());

    private static string Str(object value, string prop)
        => JsonSerializer.Serialize(value) is var json
           && JsonSerializer.Deserialize<JsonElement>(json).TryGetProperty(prop, out var el)
           ? el.ToString() : "";

    [Fact]
    public async Task Start_CreatesPendingPairing()
    {
        using var db = TestHelpers.NewDb();
        var result = await NewController(db).Start(default);

        Assert.IsType<OkObjectResult>(result);
        var pairing = Assert.Single(db.PairingCodes);
        Assert.Equal(PairingStatus.Pending, pairing.Status);
        Assert.Equal(8, pairing.Code.Length);
        Assert.NotEmpty(pairing.PollToken);
        Assert.True(pairing.ExpiresAt > DateTimeOffset.UtcNow);
    }

    [Fact]
    public async Task Status_EmptyPollToken_BadRequest()
    {
        using var db = TestHelpers.NewDb();
        Assert.IsType<BadRequestResult>(await NewController(db).Status("", default));
    }

    [Fact]
    public async Task Status_UnknownPollToken_NotFound()
    {
        using var db = TestHelpers.NewDb();
        Assert.IsType<NotFoundResult>(await NewController(db).Status("nope", default));
    }

    [Fact]
    public async Task Status_Pending_ReturnsPending()
    {
        using var db = TestHelpers.NewDb();
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "CODE1", PollToken = "poll1",
            Status = PairingStatus.Pending,
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var ok = Assert.IsType<OkObjectResult>(await NewController(db).Status("poll1", default));
        Assert.Equal("pending", Str(ok.Value!, "status"));
    }

    [Fact]
    public async Task Status_ExpiredPending_ReturnsExpired()
    {
        using var db = TestHelpers.NewDb();
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "CODE2", PollToken = "poll2",
            Status = PairingStatus.Pending,
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1),
        });
        await db.SaveChangesAsync();

        var ok = Assert.IsType<OkObjectResult>(await NewController(db).Status("poll2", default));
        Assert.Equal("expired", Str(ok.Value!, "status"));
    }

    [Fact]
    public async Task Status_Completed_ReturnsTokensAndPersistsRefresh()
    {
        using var db = TestHelpers.NewDb();
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(30) };
        db.Accounts.Add(account);
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "CODE3", PollToken = "poll3",
            Status = PairingStatus.Completed, AccountId = account.Id,
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var ok = Assert.IsType<OkObjectResult>(await NewController(db).Status("poll3", default));
        Assert.Equal("completed", Str(ok.Value!, "status"));
        Assert.Single(db.RefreshTokens);
    }

    [Fact]
    public async Task Status_PolledTwiceAfterCompletion_IsSingleUse()
    {
        using var db = TestHelpers.NewDb();
        var account = new Account { Id = Guid.NewGuid(), ExpiresAt = DateTimeOffset.UtcNow.AddDays(30) };
        db.Accounts.Add(account);
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "ONCE", PollToken = "pollonce",
            Status = PairingStatus.Completed, AccountId = account.Id,
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var first = Assert.IsType<OkObjectResult>(await NewController(db).Status("pollonce", default));
        Assert.Equal("completed", Str(first.Value!, "status"));

        var second = Assert.IsType<OkObjectResult>(await NewController(db).Status("pollonce", default));
        Assert.Equal("expired", Str(second.Value!, "status"));

        Assert.Equal(1, await db.RefreshTokens.CountAsync()); // no second session minted
        Assert.Equal(PairingStatus.Consumed, (await db.PairingCodes.SingleAsync()).Status);
    }

    [Fact]
    public async Task Status_CompletedButAccountMissing_ReturnsExpired()
    {
        using var db = TestHelpers.NewDb();
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "CODE4", PollToken = "poll4",
            Status = PairingStatus.Completed, AccountId = Guid.NewGuid(), // dangling
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var ok = Assert.IsType<OkObjectResult>(await NewController(db).Status("poll4", default));
        Assert.Equal("expired", Str(ok.Value!, "status"));
    }
}

public class InternalPairControllerTests
{
    private const string Secret = "bot-secret";

    private static InternalPairController NewController(Infrastructure.FatVpnDbContext db, string? header)
    {
        var c = new InternalPairController(db, TestHelpers.Opt(new BotOptions { Secret = Secret }));
        if (header is not null) c.WithHeader(BotSecretValidator.HeaderName, header);
        else c.WithUser();
        return c;
    }

    [Fact]
    public async Task Complete_WrongSecret_Unauthorized()
    {
        using var db = TestHelpers.NewDb();
        var req = new CompletePairingRequest("CODE", 42, "sub", DateTimeOffset.UtcNow.AddDays(1));
        Assert.IsType<UnauthorizedResult>(await NewController(db, "wrong").Complete(req, default));
    }

    [Fact]
    public async Task Complete_ValidPairing_BindsAccountAndMarksCompleted()
    {
        using var db = TestHelpers.NewDb();
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "CODEX", PollToken = "p",
            Status = PairingStatus.Pending,
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var expiry = DateTimeOffset.UtcNow.AddDays(30);
        var result = await NewController(db, Secret)
            .Complete(new CompletePairingRequest("CODEX", 777, "sub-777", expiry), default);

        Assert.IsType<OkResult>(result);
        var pairing = await db.PairingCodes.SingleAsync();
        Assert.Equal(PairingStatus.Completed, pairing.Status);
        Assert.NotNull(pairing.AccountId);
        var account = await db.Accounts.SingleAsync();
        Assert.Equal(777, account.TelegramUserId);
        Assert.Equal("sub-777", account.CurrentSubscriptionId);
    }

    [Fact]
    public async Task Complete_UnknownCode_NotFound()
    {
        using var db = TestHelpers.NewDb();
        var req = new CompletePairingRequest("NOPE", 1, "s", DateTimeOffset.UtcNow.AddDays(1));
        Assert.IsType<NotFoundResult>(await NewController(db, Secret).Complete(req, default));
    }

    [Fact]
    public async Task Complete_AlreadyCompleted_Conflict()
    {
        using var db = TestHelpers.NewDb();
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "DONE", PollToken = "p",
            Status = PairingStatus.Completed,
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var req = new CompletePairingRequest("DONE", 1, "s", DateTimeOffset.UtcNow.AddDays(1));
        Assert.IsType<ConflictResult>(await NewController(db, Secret).Complete(req, default));
    }

    [Fact]
    public async Task Complete_ConsumedCode_Conflict()
    {
        // A single-use code that's already delivered a session can't be re-bound.
        using var db = TestHelpers.NewDb();
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "USED", PollToken = "p",
            Status = PairingStatus.Consumed, AccountId = Guid.NewGuid(),
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var req = new CompletePairingRequest("USED", 1, "s", DateTimeOffset.UtcNow.AddDays(1));
        Assert.IsType<ConflictResult>(await NewController(db, Secret).Complete(req, default));
    }

    [Fact]
    public async Task Complete_ExpiredCode_NotFound()
    {
        using var db = TestHelpers.NewDb();
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "EXP", PollToken = "p",
            Status = PairingStatus.Pending,
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1),
        });
        await db.SaveChangesAsync();

        var req = new CompletePairingRequest("EXP", 1, "s", DateTimeOffset.UtcNow.AddDays(1));
        Assert.IsType<NotFoundResult>(await NewController(db, Secret).Complete(req, default));
    }

    [Fact]
    public async Task Complete_ExistingAccount_UpdatesSubscription()
    {
        using var db = TestHelpers.NewDb();
        db.Accounts.Add(new Account
        {
            Id = Guid.NewGuid(), TelegramUserId = 555,
            CurrentSubscriptionId = "old", ExpiresAt = DateTimeOffset.UtcNow.AddDays(1),
        });
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "REPAIR", PollToken = "p",
            Status = PairingStatus.Pending,
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var req = new CompletePairingRequest("REPAIR", 555, "new-sub", DateTimeOffset.UtcNow.AddDays(60));
        await NewController(db, Secret).Complete(req, default);

        Assert.Equal(1, await db.Accounts.CountAsync()); // no duplicate account
        Assert.Equal("new-sub", (await db.Accounts.SingleAsync()).CurrentSubscriptionId);
    }
}
