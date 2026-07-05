namespace FatVpn.Bff.Domain;

public static class FatVpnClaimTypes
{
    // Not "tid": that short name collides with JwtSecurityTokenHandler's default
    // inbound claim map (Azure AD tenant id) and gets silently remapped on the way in.
    public const string TokenId = "fatvpn_token_id";

    // Carried by JWTs minted for a paired Account. /me and /config resolve the
    // current subscription through the account, so bot-side key changes don't
    // invalidate the app session. Legacy deep-link tokens still use TokenId.
    public const string AccountId = "fatvpn_account_id";
}
