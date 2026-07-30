namespace FatVpn.Bff.Infrastructure.Remnawave;

/// <summary>
/// The Remnawave panel could not be reached, timed out, or answered with
/// something unusable (HTTP error, HTML instead of JSON — Cloudflare likes to
/// do that). Callers map this to 502: it is an upstream failure, never a fault
/// of the caller, and it must not surface as a 500.
///
/// Not sealed: <see cref="SubscriptionGoneException"/> is the one case where the
/// panel answered perfectly well and the news is about the subscription rather
/// than the panel. Every existing <c>catch</c> keeps working, and the handler
/// picks that one out before falling back to 502.
/// </summary>
public class RemnawaveException(string message, Exception? innerException = null)
    : Exception(message, innerException);
