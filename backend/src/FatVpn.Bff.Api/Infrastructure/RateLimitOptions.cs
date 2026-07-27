namespace FatVpn.Bff.Api.Infrastructure;

/// <summary>
/// Per-IP request budgets for the public (unauthenticated) surface. Values are
/// configurable because the right numbers depend on how many users sit behind
/// one carrier NAT — ops must be able to loosen them without a rebuild.
/// </summary>
public sealed class RateLimitOptions
{
    public const string SectionName = "RateLimiting";

    /// <summary>Escape hatch for local development and load tests.</summary>
    public bool Enabled { get; set; } = true;

    /// <summary>Catch-all budget applied to every endpoint, on top of the per-policy ones.</summary>
    public int GlobalPerMinute { get; set; } = 300;

    /// <summary>Budget for /auth/* and /pair/start — brute-force surface, low legitimate volume.</summary>
    public int AuthPerMinute { get; set; } = 20;

    /// <summary>The app polls /pair/status every 2 s (30/min); this leaves 2x headroom.</summary>
    public int PairStatusPerMinute { get; set; } = 60;

    /// <summary>Each grant provisions a real user in the panel, so this one is deliberately tight.</summary>
    public int TrialPerHour { get; set; } = 5;
}

/// <summary>Policy names shared between <c>Program</c> and the controllers.</summary>
public static class RateLimitPolicies
{
    public const string Auth = "auth";
    public const string PairStatus = "pair-status";
    public const string Trial = "trial";
}
