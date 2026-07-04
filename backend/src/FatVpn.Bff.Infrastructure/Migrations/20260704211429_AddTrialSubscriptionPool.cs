using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FatVpn.Bff.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class AddTrialSubscriptionPool : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "TrialSubscriptionSlots",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    RemnawaveSubscriptionId = table.Column<string>(type: "text", nullable: false),
                    IsAssigned = table.Column<bool>(type: "boolean", nullable: false),
                    AssignedDeviceId = table.Column<Guid>(type: "uuid", nullable: true),
                    CreatedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: false),
                    AssignedAt = table.Column<DateTimeOffset>(type: "timestamp with time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_TrialSubscriptionSlots", x => x.Id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_TrialSubscriptionSlots_RemnawaveSubscriptionId",
                table: "TrialSubscriptionSlots",
                column: "RemnawaveSubscriptionId",
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "TrialSubscriptionSlots");
        }
    }
}
