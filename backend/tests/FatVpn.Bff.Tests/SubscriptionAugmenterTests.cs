using System.Text;
using FatVpn.Bff.Infrastructure.Remnawave;
using Xunit;

namespace FatVpn.Bff.Tests;

/// <summary>
/// Guards the shape of the synthesized <c>hysteria2://</c> links. The panel's own
/// xray-json render of these nodes is the reference (verified against the live panel
/// 2026-07-27): <c>auth</c> = the user's vless UUID, <c>alpn</c> = h3, TLS SNI = the
/// node host. A drift here shows up on a device only as "connected, no internet".
/// </summary>
public class SubscriptionAugmenterTests
{
    private const string Uuid = "646b72f6-e5ac-4cc0-b415-3432a8245a7a";

    private static string Encode(params string[] lines)
        => Convert.ToBase64String(Encoding.UTF8.GetBytes(string.Join('\n', lines)));

    private static string Decode(string base64)
        => Encoding.UTF8.GetString(Convert.FromBase64String(base64));

    private static string VlessLine(string uuid = Uuid)
        => $"vless://{uuid}@fat-de.arpozan.cloud:443?type=tcp&security=tls#DE";

    [Fact]
    public void AppendHysteriaHosts_AddsAllThreeNodes_WithVlessUuidAsAuth()
    {
        var result = Decode(SubscriptionAugmenter.AppendHysteriaHosts(Encode(VlessLine())));

        var hysteriaLines = result.Split('\n')
            .Where(l => l.StartsWith("hysteria2://", StringComparison.Ordinal))
            .ToArray();

        Assert.Equal(3, hysteriaLines.Length);
        Assert.All(hysteriaLines, line => Assert.Contains($"hysteria2://{Uuid}@", line));
        Assert.Contains(hysteriaLines, l => l.Contains("h1-fi.arpozan.cloud:443"));
        Assert.Contains(hysteriaLines, l => l.Contains("h2-fr.arpozan.cloud:443"));
        Assert.Contains(hysteriaLines, l => l.Contains("h3-us.arpozan.cloud:443"));
        // The nodes advertise alpn h3/h3-29 and present a cert for their own name;
        // offering neither fails the QUIC handshake.
        Assert.All(hysteriaLines, line => Assert.Contains("alpn=h3", line));
        Assert.Contains(hysteriaLines, l => l.Contains("sni=h1-fi.arpozan.cloud"));
    }

    [Fact]
    public void AppendHysteriaHosts_KeepsExistingLines()
    {
        var original = VlessLine();
        var result = Decode(SubscriptionAugmenter.AppendHysteriaHosts(Encode(original)));

        Assert.StartsWith(original, result, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not base64 at all !!!")]
    public void AppendHysteriaHosts_LeavesUnparseableInputAlone(string input)
        => Assert.Equal(input, SubscriptionAugmenter.AppendHysteriaHosts(input));

    [Fact]
    public void AppendHysteriaHosts_WithoutVlessLine_ReturnsInputUnchanged()
    {
        // No vless line means no UUID to authenticate with — appending links that
        // cannot connect would be worse than omitting the nodes.
        var input = Encode("trojan://pass@example.com:443#T");

        Assert.Equal(input, SubscriptionAugmenter.AppendHysteriaHosts(input));
    }
}
