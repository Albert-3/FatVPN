namespace FatVpn.Bff.Infrastructure.Remnawave;

public sealed class RemnawaveOptions
{
    public string BaseUrl { get; set; } = string.Empty;
    public string ApiToken { get; set; } = string.Empty;

    /// Internal squad new trial users are added to so their subscription
    /// carries the node inbounds. Defaults to this install's "Default-Squad";
    /// override via config if the panel's squad changes.
    public string TrialSquadUuid { get; set; } = "d8269461-864e-440c-b504-65e5e5478b7a";
}
