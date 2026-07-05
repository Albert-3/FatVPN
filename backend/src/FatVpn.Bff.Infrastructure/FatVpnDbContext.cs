using FatVpn.Bff.Domain;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Infrastructure;

public class FatVpnDbContext(DbContextOptions<FatVpnDbContext> options) : DbContext(options)
{
    public DbSet<Device> Devices => Set<Device>();
    public DbSet<Trial> Trials => Set<Trial>();
    public DbSet<Token> Tokens => Set<Token>();
    public DbSet<TrialSubscriptionSlot> TrialSubscriptionSlots => Set<TrialSubscriptionSlot>();
    public DbSet<Account> Accounts => Set<Account>();
    public DbSet<PairingCode> PairingCodes => Set<PairingCode>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Device>().HasIndex(d => d.DeviceKeyHash).IsUnique();
        modelBuilder.Entity<Token>().HasIndex(t => t.ShortToken).IsUnique();
        modelBuilder.Entity<TrialSubscriptionSlot>().HasIndex(s => s.RemnawaveSubscriptionId).IsUnique();
        modelBuilder.Entity<Account>().HasIndex(a => a.TelegramUserId).IsUnique();
        modelBuilder.Entity<PairingCode>().HasIndex(p => p.Code).IsUnique();
        modelBuilder.Entity<PairingCode>().HasIndex(p => p.PollToken).IsUnique();
    }
}
