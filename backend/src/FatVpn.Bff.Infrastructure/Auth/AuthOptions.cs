namespace FatVpn.Bff.Infrastructure.Auth;

public sealed class AuthOptions
{
    /// <summary>
    /// How many distinct devices may redeem the same key at <c>/auth/token</c>.
    /// A device that already holds a slot can re-enter its key as often as it
    /// likes; only a new one consumes capacity. Pairing through the bot is not
    /// counted — this governs the pasted-code path alone.
    /// </summary>
    public int MaxDevicesPerKey { get; set; } = 3;
}
