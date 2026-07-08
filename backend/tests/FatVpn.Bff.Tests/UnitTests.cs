using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Api.Pairing;
using FatVpn.Bff.Domain;
using Xunit;

namespace FatVpn.Bff.Tests;

public class PairingCodeGeneratorTests
{
    [Fact]
    public void NewCode_Has8UnambiguousChars()
    {
        const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        for (var i = 0; i < 200; i++)
        {
            var code = PairingCodeGenerator.NewCode();
            Assert.Equal(8, code.Length);
            Assert.All(code, c => Assert.Contains(c, alphabet));
        }
    }

    [Fact]
    public void NewCode_AvoidsAmbiguousCharacters()
    {
        for (var i = 0; i < 200; i++)
        {
            var code = PairingCodeGenerator.NewCode();
            Assert.DoesNotContain('I', code);
            Assert.DoesNotContain('O', code);
            Assert.DoesNotContain('0', code);
            Assert.DoesNotContain('1', code);
        }
    }

    [Fact]
    public void NewPollToken_Is48HexChars()
    {
        var token = PairingCodeGenerator.NewPollToken();
        Assert.Equal(48, token.Length); // 24 bytes -> 48 hex chars
        Assert.All(token, c => Assert.Contains(c, "0123456789ABCDEF"));
    }

    [Fact]
    public void Codes_AreReasonablyUnique()
    {
        var set = new HashSet<string>();
        for (var i = 0; i < 1000; i++) set.Add(PairingCodeGenerator.NewCode());
        Assert.True(set.Count > 995, $"Too many collisions: {1000 - set.Count}");
    }
}

public class BotSecretValidatorTests
{
    [Fact]
    public void IsValid_MatchingSecret_ReturnsTrue()
        => Assert.True(BotSecretValidator.IsValid("s3cr3t", "s3cr3t"));

    [Fact]
    public void IsValid_DifferentSecret_ReturnsFalse()
        => Assert.False(BotSecretValidator.IsValid("s3cr3t", "other!"));

    [Theory]
    [InlineData(null, "expected")]
    [InlineData("", "expected")]
    [InlineData("provided", null)]
    [InlineData("provided", "")]
    public void IsValid_MissingOrEmpty_ReturnsFalse(string? provided, string? expected)
        => Assert.False(BotSecretValidator.IsValid(provided, expected));

    [Fact]
    public void IsValid_DifferentLength_ReturnsFalse()
        => Assert.False(BotSecretValidator.IsValid("short", "muchlonger"));
}

public class RefreshTokenEntityTests
{
    [Fact]
    public void IsActive_FreshToken_True()
    {
        var now = DateTimeOffset.UtcNow;
        var t = new RefreshToken { ExpiresAt = now.AddDays(1) };
        Assert.True(t.IsActive(now));
    }

    [Fact]
    public void IsActive_Expired_False()
    {
        var now = DateTimeOffset.UtcNow;
        var t = new RefreshToken { ExpiresAt = now.AddSeconds(-1) };
        Assert.False(t.IsActive(now));
    }

    [Fact]
    public void IsActive_Revoked_False()
    {
        var now = DateTimeOffset.UtcNow;
        var t = new RefreshToken { ExpiresAt = now.AddDays(1), RevokedAt = now };
        Assert.False(t.IsActive(now));
    }
}

public class RefreshTokenServiceTests
{
    [Fact]
    public void Create_ProducesHexRawTokenAndHashedEntity()
    {
        var svc = TestHelpers.RefreshService();
        var accountId = Guid.NewGuid();

        var (raw, entity) = svc.Create(accountId, tokenId: null);

        Assert.Equal(64, raw.Length); // 32 bytes -> 64 hex chars
        Assert.NotEqual(raw, entity.TokenHash);      // stored value is not the raw secret
        Assert.Equal(svc.Hash(raw), entity.TokenHash); // but is its hash
        Assert.Equal(accountId, entity.AccountId);
        Assert.Null(entity.TokenId);
        Assert.True(entity.ExpiresAt > DateTimeOffset.UtcNow.AddDays(89));
    }

    [Fact]
    public void Hash_IsDeterministic()
    {
        var svc = TestHelpers.RefreshService();
        Assert.Equal(svc.Hash("abc"), svc.Hash("abc"));
        Assert.NotEqual(svc.Hash("abc"), svc.Hash("abd"));
    }

    [Fact]
    public void Create_TwoCalls_ProduceDistinctRawTokens()
    {
        var svc = TestHelpers.RefreshService();
        var (a, _) = svc.Create(null, Guid.NewGuid());
        var (b, _) = svc.Create(null, Guid.NewGuid());
        Assert.NotEqual(a, b);
    }
}

public class JwtTokenServiceTests
{
    [Fact]
    public void CreateAccessToken_CarriesTokenIdClaim()
    {
        var svc = TestHelpers.JwtService();
        var token = new Token { Id = Guid.NewGuid() };

        var jwt = new JwtSecurityTokenHandler().ReadJwtToken(svc.CreateAccessToken(token));

        Assert.Equal(token.Id.ToString(), jwt.Claims.Single(c => c.Type == FatVpnClaimTypes.TokenId).Value);
        Assert.DoesNotContain(jwt.Claims, c => c.Type == FatVpnClaimTypes.AccountId);
    }

    [Fact]
    public void CreateAccessTokenForAccount_CarriesAccountIdClaim()
    {
        var svc = TestHelpers.JwtService();
        var account = new Account { Id = Guid.NewGuid() };

        var jwt = new JwtSecurityTokenHandler().ReadJwtToken(svc.CreateAccessTokenForAccount(account));

        Assert.Equal(account.Id.ToString(), jwt.Claims.Single(c => c.Type == FatVpnClaimTypes.AccountId).Value);
    }

    [Fact]
    public void CreateAccessToken_ExpiresRoughlyAtLifetime()
    {
        var svc = TestHelpers.JwtService();
        var jwt = new JwtSecurityTokenHandler().ReadJwtToken(svc.CreateAccessToken(new Token { Id = Guid.NewGuid() }));
        var expectedExp = DateTime.UtcNow.AddMinutes(30);
        Assert.True(Math.Abs((jwt.ValidTo - expectedExp).TotalMinutes) < 2);
    }

    [Fact]
    public void CreateAccessToken_HasConfiguredIssuerAndAudience()
    {
        var svc = TestHelpers.JwtService();
        var jwt = new JwtSecurityTokenHandler().ReadJwtToken(svc.CreateAccessToken(new Token { Id = Guid.NewGuid() }));
        Assert.Equal("FatVpn.Bff", jwt.Issuer);
        Assert.Contains("FatVpn.App", jwt.Audiences);
    }
}

public class ClaimsPrincipalExtensionsTests
{
    private static ClaimsPrincipal Principal(params Claim[] claims)
        => new(new ClaimsIdentity(claims, "Test"));

    [Fact]
    public void GetTokenId_ReturnsParsedGuid()
    {
        var id = Guid.NewGuid();
        Assert.Equal(id, Principal(new Claim(FatVpnClaimTypes.TokenId, id.ToString())).GetTokenId());
    }

    [Fact]
    public void GetTokenId_MissingClaim_Throws()
        => Assert.Throws<InvalidOperationException>(() => Principal().GetTokenId());

    [Fact]
    public void TryGetAccountId_Present_ReturnsGuid()
    {
        var id = Guid.NewGuid();
        Assert.Equal(id, Principal(new Claim(FatVpnClaimTypes.AccountId, id.ToString())).TryGetAccountId());
    }

    [Fact]
    public void TryGetAccountId_Absent_ReturnsNull()
        => Assert.Null(Principal().TryGetAccountId());
}
