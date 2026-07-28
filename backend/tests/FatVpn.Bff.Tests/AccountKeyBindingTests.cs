using System.ComponentModel.DataAnnotations;
using System.Text.Json;
using FatVpn.Bff.Api.Controllers;
using FatVpn.Bff.Domain;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace FatVpn.Bff.Tests;

/// <summary>
/// The exact JSON the Python bot posts, parsed by the records that receive it.
/// The bot lives outside this repository, so a renamed or mistyped field is
/// otherwise only discovered as a 400 on a live user's key.
/// </summary>
public class BotPayloadContractTests
{
    // What ASP.NET Core's MVC pipeline uses: camelCase in, case-insensitive.
    private static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web);

    [Fact]
    public void RegisterToken_PayloadWithOwner_Binds()
    {
        var request = JsonSerializer.Deserialize<RegisterTokenRequest>("""
            {"shortToken":"ABC","remnawaveSubscriptionId":"sub-1",
             "expiresAt":"2026-08-27T21:00:00+00:00","telegramUserId":123456789}
            """, Web)!;

        Assert.Equal("ABC", request.ShortToken);
        Assert.Equal(123456789, request.TelegramUserId);
    }

    [Fact]
    public void RegisterToken_PayloadFromAnOlderBot_StillBinds()
    {
        var request = JsonSerializer.Deserialize<RegisterTokenRequest>("""
            {"shortToken":"ABC","remnawaveSubscriptionId":"sub-1",
             "expiresAt":"2026-08-27T21:00:00+00:00"}
            """, Web)!;

        Assert.Null(request.TelegramUserId);
    }

    [Fact]
    public void UpsertSubscription_PayloadWithBothNewFlags_Binds()
    {
        var request = JsonSerializer.Deserialize<UpsertSubscriptionRequest>("""
            {"telegramUserId":1,"subscriptionId":"sub-new",
             "expiresAt":"2026-08-27T21:00:00+03:00","keyCode":"CODE",
             "makeActive":true,"replacesSubscriptionId":"sub-old"}
            """, Web)!;

        Assert.True(request.MakeActive);
        Assert.Equal("sub-old", request.ReplacesSubscriptionId);
        // The bot sends Moscow time; only the instant matters here, the UTC
        // normalisation happens on the way into the database.
        Assert.Equal(TimeSpan.FromHours(3), request.ExpiresAt.Offset);
    }

    [Fact]
    public void UpsertSubscription_PayloadFromAnOlderBot_DefaultsToNotSwitching()
    {
        var request = JsonSerializer.Deserialize<UpsertSubscriptionRequest>("""
            {"telegramUserId":1,"subscriptionId":"sub-1",
             "expiresAt":"2026-08-27T21:00:00+00:00"}
            """, Web)!;

        Assert.False(request.MakeActive);
        Assert.Null(request.ReplacesSubscriptionId);
    }

    [Fact]
    public void EveryRequestRecord_KeepsItsValidationOnTheConstructorParameter()
    {
        // MVC refuses to bind a positional record whose validation metadata sits
        // on the generated property instead of the primary-constructor
        // parameter: ModelMetadata.ThrowIfRecordTypeHasValidationOnProperties
        // throws before the action runs, and the caller gets a bare 500.
        //
        // This is invisible to every other test in this project, because they
        // all construct the records directly and never go through binding. It
        // shipped that way: `[property: StringLength(...)]` on these records
        // killed /auth/token, /auth/refresh, /trial and all of /internal/* the
        // moment they were first deployed. On a record positional parameter an
        // attribute already targets the parameter — the `property:` prefix is
        // what moves it to the wrong place.
        var offenders = new List<string>();

        foreach (var type in typeof(AuthController).Assembly.GetTypes())
        {
            if (!type.IsClass || type.IsAbstract) continue;
            var constructors = type.GetConstructors();
            if (constructors.Length != 1) continue;

            foreach (var parameter in constructors[0].GetParameters())
            {
                if (parameter.Name is null) continue;
                // A parameter with a same-named property is what makes this a
                // record as far as the binder is concerned.
                var property = type.GetProperty(parameter.Name);
                if (property is null) continue;
                if (property.GetCustomAttributes(typeof(ValidationAttribute), inherit: true).Length > 0)
                {
                    offenders.Add($"{type.Name}.{parameter.Name}");
                }
            }
        }

        Assert.True(offenders.Count == 0,
            "Validation must sit on the constructor parameter, not the property — "
            + "these would 500 on every request: " + string.Join(", ", offenders));
    }
}

/// <summary>
/// Which of a user's keys the app runs on. A user can hold several keys in the
/// bot while the account carries exactly one active subscription, so every
/// write has to say whether the user actually chose this key — otherwise
/// extending an unrelated key silently drags the app over to it.
/// </summary>
public class AccountKeyBindingTests
{
    private static Account Seeded(Infrastructure.FatVpnDbContext db, string subscriptionId) =>
        new()
        {
            Id = Guid.NewGuid(),
            TelegramUserId = 42,
            CurrentSubscriptionId = subscriptionId,
            CurrentKeyCode = "CODE-" + subscriptionId,
            ExpiresAt = DateTimeOffset.UtcNow.AddDays(10),
            CreatedAt = DateTimeOffset.UtcNow,
        };

    [Fact]
    public async Task UpsertSubscription_ExtendingAnotherKey_DoesNotMoveTheApp()
    {
        using var db = TestHelpers.NewDb();
        db.Accounts.Add(Seeded(db, "sub-active"));
        await db.SaveChangesAsync();

        var result = await new InternalAccountController(db).UpsertSubscription(
            new UpsertSubscriptionRequest(42, "sub-other", DateTimeOffset.UtcNow.AddDays(90), "OTHER"),
            default);

        Assert.IsType<OkResult>(result);
        var account = await db.Accounts.AsNoTracking().SingleAsync();
        Assert.Equal("sub-active", account.CurrentSubscriptionId);
        Assert.Equal("CODE-sub-active", account.CurrentKeyCode);
        // The other key's 90 days must not become the active key's expiry.
        Assert.True(account.ExpiresAt < DateTimeOffset.UtcNow.AddDays(11));
    }

    [Fact]
    public async Task UpsertSubscription_ExtendingTheActiveKey_UpdatesExpiry()
    {
        using var db = TestHelpers.NewDb();
        db.Accounts.Add(Seeded(db, "sub-active"));
        await db.SaveChangesAsync();

        var extended = DateTimeOffset.UtcNow.AddDays(40);
        await new InternalAccountController(db).UpsertSubscription(
            new UpsertSubscriptionRequest(42, "sub-active", extended), default);

        var account = await db.Accounts.AsNoTracking().SingleAsync();
        Assert.True(account.ExpiresAt > DateTimeOffset.UtcNow.AddDays(39));
    }

    [Fact]
    public async Task UpsertSubscription_MakeActive_SwitchesTheApp()
    {
        // "Поменять ключ" and a purchase the user was routed into from the app
        // are explicit choices, and do switch.
        using var db = TestHelpers.NewDb();
        db.Accounts.Add(Seeded(db, "sub-active"));
        await db.SaveChangesAsync();

        await new InternalAccountController(db).UpsertSubscription(
            new UpsertSubscriptionRequest(42, "sub-new", DateTimeOffset.UtcNow.AddDays(30), "NEWCODE",
                MakeActive: true),
            default);

        var account = await db.Accounts.AsNoTracking().SingleAsync();
        Assert.Equal("sub-new", account.CurrentSubscriptionId);
        Assert.Equal("NEWCODE", account.CurrentKeyCode);
    }

    [Fact]
    public async Task UpsertSubscription_AccountWithNoKeyYet_AdoptsTheFirstOne()
    {
        // Bootstrap: the very first thing the bot says about a new user has to
        // land, or the account sits there with no subscription at all.
        using var db = TestHelpers.NewDb();

        await new InternalAccountController(db).UpsertSubscription(
            new UpsertSubscriptionRequest(7, "sub-first", DateTimeOffset.UtcNow.AddDays(30)), default);

        var account = await db.Accounts.AsNoTracking().SingleAsync();
        Assert.Equal("sub-first", account.CurrentSubscriptionId);
    }

    [Fact]
    public async Task UpsertSubscription_ReplacingTheActiveKey_MovesTheApp()
    {
        // "Поменять ключ" deletes the panel user and mints a fresh shortUuid, so
        // the app has to follow — but only because it was on the key that got
        // replaced, not because a key changed somewhere.
        using var db = TestHelpers.NewDb();
        db.Accounts.Add(Seeded(db, "sub-old"));
        await db.SaveChangesAsync();

        await new InternalAccountController(db).UpsertSubscription(
            new UpsertSubscriptionRequest(42, "sub-fresh", DateTimeOffset.UtcNow.AddDays(10), "NEWCODE",
                ReplacesSubscriptionId: "sub-old"),
            default);

        var account = await db.Accounts.AsNoTracking().SingleAsync();
        Assert.Equal("sub-fresh", account.CurrentSubscriptionId);
    }

    [Fact]
    public async Task UpsertSubscription_ReplacingSomeOtherKey_LeavesTheAppWhereItIs()
    {
        using var db = TestHelpers.NewDb();
        db.Accounts.Add(Seeded(db, "sub-active"));
        await db.SaveChangesAsync();

        await new InternalAccountController(db).UpsertSubscription(
            new UpsertSubscriptionRequest(42, "sub-fresh", DateTimeOffset.UtcNow.AddDays(10), null,
                ReplacesSubscriptionId: "sub-somebody-elses"),
            default);

        var account = await db.Accounts.AsNoTracking().SingleAsync();
        Assert.Equal("sub-active", account.CurrentSubscriptionId);
    }

    [Fact]
    public async Task UpsertSubscription_ActiveKeyAlreadyLapsed_AdoptsTheNewOne()
    {
        // Let a key run out, then buy another: the app is on the renew screen
        // because of the dead one, so there is nothing left to protect.
        using var db = TestHelpers.NewDb();
        var lapsed = Seeded(db, "sub-dead");
        lapsed.ExpiresAt = DateTimeOffset.UtcNow.AddDays(-3);
        db.Accounts.Add(lapsed);
        await db.SaveChangesAsync();

        await new InternalAccountController(db).UpsertSubscription(
            new UpsertSubscriptionRequest(42, "sub-bought", DateTimeOffset.UtcNow.AddDays(30), "BOUGHT"),
            default);

        var account = await db.Accounts.AsNoTracking().SingleAsync();
        Assert.Equal("sub-bought", account.CurrentSubscriptionId);
        Assert.Equal("BOUGHT", account.CurrentKeyCode);
    }

    [Fact]
    public async Task RegisterToken_WithTelegramUserId_LinksTheKeyWithoutChoosingIt()
    {
        // Handing the user a code to look at is not the user picking it — the
        // choice happens when they paste it into the app.
        using var db = TestHelpers.NewDb();
        db.Accounts.Add(Seeded(db, "sub-active"));
        await db.SaveChangesAsync();

        var result = await new InternalTokensController(db).RegisterToken(
            new RegisterTokenRequest("NEWKEY", "sub-other", DateTimeOffset.UtcNow.AddDays(30), 42),
            default);

        Assert.Equal(201, Assert.IsType<StatusCodeResult>(result).StatusCode);
        var account = await db.Accounts.AsNoTracking().SingleAsync();
        Assert.Equal("sub-active", account.CurrentSubscriptionId);
        var token = await db.Tokens.AsNoTracking().SingleAsync();
        Assert.Equal(account.Id, token.AccountId);
    }

    [Fact]
    public async Task RegisterToken_FirstKeyOfAnUnknownUser_CreatesTheAccount()
    {
        using var db = TestHelpers.NewDb();

        await new InternalTokensController(db).RegisterToken(
            new RegisterTokenRequest("K", "sub-1", DateTimeOffset.UtcNow.AddDays(30), 99), default);

        var account = await db.Accounts.AsNoTracking().SingleAsync();
        Assert.Equal(99, account.TelegramUserId);
        Assert.Equal(account.Id, (await db.Tokens.AsNoTracking().SingleAsync()).AccountId);
    }

    [Fact]
    public async Task RegisterToken_WithoutTelegramUserId_LeavesTheKeyUnbound()
    {
        // A bot build that predates the field must keep working exactly as before.
        using var db = TestHelpers.NewDb();

        await new InternalTokensController(db).RegisterToken(
            new RegisterTokenRequest("K", "sub-1", DateTimeOffset.UtcNow.AddDays(30)), default);

        Assert.Null((await db.Tokens.AsNoTracking().SingleAsync()).AccountId);
        Assert.Empty(db.Accounts);
    }
}
