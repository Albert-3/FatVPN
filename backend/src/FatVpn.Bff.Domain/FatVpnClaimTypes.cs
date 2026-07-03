namespace FatVpn.Bff.Domain;

public static class FatVpnClaimTypes
{
    // Not "tid": that short name collides with JwtSecurityTokenHandler's default
    // inbound claim map (Azure AD tenant id) and gets silently remapped on the way in.
    public const string TokenId = "fatvpn_token_id";
}
