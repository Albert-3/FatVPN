using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FatVpn.Bff.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class AddAccountKeyCode : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "CurrentKeyCode",
                table: "Accounts",
                type: "text",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "CurrentKeyCode",
                table: "Accounts");
        }
    }
}
