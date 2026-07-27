namespace FatVpn.Bff.Infrastructure.Remnawave;

/// <summary>
/// The Remnawave panel could not be reached, timed out, or answered with
/// something unusable (HTTP error, HTML instead of JSON — Cloudflare likes to
/// do that). Callers map this to 502: it is an upstream failure, never a fault
/// of the caller, and it must not surface as a 500.
/// </summary>
public sealed class RemnawaveException(string message, Exception? innerException = null)
    : Exception(message, innerException);
