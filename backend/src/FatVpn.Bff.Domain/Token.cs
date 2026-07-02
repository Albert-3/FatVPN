namespace FatVpn.Bff.Domain;

public class Token
{
    public Guid Id { get; set; }
    public string ShortToken { get; set; } = string.Empty;
    public string RemnawaveSubscriptionId { get; set; } = string.Empty;
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
}
