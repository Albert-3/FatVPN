using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FatVpn.Bff.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class AddRefreshTokenSessionStart : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "SessionStartedAt",
                table: "RefreshTokens",
                type: "timestamp with time zone",
                nullable: false,
                defaultValue: new DateTimeOffset(new DateTime(1, 1, 1, 0, 0, 0, 0, DateTimeKind.Unspecified), new TimeSpan(0, 0, 0, 0, 0)));

            // Existing sessions get their own creation time as the session start.
            // Leaving them at the default would exempt every live install from an
            // absolute lifetime that is switched on later.
            migrationBuilder.Sql("""
                UPDATE "RefreshTokens"
                SET "SessionStartedAt" = "CreatedAt"
                WHERE "SessionStartedAt" = '0001-01-01T00:00:00+00:00';
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "SessionStartedAt",
                table: "RefreshTokens");
        }
    }
}
