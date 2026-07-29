namespace FatVpn.Bff.Domain;

public enum PairingStatus
{
    Pending = 0,
    Completed = 1,

    /// <summary>The app has polled once after completion and received its session
    /// tokens. Terminal: the code is single-use, so a later poll can't re-mint a
    /// session (which would accumulate refresh tokens and hand out parallel logins).</summary>
    Consumed = 2,
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

    /// <summary>
    /// Salted hash of the attestation token of the phone that started this
    /// attempt, carried from /pair/start so /pair/status can charge the session
    /// to a device slot. Without it pairing was a way onto a subscription that
    /// the device cap could not see, and pressing "Подключить через Telegram"
    /// connected any number of phones. Null for app builds that send nothing,
    /// which pair exactly as they did before.
    /// </summary>
    public string? DeviceKeyHash { get; set; }
}
