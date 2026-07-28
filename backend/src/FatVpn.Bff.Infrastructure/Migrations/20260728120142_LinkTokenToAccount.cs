using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FatVpn.Bff.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class LinkTokenToAccount : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<Guid>(
                name: "AccountId",
                table: "Tokens",
                type: "uuid",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "AccountId",
                table: "Tokens");
        }
    }
}
