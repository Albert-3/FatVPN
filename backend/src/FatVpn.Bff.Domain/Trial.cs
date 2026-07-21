namespace FatVpn.Bff.Domain;

public class Trial
{
    public Guid Id { get; set; }
    public Guid DeviceId { get; set; }
    public DateTimeOffset GrantedAt { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }

    /// <summary>The <see cref="Token"/> minted for this trial. Lets a repeat
    /// <c>POST /trial</c> from the same device (e.g. after sign-out) reissue a
    /// session for the still-running trial instead of just refusing with 409.</summary>
    public Guid TokenId { get; set; }
}
