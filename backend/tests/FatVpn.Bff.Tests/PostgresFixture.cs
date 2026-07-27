using FatVpn.Bff.Infrastructure;
using Microsoft.EntityFrameworkCore;
using Testcontainers.PostgreSql;
using Xunit;

namespace FatVpn.Bff.Tests;

/// <summary>
/// A real PostgreSQL for the tests that only mean something on one: concurrent
/// requests hitting the same row. The unit suite runs on SQLite, which is a
/// single connection and therefore cannot race with itself, and the EF InMemory
/// provider it replaced could not even express these statements.
/// </summary>
public sealed class PostgresFixture : IAsyncLifetime
{
    private PostgreSqlContainer? _container;

    /// <summary>Null when Docker isn't running; the tests skip rather than fail,
    /// so `dotnet test` stays useful on a machine without it.</summary>
    public string? ConnectionString { get; private set; }

    public async Task InitializeAsync()
    {
        try
        {
            _container = new PostgreSqlBuilder()
                .WithImage("postgres:16")
                .Build();
            await _container.StartAsync();
            ConnectionString = _container.GetConnectionString();

            await using var db = NewDbCore();
            await db.Database.MigrateAsync();
        }
        catch (Exception)
        {
            ConnectionString = null;
        }
    }

    public async Task DisposeAsync()
    {
        if (_container is not null)
        {
            await _container.DisposeAsync();
        }
    }

    /// <summary>
    /// A fresh context per caller — each concurrent request in production gets
    /// its own scoped DbContext, and sharing one here would serialise the very
    /// thing under test.
    /// </summary>
    public FatVpnDbContext NewDb() => NewDbCore();

    private FatVpnDbContext NewDbCore()
    {
        var options = new DbContextOptionsBuilder<FatVpnDbContext>()
            .UseNpgsql(ConnectionString)
            .Options;
        return new FatVpnDbContext(options);
    }

    /// <summary>Wipes the tables between tests; the container is shared for speed.</summary>
    public async Task ResetAsync()
    {
        await using var db = NewDbCore();
        await db.Database.ExecuteSqlRawAsync(
            """TRUNCATE "RefreshTokens", "PairingCodes", "Accounts", "Trials", "Devices", "Tokens" CASCADE;""");
    }
}

[CollectionDefinition(Name)]
public sealed class PostgresCollection : ICollectionFixture<PostgresFixture>
{
    public const string Name = "postgres";
}
