using System.Security.Cryptography;

namespace FatVpn.Bff.Api.Pairing;

public static class PairingCodeGenerator
{
    // Crockford-ish base32 without ambiguous chars (no I, O, 0, 1) — the code
    // travels into a t.me/bot?start=pair<CODE> link and may be read/typed by hand.
    private const string CodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

    public static string NewCode() =>
        RandomNumberGenerator.GetString(CodeAlphabet, 8);

    // Device-held secret the app polls with; never shared, so keep it long.
    public static string NewPollToken() =>
        Convert.ToHexString(RandomNumberGenerator.GetBytes(24));
}
