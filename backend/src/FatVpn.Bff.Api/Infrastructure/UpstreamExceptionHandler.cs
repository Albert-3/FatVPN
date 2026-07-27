using FatVpn.Bff.Infrastructure.Remnawave;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;

namespace FatVpn.Bff.Api.Infrastructure;

/// <summary>
/// Maps a failed Remnawave call to 502 instead of letting it bubble up as 500.
/// The app already understands 502 as "panel unreachable, retry" — a 500 reads
/// as "the BFF is broken" and sends the user to support.
/// </summary>
public sealed class UpstreamExceptionHandler(ILogger<UpstreamExceptionHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext httpContext, Exception exception, CancellationToken ct)
    {
        if (exception is not RemnawaveException)
        {
            return false;
        }

        logger.LogWarning(exception, "Remnawave call failed while serving {Method} {Path}",
            httpContext.Request.Method, httpContext.Request.Path);

        httpContext.Response.StatusCode = StatusCodes.Status502BadGateway;
        await httpContext.Response.WriteAsJsonAsync(new ProblemDetails
        {
            Status = StatusCodes.Status502BadGateway,
            Title = "Upstream unavailable",
            Detail = "The VPN panel could not be reached. Please try again.",
        }, ct);

        return true;
    }
}
