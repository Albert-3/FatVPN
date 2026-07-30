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

        // A subscription the panel no longer has is not an outage. It is the same
        // condition as a lapsed one, and the app already knows how to answer 402:
        // it shows the renew screen. Answering 502 sent that user to a home
        // screen reading "ApiException(502)" with nothing said about their key.
        if (exception is SubscriptionGoneException gone)
        {
            logger.LogWarning("The panel no longer has subscription {SubscriptionId}; answering 402",
                gone.SubscriptionId);

            httpContext.Response.StatusCode = StatusCodes.Status402PaymentRequired;
            await httpContext.Response.WriteAsJsonAsync(new ProblemDetails
            {
                Status = StatusCodes.Status402PaymentRequired,
                Title = "Subscription no longer exists",
                Detail = "This key is not on the panel any more. Renew it in the bot.",
            }, ct);

            return true;
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
