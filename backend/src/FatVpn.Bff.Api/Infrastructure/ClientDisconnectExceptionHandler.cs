using Microsoft.AspNetCore.Diagnostics;

namespace FatVpn.Bff.Api.Infrastructure;

/// <summary>
/// A mobile client that hangs up mid-request cancels <see cref="HttpContext.RequestAborted"/>,
/// which surfaces as an <see cref="OperationCanceledException"/> out of every awaited call.
/// That is normal traffic, not an error: swallow it quietly instead of logging
/// a 500 for every user who backgrounded the app.
/// </summary>
public sealed class ClientDisconnectExceptionHandler : IExceptionHandler
{
    public ValueTask<bool> TryHandleAsync(HttpContext httpContext, Exception exception, CancellationToken ct)
    {
        if (exception is not OperationCanceledException || !httpContext.RequestAborted.IsCancellationRequested)
        {
            return ValueTask.FromResult(false);
        }

        // 499 is nginx's "client closed request"; nothing is written back — the
        // socket is already gone. It only makes the access log readable.
        httpContext.Response.StatusCode = 499;
        return ValueTask.FromResult(true);
    }
}
