using System.Text.Json;
using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Api.Controllers;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure.Bot;
using FatVpn.Bff.Infrastructure.TrialPool;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace FatVpn.Bff.Tests;

public class PairControllerTests
{
    private static PairController NewController(Infrastructure.FatVpnDbContext db)
        => new(db, TestHelpers.JwtService(), TestHelpers.RefreshService(),
               TestHelpers.Opt(new TrialOptions()), TestHelpers.Slots(db));

    private static string Str(object value, string prop)
        => JsonSerializer.Serialize(value) is var json
           && JsonSerializer.Deserialize<JsonElement>(json).TryGetProperty(prop, out var el)
           ? el.ToString() : "";

    [Fact]
    public async Task Start_CreatesPendingPairing()
    {
        using var db = TestHelpers.NewDb();
        var result = await NewController(db).Start(null, default);

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
    public async Task Status_Completed_ChargesTheSessionToADeviceSlot()
    {
        // Pairing is a way onto a subscription like any other. While it counted
        // for nothing, the three-device cap only applied to users who pasted the
        // code instead of pressing "Подключить через Telegram".
        using var db = TestHelpers.NewDb();
        var account = new Account
        {
            Id = Guid.NewGuid(),
            CurrentSubscriptionId = "sub-paired",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(30),
        };
        db.Accounts.Add(account);
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "DEV1", PollToken = "polldev",
            Status = PairingStatus.Completed, AccountId = account.Id,
            DeviceKeyHash = "hash-of-the-pairing-phone",
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var ok = Assert.IsType<OkObjectResult>(await NewController(db).Status("polldev", default));
        Assert.Equal("completed", Str(ok.Value!, "status"));

        var slot = Assert.Single(await db.TokenDevices.AsNoTracking().ToListAsync());
        Assert.Equal("sub-paired", slot.SubscriptionId);
        Assert.Equal("hash-of-the-pairing-phone", slot.DeviceKeyHash);
        // And the session knows its device, so signing out or being evicted can
        // find the slot again.
        Assert.Equal("hash-of-the-pairing-phone",
            (await db.RefreshTokens.AsNoTracking().SingleAsync()).DeviceKeyHash);
    }

    [Fact]
    public async Task Status_CompletedWithoutADevice_StillPairs()
    {
        // App builds that send no attestation at /pair/start keep working, and
        // take no slot — the same concession /auth/token has always made.
        using var db = TestHelpers.NewDb();
        var account = new Account
        {
            Id = Guid.NewGuid(),
            CurrentSubscriptionId = "sub-paired",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(30),
        };
        db.Accounts.Add(account);
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "OLD1", PollToken = "pollold",
            Status = PairingStatus.Completed, AccountId = account.Id,
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var ok = Assert.IsType<OkObjectResult>(await NewController(db).Status("pollold", default));
        Assert.Equal("completed", Str(ok.Value!, "status"));
        Assert.Empty(await db.TokenDevices.AsNoTracking().ToListAsync());
    }

    [Fact]
    public async Task Start_WithAnAttestation_RemembersTheDevice()
    {
        using var db = TestHelpers.NewDb();
        var result = await NewController(db)
            .Start(new StartPairingRequest("this-phones-attestation-token"), default);

        Assert.IsType<OkObjectResult>(result);
        // Recorded at /pair/start because that is the request the phone makes;
        // the later poll carries nothing but the poll token.
        Assert.NotNull(Assert.Single(db.PairingCodes).DeviceKeyHash);
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
        Assert.Equal(PairingStatus.Consumed, (await db.PairingCodes.AsNoTracking().SingleAsync()).Status);
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

    // The bot secret is no longer checked inside the action — it is an
    // authorization policy now, covered by BotSecretAuthorizationHandlerTests.
    private static InternalPairController NewController(Infrastructure.FatVpnDbContext db, string? header = null)
    {
        var c = new InternalPairController(db);
        if (header is not null) c.WithHeader(BotSecretValidator.HeaderName, header);
        else c.WithUser();
        return c;
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
            .Complete(new CompletePairingRequest("CODEX", 777, "sub-777", expiry, "GALHKEYCODE"), default);

        Assert.IsType<OkResult>(result);
        var pairing = await db.PairingCodes.SingleAsync();
        Assert.Equal(PairingStatus.Completed, pairing.Status);
        Assert.NotNull(pairing.AccountId);
        var account = await db.Accounts.SingleAsync();
        Assert.Equal(777, account.TelegramUserId);
        Assert.Equal("sub-777", account.CurrentSubscriptionId);
        Assert.Equal("GALHKEYCODE", account.CurrentKeyCode);
    }

    [Fact]
    public async Task Complete_SwitchingKeyWithoutACode_DropsThePreviousKeysCode()
    {
        // The bot names a key but not its code, which is the ordinary pairing
        // call. Holding on to the code we already had would show the app the
        // code of the key it just left, and pasting that on a second phone
        // would put it on a different subscription.
        using var db = TestHelpers.NewDb();
        db.Accounts.Add(new Account
        {
            Id = Guid.NewGuid(),
            TelegramUserId = 777,
            CurrentSubscriptionId = "sub-old",
            CurrentKeyCode = "CODE-OF-THE-OLD-KEY",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(10),
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
        });
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "SWITCH", PollToken = "p2",
            Status = PairingStatus.Pending,
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var result = await NewController(db, Secret).Complete(
            new CompletePairingRequest("SWITCH", 777, "sub-new", DateTimeOffset.UtcNow.AddDays(30)),
            default);

        Assert.IsType<OkResult>(result);
        var account = await db.Accounts.SingleAsync();
        Assert.Equal("sub-new", account.CurrentSubscriptionId);
        Assert.Null(account.CurrentKeyCode);
    }

    [Fact]
    public async Task Complete_SameKeyWithoutACode_KeepsTheCodeItAlreadyShows()
    {
        // Re-pairing onto the key already in use says nothing new about the
        // code, and blanking it would drop a good value for no reason.
        using var db = TestHelpers.NewDb();
        db.Accounts.Add(new Account
        {
            Id = Guid.NewGuid(),
            TelegramUserId = 778,
            CurrentSubscriptionId = "sub-same",
            CurrentKeyCode = "STILL-VALID",
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(10),
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
        });
        db.PairingCodes.Add(new PairingCode
        {
            Id = Guid.NewGuid(), Code = "SAME", PollToken = "p3",
            Status = PairingStatus.Pending,
            ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
        });
        await db.SaveChangesAsync();

        var result = await NewController(db, Secret).Complete(
            new CompletePairingRequest("SAME", 778, "sub-same", DateTimeOffset.UtcNow.AddDays(30)),
            default);

        Assert.IsType<OkResult>(result);
        var account = await db.Accounts.SingleAsync();
        Assert.Equal("STILL-VALID", account.CurrentKeyCode);
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
