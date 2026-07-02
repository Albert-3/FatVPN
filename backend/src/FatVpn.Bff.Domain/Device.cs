namespace FatVpn.Bff.Domain;

public class Device
{
    public Guid Id { get; set; }
    public string DeviceKeyHash { get; set; } = string.Empty;
    public string Platform { get; set; } = string.Empty;
    public DateTimeOffset CreatedAt { get; set; }
}
