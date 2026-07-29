using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FatVpn.Bff.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class MarkRotatedRefreshTokens : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<bool>(
                name: "RotatedOut",
                table: "RefreshTokens",
                type: "boolean",
                nullable: false,
                defaultValue: false);

            // Everything already revoked predates the distinction, and its grace
            // window closed long ago — so the flag cannot change how those rows
            // behave. Except for the handful revoked in the seconds around this
            // deployment: calling those rotations keeps them behaving exactly as
            // they did a moment earlier, instead of signing someone out mid-race.
            migrationBuilder.Sql(
                """UPDATE "RefreshTokens" SET "RotatedOut" = true WHERE "RevokedAt" IS NOT NULL;""");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "RotatedOut",
                table: "RefreshTokens");
        }
    }
}
