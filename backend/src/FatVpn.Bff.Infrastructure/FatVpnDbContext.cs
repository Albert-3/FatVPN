using FatVpn.Bff.Domain;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;

namespace FatVpn.Bff.Infrastructure;

public class FatVpnDbContext(DbContextOptions<FatVpnDbContext> options) : DbContext(options)
{
    public DbSet<Device> Devices => Set<Device>();
    public DbSet<Trial> Trials => Set<Trial>();
    public DbSet<Token> Tokens => Set<Token>();
    public DbSet<TokenDevice> TokenDevices => Set<TokenDevice>();
    public DbSet<TrialSubscriptionSlot> TrialSubscriptionSlots => Set<TrialSubscriptionSlot>();
    public DbSet<Account> Accounts => Set<Account>();
    public DbSet<PairingCode> PairingCodes => Set<PairingCode>();
    public DbSet<RefreshToken> RefreshTokens => Set<RefreshToken>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Device>().HasIndex(d => d.DeviceKeyHash).IsUnique();
        modelBuilder.Entity<Token>().HasIndex(t => t.ShortToken).IsUnique();
        modelBuilder.Entity<TrialSubscriptionSlot>().HasIndex(s => s.RemnawaveSubscriptionId).IsUnique();
        modelBuilder.Entity<Account>().HasIndex(a => a.TelegramUserId).IsUnique();
        modelBuilder.Entity<PairingCode>().HasIndex(p => p.Code).IsUnique();
        modelBuilder.Entity<PairingCode>().HasIndex(p => p.PollToken).IsUnique();
        modelBuilder.Entity<RefreshToken>().HasIndex(r => r.TokenHash).IsUnique();

        // The device cap, enforced by the database rather than by a count-then-
        // insert: only one device can hold a given slot of a given key, and a
        // device can hold only one slot. Racing redemptions block on these and
        // then see the winner's committed row, so the outcome doesn't depend on
        // who read first.
        modelBuilder.Entity<TokenDevice>().HasIndex(d => new { d.SubscriptionId, d.SlotIndex }).IsUnique();
        modelBuilder.Entity<TokenDevice>().HasIndex(d => new { d.SubscriptionId, d.DeviceKeyHash }).IsUnique();

        // RefreshTokens is the fastest-growing table (one row per /auth/refresh,
        // ~48/device/day). Without these, revoking a session family and the
        // nightly cleanup both sequentially scan it.
        modelBuilder.Entity<RefreshToken>().HasIndex(r => new { r.AccountId, r.RevokedAt });
        modelBuilder.Entity<RefreshToken>().HasIndex(r => new { r.FamilyId, r.RevokedAt });
        modelBuilder.Entity<RefreshToken>().HasIndex(r => new { r.TokenId, r.RevokedAt });
        modelBuilder.Entity<RefreshToken>().HasIndex(r => r.ExpiresAt);
        // Evicting a device ends its sessions, which asks this table "whose are
        // these" — the one lookup here that isn't by token, family or account.
        modelBuilder.Entity<RefreshToken>().HasIndex(r => new { r.DeviceKeyHash, r.RevokedAt });

        // One trial per device, enforced by the database rather than by a
        // read-then-write: without it a racing pair of /trial calls leaves two
        // rows, and SingleOrDefaultAsync then throws forever for that device.
        modelBuilder.Entity<Trial>().HasIndex(t => t.DeviceId).IsUnique();

        modelBuilder.Entity<PairingCode>().HasIndex(p => p.ExpiresAt);

        // Npgsql refuses to write a DateTimeOffset with a non-zero offset into a
        // timestamptz column. Every timestamp we take from outside — the bot sends
        // Moscow time, the panel sends its own — would otherwise throw at
        // SaveChanges and surface as a 500. Normalise on the way in, once, for
        // every entity, so a future write path can't reintroduce it.
        var toUtc = new ValueConverter<DateTimeOffset, DateTimeOffset>(
            v => v.ToUniversalTime(), v => v);
        var toUtcNullable = new ValueConverter<DateTimeOffset?, DateTimeOffset?>(
            v => v == null ? null : v.Value.ToUniversalTime(), v => v);

        foreach (var entityType in modelBuilder.Model.GetEntityTypes())
        {
            foreach (var property in entityType.GetProperties())
            {
                if (property.ClrType == typeof(DateTimeOffset))
                {
                    property.SetValueConverter(toUtc);
                }
                else if (property.ClrType == typeof(DateTimeOffset?))
                {
                    property.SetValueConverter(toUtcNullable);
                }
            }
        }
    }
}
