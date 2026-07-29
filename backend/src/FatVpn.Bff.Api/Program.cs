using System.Globalization;
using System.Net;
using System.Text;
using System.Threading.RateLimiting;
using FatVpn.Bff.Api.Auth;
using FatVpn.Bff.Api.Infrastructure;
using FatVpn.Bff.Infrastructure;
using FatVpn.Bff.Infrastructure.Auth;
using FatVpn.Bff.Infrastructure.Bot;
using FatVpn.Bff.Infrastructure.Remnawave;
using FatVpn.Bff.Infrastructure.TrialPool;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);
var isDevelopment = builder.Environment.IsDevelopment();

// Add services to the container.

builder.Services.AddControllers();
// Learn more about configuring OpenAPI at https://aka.ms/aspnet/openapi
builder.Services.AddOpenApi();
builder.Services.AddProblemDetails();
builder.Services.AddHttpContextAccessor();
builder.Services.AddMemoryCache();
// /servers and /config are the two responses worth compressing on a mobile link.
builder.Services.AddResponseCompression(o => o.EnableForHttps = true);

// Every request this API serves is a small JSON document. Nothing legitimate
// comes close to this, and it caps the cheapest denial-of-service there is.
builder.WebHost.ConfigureKestrel(o => o.Limits.MaxRequestBodySize = 64 * 1024);

builder.Services.AddDbContext<FatVpnDbContext>(options =>
    options.UseNpgsql(builder.Configuration.GetConnectionString("FatVpn")));

// Secrets are validated at startup, not at first use: a short or missing
// Jwt:Secret used to start fine and then 500 on every single login.
builder.Services.AddOptions<JwtOptions>()
    .Bind(builder.Configuration.GetSection("Jwt"))
    .Validate(o => Encoding.UTF8.GetByteCount(o.Secret) >= 32,
        "Jwt:Secret must be at least 32 bytes — HMAC-SHA256 refuses to sign with a shorter key.")
    .Validate(o => !string.IsNullOrWhiteSpace(o.Issuer), "Jwt:Issuer must be set.")
    .Validate(o => !string.IsNullOrWhiteSpace(o.Audience), "Jwt:Audience must be set.")
    .Validate(o => o.AccessTokenLifetime > TimeSpan.Zero, "Jwt:AccessTokenLifetime must be positive.")
    .Validate(o => o.RefreshTokenLifetime > TimeSpan.Zero, "Jwt:RefreshTokenLifetime must be positive.")
    .ValidateOnStart();

builder.Services.AddOptions<AuthOptions>()
    .Bind(builder.Configuration.GetSection("Auth"))
    // Zero would refuse every device including the first, and a negative value
    // would make the slot-claiming UPDATE match nothing — both lock every user
    // out of their own key, so fail at startup instead.
    .Validate(o => o.MaxDevicesPerKey >= 1, "Auth:MaxDevicesPerKey must be at least 1.")
    .ValidateOnStart();

builder.Services.AddOptions<RemnawaveOptions>()
    .Bind(builder.Configuration.GetSection("Remnawave"))
    .Validate(o => Uri.TryCreate(o.BaseUrl, UriKind.Absolute, out _), "Remnawave:BaseUrl must be an absolute URL.")
    .Validate(o => isDevelopment || !string.IsNullOrWhiteSpace(o.ApiToken),
        "Remnawave:ApiToken must be set outside Development.")
    .ValidateOnStart();

builder.Services.AddOptions<BotOptions>()
    .Bind(builder.Configuration.GetSection("Bot"))
    .Validate(o => isDevelopment || o.Secret.Length >= 16,
        "Bot:Secret must be at least 16 characters outside Development — it is the only guard on /internal/*.")
    .ValidateOnStart();

builder.Services.AddOptions<TrialOptions>()
    .Bind(builder.Configuration.GetSection("Trial"))
    // An empty salt is not a hard failure of the hash, but it makes device keys
    // trivially rainbow-tableable, so refuse to run that way in production.
    .Validate(o => isDevelopment || !string.IsNullOrWhiteSpace(o.DeviceKeySalt),
        "Trial:DeviceKeySalt must be set outside Development.")
    .Validate(o => o.DurationDays > 0 || o.DurationMinutes > 0, "Trial duration must be positive.")
    .ValidateOnStart();

builder.Services.AddOptions<RateLimitOptions>()
    .Bind(builder.Configuration.GetSection(RateLimitOptions.SectionName));
builder.Services.AddOptions<ReverseProxyOptions>()
    .Bind(builder.Configuration.GetSection(ReverseProxyOptions.SectionName));

builder.Services.AddScoped<IJwtTokenService, JwtTokenService>();
builder.Services.AddScoped<IRefreshTokenService, RefreshTokenService>();
builder.Services.AddHttpClient<IRemnawaveClient, RemnawaveClient>((sp, client) =>
    {
        var remnawaveOptions = sp.GetRequiredService<IOptions<RemnawaveOptions>>().Value;
        client.BaseAddress = new Uri(remnawaveOptions.BaseUrl);
        // Default is 100 s: a hung panel would pin BFF request threads and
        // sockets long enough to take the whole API down with it.
        client.Timeout = TimeSpan.FromSeconds(10);
    })
    .ConfigurePrimaryHttpMessageHandler(() => new SocketsHttpHandler
    {
        // The panel sits behind Cloudflare; recycling pooled connections means
        // an upstream IP change is picked up without restarting the container.
        PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        // No endpoint of the panel's answers with a redirect, so following one
        // can only ever land somewhere that isn't the panel — which is precisely
        // how a login portal in front of /sub returned HTTP 200 and a page of
        // HTML where the subscription should have been. Leave the 302 visible so
        // EnsureSuccessStatusCode turns it into a 502.
        AllowAutoRedirect = false,
    });
// Deliberately no AddStandardResilienceHandler: its default retry policy also
// retries POSTs, and a retried POST /api/users would leave orphan trial users
// in the panel. Timeout + connection recycling is the safe half.

// Client IPs are the partition key for rate limiting; behind Caddy every
// request would otherwise carry the proxy's address and share one bucket.
var reverseProxy = builder.Configuration.GetSection(ReverseProxyOptions.SectionName).Get<ReverseProxyOptions>()
    ?? new ReverseProxyOptions();
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    if (!reverseProxy.IsConfigured)
    {
        return;
    }

    // Replacing the defaults (loopback only) rather than adding to them — a
    // containerised proxy never appears as 127.0.0.1.
    options.KnownProxies.Clear();
    options.KnownIPNetworks.Clear();
    foreach (var proxy in reverseProxy.KnownProxies)
    {
        options.KnownProxies.Add(IPAddress.Parse(proxy));
    }

    foreach (var network in reverseProxy.KnownNetworks)
    {
        options.KnownIPNetworks.Add(System.Net.IPNetwork.Parse(network));
    }
});

var requireHttps = builder.Configuration.GetValue<bool>("Security:RequireHttps");

var rateLimits = builder.Configuration.GetSection(RateLimitOptions.SectionName).Get<RateLimitOptions>()
    ?? new RateLimitOptions();
builder.Services.AddRateLimiter(limiter =>
{
    limiter.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    limiter.OnRejected = (context, _) =>
    {
        if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
        {
            context.HttpContext.Response.Headers.RetryAfter =
                ((int)retryAfter.TotalSeconds).ToString(CultureInfo.InvariantCulture);
        }

        return ValueTask.CompletedTask;
    };

    limiter.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(http =>
        RateLimitPartition.GetFixedWindowLimiter(ClientKey(http), _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = rateLimits.GlobalPerMinute,
            Window = TimeSpan.FromMinutes(1),
        }));

    limiter.AddPolicy(RateLimitPolicies.Auth, http =>
        RateLimitPartition.GetFixedWindowLimiter(ClientKey(http), _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = rateLimits.AuthPerMinute,
            Window = TimeSpan.FromMinutes(1),
        }));

    limiter.AddPolicy(RateLimitPolicies.PairStatus, http =>
        RateLimitPartition.GetFixedWindowLimiter(ClientKey(http), _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = rateLimits.PairStatusPerMinute,
            Window = TimeSpan.FromMinutes(1),
        }));

    limiter.AddPolicy(RateLimitPolicies.Trial, http =>
        RateLimitPartition.GetFixedWindowLimiter(ClientKey(http), _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = rateLimits.TrialPerHour,
            Window = TimeSpan.FromHours(1),
        }));

    static string ClientKey(HttpContext http) =>
        http.Connection.RemoteIpAddress?.ToString() ?? "unknown";
});

builder.Services.AddExceptionHandler<ClientDisconnectExceptionHandler>();
builder.Services.AddExceptionHandler<UpstreamExceptionHandler>();

var jwtOptions = builder.Configuration.GetSection("Jwt").Get<JwtOptions>() ?? new JwtOptions();
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(o =>
    {
        o.TokenValidationParameters = new TokenValidationParameters
        {
            ValidIssuer = jwtOptions.Issuer,
            ValidAudience = jwtOptions.Audience,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtOptions.Secret)),
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            // Pin the algorithm so a token can't ask to be validated differently.
            ValidAlgorithms = [SecurityAlgorithms.HmacSha256],
            // Default is 5 minutes, which quietly turns a 30-minute access token
            // into a 35-minute one.
            ClockSkew = TimeSpan.FromSeconds(30),
        };
    });
builder.Services.AddSingleton<IAuthorizationHandler, BotSecretAuthorizationHandler>();
builder.Services.AddAuthorization(options =>
{
    // The /internal/* surface authenticates with a shared secret, not a JWT.
    options.AddPolicy(BotSecretRequirement.PolicyName,
        policy => policy.AddRequirements(new BotSecretRequirement()));
});

builder.Services.AddHostedService<ExpiredCredentialSweeper>();

builder.Services.AddHealthChecks().AddDbContextCheck<FatVpnDbContext>();

var app = builder.Build();

// Run the ValidateOnStart checks before touching the database, so a missing
// secret reports itself instead of hiding behind a connection timeout.
app.Services.GetRequiredService<IStartupValidator>().Validate();

using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<FatVpnDbContext>();
    db.Database.Migrate();
}

app.UseForwardedHeaders();
if (!isDevelopment && !reverseProxy.IsConfigured)
{
    app.Logger.LogWarning(
        "ReverseProxy:KnownProxies/KnownNetworks are empty — X-Forwarded-For will be ignored and " +
        "per-IP rate limiting will bucket every client behind the proxy together.");
}

// The Development secrets were committed to git once and must be treated as
// public. Setting ASPNETCORE_ENVIRONMENT=Development on a reachable host would
// therefore sign JWTs with a key anyone can read — refuse to start that way.
if (isDevelopment)
{
    var urls = builder.Configuration["ASPNETCORE_URLS"] ?? builder.Configuration["urls"] ?? string.Empty;
    var exposed = urls.Split(';', StringSplitOptions.RemoveEmptyEntries)
        .Where(u => !IsLoopback(u))
        .ToArray();
    if (exposed.Length > 0)
    {
        throw new InvalidOperationException(
            $"Refusing to run the Development configuration on a non-loopback address ({string.Join(", ", exposed)}). " +
            "Its secrets are in git history; set ASPNETCORE_ENVIRONMENT=Production and supply real ones.");
    }

    static bool IsLoopback(string url) =>
        Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri)
        && (uri.Host is "localhost" or "127.0.0.1" or "[::1]" or "::1");
}

if (requireHttps && !reverseProxy.IsConfigured)
{
    throw new InvalidOperationException(
        "Security:RequireHttps is on but ReverseProxy:KnownProxies/KnownNetworks are empty. " +
        "The BFF would not see X-Forwarded-Proto and would redirect every proxied request forever.");
}

app.UseExceptionHandler();

if (isDevelopment)
{
    app.MapOpenApi();
}

// Was previously the other way round — redirecting in Development, where it is
// pointless, and never in production, where it is the whole point. It stays
// opt-in because turning it on before the app ships an https:// base URL would
// 307 every existing install into a wall; flip Security:RequireHttps together
// with the domain cutover. Requires ReverseProxy:* to be set, otherwise
// X-Forwarded-Proto is ignored and Caddy and the BFF redirect each other in a loop.
if (requireHttps)
{
    app.UseHsts();
    app.UseHttpsRedirection();
}

if (rateLimits.Enabled)
{
    app.UseRateLimiter();
}

app.UseResponseCompression();
app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();

// Was an unconditional "ok", which reported healthy while the database was down.
// The response shape is kept as-is so existing probes don't have to change.
app.MapHealthChecks("/health", new HealthCheckOptions
{
    ResponseWriter = (context, report) =>
    {
        context.Response.ContentType = "application/json";
        return context.Response.WriteAsJsonAsync(new
        {
            status = report.Status == HealthStatus.Healthy ? "ok" : "degraded",
        });
    },
});

app.Run();
