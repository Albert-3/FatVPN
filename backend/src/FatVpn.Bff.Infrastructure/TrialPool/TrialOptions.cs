namespace FatVpn.Bff.Infrastructure.TrialPool;

public sealed class TrialOptions
{
    public int DurationDays { get; set; } = 3;

    /// When greater than zero, the trial lasts this many minutes instead of
    /// <see cref="DurationDays"/>. Intended for short-lived test trials.
    public int DurationMinutes { get; set; }

    public string DeviceKeySalt { get; set; } = string.Empty;
}
