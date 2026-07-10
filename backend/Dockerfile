FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY src/FatVpn.Bff.Api/FatVpn.Bff.Api.csproj src/FatVpn.Bff.Api/
COPY src/FatVpn.Bff.Domain/FatVpn.Bff.Domain.csproj src/FatVpn.Bff.Domain/
COPY src/FatVpn.Bff.Infrastructure/FatVpn.Bff.Infrastructure.csproj src/FatVpn.Bff.Infrastructure/

# Restore the API project (pulls Domain + Infrastructure transitively) rather
# than the whole solution — the .slnx also references the test project, which
# isn't copied into the runtime image and would fail the restore.
RUN dotnet restore src/FatVpn.Bff.Api/FatVpn.Bff.Api.csproj

COPY . .
RUN dotnet publish src/FatVpn.Bff.Api/FatVpn.Bff.Api.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app/publish .

ENV ASPNETCORE_URLS=http://+:5030
EXPOSE 5030

ENTRYPOINT ["dotnet", "FatVpn.Bff.Api.dll"]
