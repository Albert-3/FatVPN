using System.Text.RegularExpressions;
using Xunit;

namespace FatVpn.Bff.Tests;

/// <summary>
/// Guards on the deployed compose file, not on code. `AllowedHosts` was widened
/// to "*" for as long as this project has existed, and narrowing it moved a
/// class of mistake into a place no test looks: a name dropped from that list
/// does not warn, it answers <b>400</b> to everything arriving under it. Two of
/// the entries are load-bearing in ways their spelling does not advertise —
/// `fatvpn-bff` is the name the Telegram bot calls over the shared docker
/// network, and the bare IP is the address of every app build already installed
/// on a phone — so both are asserted by name.
/// </summary>
public class DeploymentConfigTests
{
    private static string ComposeFile()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "docker-compose.yml")))
        {
            dir = dir.Parent;
        }

        Assert.NotNull(dir);
        return File.ReadAllText(Path.Combine(dir!.FullName, "docker-compose.yml"));
    }

    private static string AllowedHosts()
    {
        var match = Regex.Match(ComposeFile(), @"^\s*AllowedHosts:\s*""?([^""\r\n]+)""?\s*$",
            RegexOptions.Multiline);
        Assert.True(match.Success, "docker-compose.yml no longer sets AllowedHosts at all, "
            + "which falls back to the appsettings default of \"*\" — every Host header accepted.");
        return match.Groups[1].Value;
    }

    [Theory]
    // The bot: http://fatvpn-bff:5030 over the fatvpn_default network. Losing
    // this one breaks pairing, and the app's own traffic keeps working, so
    // nothing about the symptom points here.
    [InlineData("fatvpn-bff")]
    // Builds already in people's hands, which is also why plain HTTP on 5030 is
    // still open. This entry retires when they do, not when a new build ships.
    [InlineData("87.121.221.229")]
    // What Caddy passes through for everything current.
    [InlineData("api.fatklyuchi.space")]
    public void AllowedHosts_keeps_every_name_the_bff_is_reached_by(string host)
    {
        Assert.Contains(host, AllowedHosts().Split(';').Select(h => h.Trim()));
    }

    [Fact]
    public void AllowedHosts_is_not_a_wildcard()
    {
        Assert.DoesNotContain("*", AllowedHosts());
    }
}
