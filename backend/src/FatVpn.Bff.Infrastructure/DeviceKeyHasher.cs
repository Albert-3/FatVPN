using System.Security.Cryptography;
using System.Text;

namespace FatVpn.Bff.Infrastructure;

/// <summary>Salted SHA-256 of a device's per-install key. Shared by trial
/// anti-abuse (one trial per device) and subscription-key binding (one key per
/// phone) so both compute the hash identically.</summary>
public static class DeviceKeyHasher
{
    public static string Compute(string attestationToken, string salt)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(salt + attestationToken));
        return Convert.ToHexString(hash);
    }
}
