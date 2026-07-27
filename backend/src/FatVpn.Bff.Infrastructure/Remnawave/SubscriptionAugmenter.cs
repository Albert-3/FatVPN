using System.Text;

namespace FatVpn.Bff.Infrastructure.Remnawave;

/// <summary>
/// Remnawave omits our Hysteria2 nodes (FR/US/FI "H2") from the subscription formats
/// the app consumes — they run as an Xray-hysteria plugin, so the panel's generator
/// skips them in base64, sing-box and clash alike (its xray-json/Happ render is the
/// one format that does include them). The app would therefore never see them. Here
/// we synthesize <c>hysteria2://</c> links and append them to the base64 subscription
/// so the sing-box tunnel can use them.
///
/// The per-user auth for these Hysteria inbounds is the user's vless UUID, which is
/// already present in every <c>vless://</c> line of the subscription — so we lift it
/// from the config itself and need no extra Remnawave call. Verified 2026-07-27
/// against the panel's own xray-json render: its <c>hysteriaSettings.auth</c> equals
/// that user's vless UUID. Params (host/sni/alpn) come from the same render.
/// </summary>
public static class SubscriptionAugmenter
{
    // The hosts come from configuration (RemnawaveOptions.HysteriaHosts) rather
    // than the panel: it exposes them only through /api/hosts joined to a config
    // profile, which would be an extra round trip on every /config.
    private static readonly HysteriaHostOptions[] DefaultHosts = new RemnawaveOptions().HysteriaHosts;

    /// <summary>
    /// Appends synthesized hysteria2:// links to a base64 v2ray subscription.
    /// Returns the input unchanged when it isn't base64 or has no vless line to
    /// derive the auth from, so a non-standard/empty config is never corrupted.
    /// </summary>
    public static string AppendHysteriaHosts(string base64Config, IReadOnlyList<HysteriaHostOptions>? hosts = null)
    {
        if (string.IsNullOrWhiteSpace(base64Config)) return base64Config;

        var hysteriaHosts = hosts is { Count: > 0 } ? hosts : DefaultHosts;

        string decoded;
        try
        {
            // Strip any whitespace/newlines and fix padding before decoding.
            var compact = new string(base64Config.Where(c => !char.IsWhiteSpace(c)).ToArray());
            compact = compact.PadRight((compact.Length + 3) / 4 * 4, '=');
            decoded = Encoding.UTF8.GetString(Convert.FromBase64String(compact));
        }
        catch (FormatException)
        {
            return base64Config;
        }

        var auth = ExtractVlessUuid(decoded);
        if (auth is null) return base64Config;

        var sb = new StringBuilder(decoded.TrimEnd('\n'));
        foreach (var entry in hysteriaHosts)
        {
            var tag = Uri.EscapeDataString(entry.Name);
            sb.Append('\n')
              .Append($"hysteria2://{auth}@{entry.Host}:{entry.Port}?sni={entry.Host}&alpn=h3#{tag}");
        }

        return Convert.ToBase64String(Encoding.UTF8.GetBytes(sb.ToString()));
    }

    // The vless UUID (used as the hysteria2 password) is the userinfo of any
    // vless:// line: vless://<uuid>@host:port?...
    private static string? ExtractVlessUuid(string config)
    {
        foreach (var raw in config.Split('\n'))
        {
            var line = raw.Trim();
            if (!line.StartsWith("vless://", StringComparison.OrdinalIgnoreCase)) continue;
            var rest = line["vless://".Length..];
            var at = rest.IndexOf('@');
            if (at <= 0) continue;
            var uuid = rest[..at];
            if (!string.IsNullOrWhiteSpace(uuid)) return uuid;
        }
        return null;
    }
}
