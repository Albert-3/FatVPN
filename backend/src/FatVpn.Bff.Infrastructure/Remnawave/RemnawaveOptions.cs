namespace FatVpn.Bff.Infrastructure.Remnawave;

public sealed class RemnawaveOptions
{
    public string BaseUrl { get; set; } = string.Empty;
    public string ApiToken { get; set; } = string.Empty;

    /// Internal squad new trial users are added to so their subscription
    /// carries the node inbounds. Defaults to this install's "Default-Squad";
    /// override via config if the panel's squad changes.
    public string TrialSquadUuid { get; set; } = "d8269461-864e-440c-b504-65e5e5478b7a";

    /// <summary>
    /// Whether to splice synthesized <c>hysteria2://</c> links for the FR/US/FI
    /// "H2" hosts into the subscription (see <see cref="SubscriptionAugmenter"/>).
    /// </summary>
    /// <remarks>
    /// Off by default: the links were never verified end to end and, on device,
    /// the FR and US entries connect the tunnel but pass no traffic at all. The
    /// app reports "connected" from the OS tunnel status, which comes up whether
    /// or not sing-box ever reached the server — so a broken outbound looks
    /// exactly like a working one, and the user just has no internet. Serving no
    /// Hysteria entry is strictly better than serving a dead one.
    ///
    /// Turn this back on once a synthesized link is confirmed to carry traffic.
    /// Two things are unproven: that the per-user password really is the vless
    /// UUID (the panel's config profile carries an empty <c>clients</c> array and
    /// injects credentials onto the node at runtime), and that sing-box's
    /// standard hysteria2 outbound is wire-compatible with these inbounds, which
    /// are Xray's <c>"protocol": "hysteria"</c> plugin wrapped in a non-standard
    /// <c>finalmask</c> QUIC layer.
    /// </remarks>
    public bool AugmentHysteria { get; set; }
}
