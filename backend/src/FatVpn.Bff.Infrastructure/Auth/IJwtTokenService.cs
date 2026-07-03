using FatVpn.Bff.Domain;

namespace FatVpn.Bff.Infrastructure.Auth;

public interface IJwtTokenService
{
    string CreateAccessToken(Token token);
}
