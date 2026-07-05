namespace FatVpn.Bff.Domain;

/// <summary>
/// A stable app identity keyed by the user's Telegram id. Holds the user's
/// current Remnawave subscription, which the bot keeps fresh whenever the
/// active key changes (create/change/extend). The app's JWT carries the
/// account id, so key changes in the bot no longer break the app session.
/// </summary>
public class Account
{
    public Guid Id { get; set; }
    public long TelegramUserId { get; set; }
    public string CurrentSubscriptionId { get; set; } = string.Empty;
    public DateTimeOffset ExpiresAt { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }
}
