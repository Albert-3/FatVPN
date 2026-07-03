FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY FatVpn.Bff.slnx .
COPY src/FatVpn.Bff.Api/FatVpn.Bff.Api.csproj src/FatVpn.Bff.Api/
COPY src/FatVpn.Bff.Domain/FatVpn.Bff.Domain.csproj src/FatVpn.Bff.Domain/
COPY src/FatVpn.Bff.Infrastructure/FatVpn.Bff.Infrastructure.csproj src/FatVpn.Bff.Infrastructure/

RUN dotnet restore FatVpn.Bff.slnx

COPY . .
RUN dotnet publish src/FatVpn.Bff.Api/FatVpn.Bff.Api.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app/publish .

ENV ASPNETCORE_URLS=http://+:5030
EXPOSE 5030

ENTRYPOINT ["dotnet", "FatVpn.Bff.Api.dll"]
