using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Remnawave;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Caching.Memory;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("servers")]
[Authorize]
public class ServersController(
    FatVpnDbContext db,
    IRemnawaveClient remnawaveClient,
    IMemoryCache cache) : ControllerBase
{
    private const string CacheKey = "servers:nodes";

    /// <summary>Short enough that a node going offline shows up within a minute,
    /// long enough that pull-to-refresh doesn't hit the panel once per user.</summary>
    private static readonly TimeSpan CacheLifetime = TimeSpan.FromSeconds(45);

    /// <summary>Collapses a thundering herd onto a single panel call: without it,
    /// every request that arrives while the cache is cold starts its own.</summary>
    private static readonly SemaphoreSlim RefreshLock = new(1, 1);

    [HttpGet]
    public async Task<IActionResult> GetServers(CancellationToken ct)
    {
        var subscription = await db.ResolveSubscriptionAsync(User, ct);
        if (subscription is null)
        {
            return Unauthorized();
        }

        if (!subscription.IsActive)
        {
            // Lapsed subscription — same 402 signal as /config so the app routes
            // to the renew screen instead of listing servers it can't connect to.
            return StatusCode(StatusCodes.Status402PaymentRequired);
        }

        var servers = await GetNodesCachedAsync(ct);
        Response.Headers.CacheControl = "private, max-age=45";
        return Ok(servers);
    }

    /// <summary>
    /// The node list is identical for every user, but each pull-to-refresh used
    /// to become its own request to the panel.
    /// </summary>
    private async Task<IReadOnlyList<ServerCountry>> GetNodesCachedAsync(CancellationToken ct)
    {
        if (cache.TryGetValue(CacheKey, out IReadOnlyList<ServerCountry>? cached) && cached is not null)
        {
            return cached;
        }

        await RefreshLock.WaitAsync(ct);
        try
        {
            // Someone else may have filled it while we waited for the lock.
            if (cache.TryGetValue(CacheKey, out cached) && cached is not null)
            {
                return cached;
            }

            var fresh = await remnawaveClient.GetNodesAsync(ct);
            cache.Set(CacheKey, fresh, CacheLifetime);
            return fresh;
        }
        finally
        {
            RefreshLock.Release();
        }
    }
}
