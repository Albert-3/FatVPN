using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FatVpn.Bff.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class EvictLeastRecentlySeenDevice : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<DateTimeOffset>(
                name: "LastSeenAt",
                table: "TokenDevices",
                type: "timestamp with time zone",
                nullable: false,
                defaultValue: new DateTimeOffset(new DateTime(1, 1, 1, 0, 0, 0, 0, DateTimeKind.Unspecified), new TimeSpan(0, 0, 0, 0, 0)));

            // Devices already holding a slot have never "been seen" by a column
            // that did not exist. Left at the default they would all sort ahead
            // of any new device and be evicted first, in the order they happened
            // to be bound — so start their clock where their evidence ends.
            //
            // Matched by comparison rather than against the default's literal:
            // Npgsql stores DateTimeOffset.MinValue as '-infinity', so testing
            // for '0001-01-01' silently updates nothing (it did exactly that on
            // the test server).
            migrationBuilder.Sql(
                """UPDATE "TokenDevices" SET "LastSeenAt" = "BoundAt" WHERE "LastSeenAt" < "BoundAt";""");

            migrationBuilder.AddColumn<string>(
                name: "DeviceKeyHash",
                table: "RefreshTokens",
                type: "text",
                nullable: true);

            migrationBuilder.CreateIndex(
                name: "IX_RefreshTokens_DeviceKeyHash_RevokedAt",
                table: "RefreshTokens",
                columns: new[] { "DeviceKeyHash", "RevokedAt" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_RefreshTokens_DeviceKeyHash_RevokedAt",
                table: "RefreshTokens");

            migrationBuilder.DropColumn(
                name: "LastSeenAt",
                table: "TokenDevices");

            migrationBuilder.DropColumn(
                name: "DeviceKeyHash",
                table: "RefreshTokens");
        }
    }
}
