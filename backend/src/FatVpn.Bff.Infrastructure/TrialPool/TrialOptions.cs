namespace FatVpn.Bff.Infrastructure.TrialPool;

public sealed class TrialOptions
{
    public int DurationDays { get; set; } = 3;
    public string DeviceKeySalt { get; set; } = string.Empty;
}
