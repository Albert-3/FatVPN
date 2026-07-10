using System.Text;

namespace FatVpn.Bff.Infrastructure.Remnawave;

/// <summary>
/// PoC: Remnawave omits our Hysteria2 nodes (FR/US/FI "H2") from the subscription
/// output — they run as an Xray-hysteria plugin, not xray-core, so the panel's
/// subscription generator skips them in every format (base64, sing-box, clash).
/// The app therefore never sees them. Here we synthesize <c>hysteria2://</c> links
/// and append them to the base64 subscription so the sing-box tunnel can use them.
///
/// The per-user auth for these Hysteria inbounds is the user's vless UUID, which is
/// already present in every <c>vless://</c> line of the subscription — so we lift it
/// from the config itself and need no extra Remnawave call. Params (host/sni/alpn)
/// were read from the panel's Happ (xray-json) render of these same nodes.
/// </summary>
public static class SubscriptionAugmenter
{
    // Hysteria2 hosts Remnawave won't render. Kept in code for the PoC; a later
    // pass can fetch these from /api/hosts filtered to hysteria inbounds.
    private static readonly (string Host, int Port, string Name)[] HysteriaHosts =
    [
        ("h2-fr.arpozan.cloud", 443, "\U0001F1EB\U0001F1F7 Франция • H2"),
        ("h3-us.arpozan.cloud", 443, "\U0001F1FA\U0001F1F8 США • H2"),
        ("h1-fi.arpozan.cloud", 443, "\U0001F1EB\U0001F1EE Финляндия • H2"),
    ];

    /// <summary>
    /// Appends synthesized hysteria2:// links to a base64 v2ray subscription.
    /// Returns the input unchanged when it isn't base64 or has no vless line to
    /// derive the auth from, so a non-standard/empty config is never corrupted.
    /// </summary>
    public static string AppendHysteriaHosts(string base64Config)
    {
        if (string.IsNullOrWhiteSpace(base64Config)) return base64Config;

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
        foreach (var (host, port, name) in HysteriaHosts)
        {
            var tag = Uri.EscapeDataString(name);
            sb.Append('\n')
              .Append($"hysteria2://{auth}@{host}:{port}?sni={host}&alpn=h3#{tag}");
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
