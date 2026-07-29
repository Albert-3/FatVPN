namespace FatVpn.Bff.Domain;

/// <summary>
/// One device holding one of a key's slots. A key may be redeemed by up to
/// <c>Auth:MaxDevicesPerKey</c> distinct devices; the set is cleared when the
/// bot reissues the key.
///
/// Admission is decided by the two unique indexes rather than by counting rows:
/// a device claims the lowest free <see cref="SlotIndex"/>, and racing inserts
/// are ordered by the database. Counting first and inserting after cannot do
/// that — every racer reads "room for one more" at the same instant.
/// </summary>
public class TokenDevice
{
    public Guid Id { get; set; }
    public Guid TokenId { get; set; }

    /// Which of the key's slots this device holds, from zero. Unique per key —
    /// this is what caps the number of devices.
    public int SlotIndex { get; set; }

    /// Salted hash of the device's attestation token — the same identity the
    /// trial anti-abuse uses (<see cref="Device.DeviceKeyHash"/>). Unique per
    /// key, so one device can never occupy two slots.
    public string DeviceKeyHash { get; set; } = string.Empty;

    public DateTimeOffset BoundAt { get; set; }
}
