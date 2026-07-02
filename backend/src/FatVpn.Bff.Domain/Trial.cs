namespace FatVpn.Bff.Domain;

public class Trial
{
    public Guid Id { get; set; }
    public Guid DeviceId { get; set; }
    public DateTimeOffset GrantedAt { get; set; }
    public DateTimeOffset ExpiresAt { get; set; }
}
