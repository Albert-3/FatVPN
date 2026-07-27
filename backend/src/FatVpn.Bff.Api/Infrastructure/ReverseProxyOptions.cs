namespace FatVpn.Bff.Api.Infrastructure;

/// <summary>
/// Which upstream proxies may set <c>X-Forwarded-For</c>/<c>X-Forwarded-Proto</c>.
/// This has to be explicit: trusting everyone lets any client forge its source
/// IP and walk straight through the per-IP rate limiter.
/// </summary>
public sealed class ReverseProxyOptions
{
    public const string SectionName = "ReverseProxy";

    /// <summary>Individual proxy addresses, e.g. the Caddy container's IP.</summary>
    public string[] KnownProxies { get; set; } = [];

    /// <summary>CIDR ranges, e.g. "172.16.0.0/12" for the Docker bridge network.</summary>
    public string[] KnownNetworks { get; set; } = [];

    public bool IsConfigured => KnownProxies.Length > 0 || KnownNetworks.Length > 0;
}
