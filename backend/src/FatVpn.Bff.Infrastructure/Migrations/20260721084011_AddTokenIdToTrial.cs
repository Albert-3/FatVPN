using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FatVpn.Bff.Infrastructure.Migrations
{
    /// <inheritdoc />
    public partial class AddTokenIdToTrial : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<Guid>(
                name: "TokenId",
                table: "Trials",
                type: "uuid",
                nullable: false,
                defaultValue: new Guid("00000000-0000-0000-0000-000000000000"));

            // Back-fill existing rows: GrantTrial always set Trial.GrantedAt ==
            // Token.CreatedAt and Trial.ExpiresAt == Token.ExpiresAt in the same
            // save, so that pair uniquely identifies the token a pre-existing
            // trial belongs to.
            migrationBuilder.Sql(
                """
                UPDATE "Trials" t
                SET "TokenId" = tok."Id"
                FROM "Tokens" tok
                WHERE t."TokenId" = '00000000-0000-0000-0000-000000000000'
                  AND tok."CreatedAt" = t."GrantedAt"
                  AND tok."ExpiresAt" = t."ExpiresAt";
                """);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "TokenId",
                table: "Trials");
        }
    }
}
