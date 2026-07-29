using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FatVpn.Bff.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class AllowMultipleDevicesPerKey : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "TokenDevices",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    TokenId = table.Column<Guid>(type: "uuid", nullable: false),
                    SlotIndex = table.Column<int>(type: "integer", nullable: false),
                    DeviceKeyHash = table.Column<string>(type: "text", nullable: false),
                    BoundAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_TokenDevices", x => x.Id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_TokenDevices_TokenId_DeviceKeyHash",
                table: "TokenDevices",
                columns: new[] { "TokenId", "DeviceKeyHash" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_TokenDevices_TokenId_SlotIndex",
                table: "TokenDevices",
                columns: new[] { "TokenId", "SlotIndex" },
                unique: true);

            // Carry every phone that already redeemed its key into slot zero.
            // Without this the slots read as free, and the next three devices to
            // paste the key would take them all while the phone actually using
            // the subscription holds none.
            migrationBuilder.Sql("""
                INSERT INTO "TokenDevices" ("Id", "TokenId", "SlotIndex", "DeviceKeyHash", "BoundAt")
                SELECT gen_random_uuid(), "Id", 0, "BoundDeviceKeyHash", now()
                FROM "Tokens"
                WHERE "BoundDeviceKeyHash" IS NOT NULL;
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "TokenDevices");
        }
    }
}
