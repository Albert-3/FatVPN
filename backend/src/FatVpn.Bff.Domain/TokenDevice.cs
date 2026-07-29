namespace FatVpn.Bff.Domain;

/// <summary>
/// One device holding one of a subscription's slots. A subscription may be used
/// by up to <c>Auth:MaxDevicesPerKey</c> distinct devices, whichever way they
/// connected — pasting a code or pairing through the bot.
///
/// Slots hang off the subscription rather than off the <see cref="Token"/> row
/// that carries a code, because those are not the same thing: one subscription
/// accumulates a new code row every time the bot shows the user their key, and
/// while slots were keyed by code, four codes meant twelve devices. Pairing,
/// which has no code row at all, escaped the cap entirely.
///
/// Admission is decided by the two unique indexes rather than by counting rows:
/// a device claims the lowest free <see cref="SlotIndex"/>, and racing inserts
/// are ordered by the database. Counting first and inserting after cannot do
/// that — every racer reads "room for one more" at the same instant.
/// </summary>
public class TokenDevice
{
    public Guid Id { get; set; }

    /// The Remnawave subscription these devices share — the thing a user calls
    /// "my key", as opposed to any one code that hands it out.
    public string SubscriptionId { get; set; } = string.Empty;

    /// Which of the subscription's slots this device holds, from zero. Unique per
    /// subscription — this is what caps the number of devices.
    public int SlotIndex { get; set; }

    /// <summary>
    /// Salted hash of the device's attestation token — the same identity the
    /// trial anti-abuse uses (<see cref="Device.DeviceKeyHash"/>). Unique per
    /// subscription, so one device can never occupy two slots.
    /// </summary>
    public string DeviceKeyHash { get; set; } = string.Empty;

    public DateTimeOffset BoundAt { get; set; }

    /// <summary>
    /// Last time this device was heard from — set on every session refresh, so a
    /// phone in daily use keeps moving forward while one left in a drawer does
    /// not. A fourth device evicts whichever slot has the oldest value, which is
    /// the difference between "the phone I sold" and "the phone I use". Rows
    /// written before this column existed carry their <see cref="BoundAt"/>.
    /// </summary>
    public DateTimeOffset LastSeenAt { get; set; }
}
