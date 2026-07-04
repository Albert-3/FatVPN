using System.Security.Cryptography;
using System.Text;

namespace FatVpn.Bff.Api.Auth;

public static class BotSecretValidator
{
    public const string HeaderName = "X-Bot-Secret";

    public static bool IsValid(string? provided, string? expected)
    {
        if (string.IsNullOrEmpty(provided) || string.IsNullOrEmpty(expected) || provided.Length != expected.Length)
        {
            return false;
        }

        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(provided),
            Encoding.UTF8.GetBytes(expected));
    }
}
