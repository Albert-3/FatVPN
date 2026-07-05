namespace FatVpn.Bff.Domain;

public enum PairingStatus
{
    Pending = 0,
    Completed = 1,
}

/// <summary>
/// One pairing attempt started by the app. <see cref="Code"/> travels into the
/// Telegram deep link (t.me/bot?start=pair&lt;Code&gt;) and is redeemed by the bot
/// via /internal/pair/complete. <see cref="PollToken"/> is the device-held secret
/// the app polls with to receive its JWT once the bot completes pairing.
/// </summary>
public class PairingCode
{
    public Guid Id { get; set; }
    public string Code { get; set; } = string.Empty;
    public string PollToken { get; set; } = string.Empty;
    public Guid? AccountId { get; set; }
    public PairingStatus Status { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
}
