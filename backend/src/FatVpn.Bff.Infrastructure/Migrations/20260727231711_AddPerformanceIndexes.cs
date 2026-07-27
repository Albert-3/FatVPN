using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FatVpn.Bff.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class AddPerformanceIndexes : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            // Nothing stopped two racing POST /trial calls from writing two trials
            // for one device, and the unique index below would refuse to build over
            // them — leaving the container in a migrate-crash loop on startup. Keep
            // the most generous trial per device (latest expiry) and drop the rest;
            // the device keeps its entitlement either way.
            migrationBuilder.Sql("""
                DELETE FROM "Trials" t
                USING "Trials" other
                WHERE t."DeviceId" = other."DeviceId"
                  AND (t."ExpiresAt", t."Id") < (other."ExpiresAt", other."Id");
                """);

            migrationBuilder.CreateIndex(
                name: "IX_Trials_DeviceId",
                table: "Trials",
                column: "DeviceId",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_RefreshTokens_AccountId_RevokedAt",
                table: "RefreshTokens",
                columns: new[] { "AccountId", "RevokedAt" });

            migrationBuilder.CreateIndex(
                name: "IX_RefreshTokens_ExpiresAt",
                table: "RefreshTokens",
                column: "ExpiresAt");

            migrationBuilder.CreateIndex(
                name: "IX_RefreshTokens_TokenId_RevokedAt",
                table: "RefreshTokens",
                columns: new[] { "TokenId", "RevokedAt" });

            migrationBuilder.CreateIndex(
                name: "IX_PairingCodes_ExpiresAt",
                table: "PairingCodes",
                column: "ExpiresAt");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_Trials_DeviceId",
                table: "Trials");

            migrationBuilder.DropIndex(
                name: "IX_RefreshTokens_AccountId_RevokedAt",
                table: "RefreshTokens");

            migrationBuilder.DropIndex(
                name: "IX_RefreshTokens_ExpiresAt",
                table: "RefreshTokens");

            migrationBuilder.DropIndex(
                name: "IX_RefreshTokens_TokenId_RevokedAt",
                table: "RefreshTokens");

            migrationBuilder.DropIndex(
                name: "IX_PairingCodes_ExpiresAt",
                table: "PairingCodes");
        }
    }
}
