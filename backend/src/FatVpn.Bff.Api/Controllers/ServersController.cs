using FatVpn.Bff.Infrastructure.Remnawave;
using Microsoft.AspNetCore.Mvc;

namespace FatVpn.Bff.Api.Controllers;

[ApiController]
[Route("servers")]
public class ServersController(IRemnawaveClient remnawaveClient) : ControllerBase
{
    [HttpGet]
    public async Task<IActionResult> GetServers(CancellationToken ct)
    {
        try
        {
            var servers = await remnawaveClient.GetNodesAsync(ct);
            return Ok(servers);
        }
        catch (HttpRequestException)
        {
            return StatusCode(StatusCodes.Status502BadGateway);
        }
    }
}
