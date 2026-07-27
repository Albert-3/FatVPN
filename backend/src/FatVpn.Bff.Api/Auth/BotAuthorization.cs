using FatVpn.Bff.Infrastructure.Bot;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Extensions.Options;

namespace FatVpn.Bff.Api.Auth;

/// <summary>
/// Authorization for the bot-only <c>/internal/*</c> surface. The check used to
/// be copy-pasted into the first line of every internal action, which meant a
/// new endpoint was one forgotten line away from being wide open. As a policy it
/// is declarative and impossible to omit silently.
/// </summary>
public sealed class BotSecretRequirement : IAuthorizationRequirement
{
    public const string PolicyName = "Bot";
}

public sealed class BotSecretAuthorizationHandler(
    IHttpContextAccessor httpContextAccessor,
    IOptions<BotOptions> botOptions,
    ILogger<BotSecretAuthorizationHandler> logger) : AuthorizationHandler<BotSecretRequirement>
{
    protected override Task HandleRequirementAsync(
        AuthorizationHandlerContext context, BotSecretRequirement requirement)
    {
        var httpContext = httpContextAccessor.HttpContext;
        if (httpContext is null)
        {
            return Task.CompletedTask;
        }

        var provided = httpContext.Request.Headers[BotSecretValidator.HeaderName];
        if (BotSecretValidator.IsValid(provided, botOptions.Value.Secret))
        {
            context.Succeed(requirement);
        }
        else
        {
            // There is no audit trail on this surface at all; a rejected bot call
            // is worth knowing about, since only our own bot should ever make one.
            logger.LogWarning("Rejected an /internal call to {Path} with a bad or missing bot secret",
                httpContext.Request.Path);
        }

        return Task.CompletedTask;
    }
}
