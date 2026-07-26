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
    /// On by default since 2026-07-27, when both open questions were settled
    /// against the live panel and real nodes:
    ///
    /// 1. <b>The password really is the vless UUID.</b> The config profile keeps
    ///    an empty <c>clients</c> array (the node injects credentials at runtime),
    ///    but the panel's own xray-json render of a subscription carries
    ///    <c>streamSettings.hysteriaSettings.auth</c>, and it is byte-identical to
    ///    that user's vless UUID — which is what we lift from the subscription.
    /// 2. <b>sing-box is wire-compatible with these inbounds.</b> Driving the exact
    ///    outbound the app builds from our synthesized link (sing-box 1.13.14,
    ///    hysteria2, tls+alpn h3) through all three nodes carried real traffic:
    ///    exit IPs resolved to FI/FR/US respectively, and 10 MB downloads
    ///    completed. The non-standard <c>finalmask</c> block turns out to be
    ///    endpoint-local QUIC tuning (congestion control, receive windows), not a
    ///    wire-format change, so it needs no client-side counterpart.
    ///
    /// The earlier on-device failure ("tunnel up, no traffic") is therefore not a
    /// config or credential problem. If it recurs, suspect the access network
    /// blocking UDP/443 — QUIC is all these nodes speak, and the app reports
    /// "connected" from the OS tunnel status whether or not sing-box ever reached
    /// the server, so a blocked path looks exactly like a working one.
    ///
    /// Note the FI node is slow (~1-2 Mbit/s in that test, vs ~10-17 for FR/US);
    /// that is node capacity, not the protocol.
    /// </remarks>
    public bool AugmentHysteria { get; set; } = true;
}
