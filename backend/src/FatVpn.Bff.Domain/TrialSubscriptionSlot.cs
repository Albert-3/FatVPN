namespace FatVpn.Bff.Domain;

public class TrialSubscriptionSlot
{
    public Guid Id { get; set; }
    public string RemnawaveSubscriptionId { get; set; } = string.Empty;
    public bool IsAssigned { get; set; }
    public Guid? AssignedDeviceId { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? AssignedAt { get; set; }
}
