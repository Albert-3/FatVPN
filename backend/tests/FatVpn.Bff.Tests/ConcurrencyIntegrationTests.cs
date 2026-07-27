using FatVpn.Bff.Api.Controllers;
using FatVpn.Bff.Domain;
using FatVpn.Bff.Infrastructure.Remnawave;
using FatVpn.Bff.Infrastructure.TrialPool;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace FatVpn.Bff.Tests;

/// <summary>
/// The races the audit found (B1, B2, B5, B6, B10). Each one used to hand out a
/// second session, a second trial, or a duplicate row; none of them is
/// observable on a single-connection test database, which is why they survived
/// a green suite for so long.
/// </summary>
[Collection(PostgresCollection.Name)]
public class ConcurrencyIntegrationTests(PostgresFixture postgres)
{
    private const int Racers = 8;

    private void RequireDocker()
        => Skip.If(postgres.ConnectionString is null, "Docker is not available; skipping the PostgreSQL integration tests.");

    private PairController NewPairController()
        => new(postgres.NewDb(), TestHelpers.JwtService(), TestHelpers.RefreshService());

    private AuthController NewAuthController()
        => new(postgres.NewDb(), TestHelpers.JwtService(), TestHelpers.RefreshService(),
               TestHelpers.Opt(new TrialOptions { DeviceKeySalt = "salt" }),
               TestHelpers.Opt(TestHelpers.Jwt()),
               NullLogger<AuthController>.Instance);

    private TrialController NewTrialController()
        => new(postgres.NewDb(), TestHelpers.JwtService(), TestHelpers.RefreshService(),
               new FakeRemnawaveClient
               {
                   OnCreateTrial = expiry => new RemnawaveTrialUser($"sub-{Guid.NewGuid():N}"[..12], expiry, Guid.NewGuid().ToString()),
               },
               TestHelpers.Opt(new TrialOptions { DurationDays = 2, DeviceKeySalt = "salt" }),
               NullLogger<TrialController>.Instance);

    [SkippableFact]
    public async Task PairStatus_PolledConcurrently_MintsExactlyOneSession()
    {
        RequireDocker();
        await postgres.ResetAsync();

        var accountId = Guid.NewGuid();
        await using (var seed = postgres.NewDb())
        {
            seed.Accounts.Add(new Account { Id = accountId, ExpiresAt = DateTimeOffset.UtcNow.AddDays(30) });
            seed.PairingCodes.Add(new PairingCode
            {
                Id = Guid.NewGuid(), Code = "RACE01", PollToken = "race-poll",
                Status = PairingStatus.Completed, AccountId = accountId,
                CreatedAt = DateTimeOffset.UtcNow, ExpiresAt = DateTimeOffset.UtcNow.AddMinutes(10),
            });
            await seed.SaveChangesAsync();
        }

        var results = await Task.WhenAll(Enumerable.Range(0, Racers)
            .Select(_ => NewPairController().Status("race-poll", default)));

        var completed = results.Count(r => r is OkObjectResult ok && Status(ok) == "completed");
        Assert.Equal(1, completed);

        await using var db = postgres.NewDb();
        Assert.Equal(1, await db.RefreshTokens.CountAsync());
        Assert.Equal(PairingStatus.Consumed, (await db.PairingCodes.SingleAsync()).Status);
    }

    [SkippableFact]
    public async Task Refresh_CalledConcurrently_LeavesTheFamilyIntact()
    {
        RequireDocker();
        await postgres.ResetAsync();

        var refreshSvc = TestHelpers.RefreshService();
        var accountId = Guid.NewGuid();
        var (raw, entity) = refreshSvc.Create(accountId, null);
        await using (var seed = postgres.NewDb())
        {
            seed.Accounts.Add(new Account { Id = accountId, ExpiresAt = DateTimeOffset.UtcNow.AddDays(30) });
            seed.RefreshTokens.Add(entity);
            await seed.SaveChangesAsync();
        }

        // The app fires these when several requests hit 401 at once.
        var results = await Task.WhenAll(Enumerable.Range(0, Racers)
            .Select(_ => NewAuthController().Refresh(new RefreshRequest(raw), default)));

        // Every caller is served — the grace window is what stops the losers from
        // tripping reuse-detection — and nothing revokes the family.
        Assert.All(results, r => Assert.IsType<OkObjectResult>(r));

        await using var db = postgres.NewDb();
        var presented = await db.RefreshTokens.SingleAsync(r => r.Id == entity.Id);
        Assert.NotNull(presented.RevokedAt); // rotated out exactly once
        Assert.Equal(Racers, await db.RefreshTokens.CountAsync(r => r.RevokedAt == null));
    }

    [SkippableFact]
    public async Task Refresh_ReuseOutsideTheGraceWindow_StillRevokesTheFamily()
    {
        RequireDocker();
        await postgres.ResetAsync();

        var refreshSvc = TestHelpers.RefreshService();
        var accountId = Guid.NewGuid();
        var (raw, stale) = refreshSvc.Create(accountId, null);
        stale.RevokedAt = DateTimeOffset.UtcNow.AddMinutes(-10);
        var (_, live) = refreshSvc.Create(accountId, null);
        await using (var seed = postgres.NewDb())
        {
            seed.Accounts.Add(new Account { Id = accountId, ExpiresAt = DateTimeOffset.UtcNow.AddDays(30) });
            seed.RefreshTokens.AddRange(stale, live);
            await seed.SaveChangesAsync();
        }

        Assert.IsType<UnauthorizedResult>(
            await NewAuthController().Refresh(new RefreshRequest(raw), default));

        await using var db = postgres.NewDb();
        Assert.False(await db.RefreshTokens.AnyAsync(r => r.RevokedAt == null));
    }

    [SkippableFact]
    public async Task Trial_RequestedConcurrently_GrantsExactlyOne()
    {
        RequireDocker();
        await postgres.ResetAsync();

        var deviceKey = new string('a', 40);
        var results = await Task.WhenAll(Enumerable.Range(0, Racers)
            .Select(_ => NewTrialController().GrantTrial(new TrialRequest(deviceKey, "android"), default)));

        // Losers either resume the winner's trial or get a 409 — never a second one.
        Assert.All(results, r => Assert.True(r is OkObjectResult or ConflictResult,
            $"unexpected {r.GetType().Name}"));

        await using var db = postgres.NewDb();
        Assert.Equal(1, await db.Devices.CountAsync());
        Assert.Equal(1, await db.Trials.CountAsync());
    }

    [SkippableFact]
    public async Task ExchangeToken_TwoDevicesRaceOneKey_OnlyOneBinds()
    {
        RequireDocker();
        await postgres.ResetAsync();

        await using (var seed = postgres.NewDb())
        {
            seed.Tokens.Add(new Token
            {
                Id = Guid.NewGuid(), ShortToken = "RACEKEY",
                RemnawaveSubscriptionId = "sub", ExpiresAt = DateTimeOffset.UtcNow.AddDays(30),
                CreatedAt = DateTimeOffset.UtcNow,
            });
            await seed.SaveChangesAsync();
        }

        var results = await Task.WhenAll(Enumerable.Range(0, Racers).Select(i =>
            NewAuthController().ExchangeToken(
                new ExchangeTokenRequest("RACEKEY", $"device-{i}-{new string('x', 20)}"), default)));

        Assert.Equal(1, results.Count(r => r is OkObjectResult));
        Assert.Equal(Racers - 1, results.Count(r => r is ConflictResult));
    }

    [SkippableFact]
    public async Task AccountUpsert_RacedByPairAndSubscription_CreatesOneAccount()
    {
        RequireDocker();
        await postgres.ResetAsync();

        const long telegramUserId = 987654;
        var expiry = DateTimeOffset.UtcNow.AddDays(30);

        // "Bought a key and paired immediately": both bot calls land together.
        var tasks = Enumerable.Range(0, Racers).Select(async _ =>
        {
            await using var db = postgres.NewDb();
            var controller = new InternalAccountController(db);
            return await controller.UpsertSubscription(
                new UpsertSubscriptionRequest(telegramUserId, "sub-1", expiry), default);
        });

        var results = await Task.WhenAll(tasks);
        Assert.All(results, r => Assert.IsType<OkResult>(r));

        await using var db = postgres.NewDb();
        Assert.Equal(1, await db.Accounts.CountAsync());
    }

    [SkippableFact]
    public async Task BotTimestampWithOffset_IsStoredWithoutThrowing()
    {
        RequireDocker();
        await postgres.ResetAsync();

        // The Python bot sends Moscow time. Npgsql accepts a timestamptz only
        // with a zero offset, so this used to be a 500 on every key purchase.
        var moscow = new DateTimeOffset(2026, 8, 1, 0, 0, 0, TimeSpan.FromHours(3));

        await using (var db = postgres.NewDb())
        {
            var result = await new InternalAccountController(db).UpsertSubscription(
                new UpsertSubscriptionRequest(555, "sub-tz", moscow), default);
            Assert.IsType<OkResult>(result);
        }

        await using var verify = postgres.NewDb();
        var account = await verify.Accounts.SingleAsync();
        Assert.Equal(moscow.ToUniversalTime(), account.ExpiresAt.ToUniversalTime());
    }

    private static string Status(OkObjectResult ok)
        => System.Text.Json.JsonSerializer.Serialize(ok.Value).Contains("\"status\":\"completed\"")
            ? "completed"
            : "other";
}
