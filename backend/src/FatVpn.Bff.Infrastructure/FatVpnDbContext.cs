using FatVpn.Bff.Domain;
using Microsoft.EntityFrameworkCore;

namespace FatVpn.Bff.Infrastructure;

public class FatVpnDbContext(DbContextOptions<FatVpnDbContext> options) : DbContext(options)
{
    public DbSet<Device> Devices => Set<Device>();
    public DbSet<Trial> Trials => Set<Trial>();
    public DbSet<Token> Tokens => Set<Token>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Device>().HasIndex(d => d.DeviceKeyHash).IsUnique();
        modelBuilder.Entity<Token>().HasIndex(t => t.ShortToken).IsUnique();
    }
}
