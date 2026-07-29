using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FatVpn.Bff.Infrastructure.Migrations
{
    /// <summary>
    /// Moves the device cap off the code row and onto the subscription.
    ///
    /// Slots used to be keyed by <c>TokenId</c> — one row per code the bot ever
    /// handed out — while a user's "key" is the subscription behind it. A single
    /// subscription accumulates a new code row every time the bot shows its
    /// screen, and each of those carried its own three slots, so four codes meant
    /// twelve devices.
    ///
    /// The scaffolded version of this dropped TokenId before anything was copied
    /// out of it, which would have thrown away every existing binding.
    /// </summary>
    public partial class DeviceSlotsPerSubscription : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "SubscriptionId",
                table: "TokenDevices",
                type: "text",
                nullable: false,
                defaultValue: "");

            migrationBuilder.AddColumn<string>(
                name: "DeviceKeyHash",
                table: "PairingCodes",
                type: "text",
                nullable: true);

            migrationBuilder.Sql(
                """
                UPDATE "TokenDevices" td
                   SET "SubscriptionId" = t."RemnawaveSubscriptionId"
                  FROM "Tokens" t
                 WHERE t."Id" = td."TokenId";
                """);

            // A slot whose code row is gone, or that never named a subscription,
            // describes nothing and would collide with every other such row on the
            // new unique index.
            migrationBuilder.Sql("""DELETE FROM "TokenDevices" WHERE "SubscriptionId" = '';""");

            // The same phone could hold a slot on several codes of one
            // subscription. Collapse those to one row, keeping the freshest.
            migrationBuilder.Sql(
                """
                DELETE FROM "TokenDevices" td
                 USING "TokenDevices" other
                 WHERE td."SubscriptionId" = other."SubscriptionId"
                   AND td."DeviceKeyHash" = other."DeviceKeyHash"
                   AND (td."LastSeenAt" < other."LastSeenAt"
                        OR (td."LastSeenAt" = other."LastSeenAt" AND td."Id" < other."Id"));
                """);

            // Merging several codes' slot sets can leave a subscription over the
            // cap. Keep the three most recently seen — 3 is the shipped default of
            // Auth:MaxDevicesPerKey, and a one-off historical fix cannot read
            // configuration. Anything over the runtime's cap would be evicted on
            // the next arrival anyway; this just avoids leaving rows that no
            // admission path can ever reach.
            migrationBuilder.Sql(
                """
                WITH ranked AS (
                    SELECT "Id",
                           row_number() OVER (PARTITION BY "SubscriptionId"
                                              ORDER BY "LastSeenAt" DESC, "Id") - 1 AS rn
                      FROM "TokenDevices"
                )
                DELETE FROM "TokenDevices" td
                 USING ranked
                 WHERE td."Id" = ranked."Id" AND ranked.rn >= 3;
                """);

            // Slot numbers were unique per code; per subscription they may now
            // repeat. Renumber from zero so the admission loop can find them.
            migrationBuilder.Sql(
                """
                WITH ranked AS (
                    SELECT "Id",
                           row_number() OVER (PARTITION BY "SubscriptionId"
                                              ORDER BY "LastSeenAt" DESC, "Id") - 1 AS rn
                      FROM "TokenDevices"
                )
                UPDATE "TokenDevices" td
                   SET "SlotIndex" = ranked.rn
                  FROM ranked
                 WHERE td."Id" = ranked."Id";
                """);

            migrationBuilder.DropIndex(
                name: "IX_TokenDevices_TokenId_DeviceKeyHash",
                table: "TokenDevices");

            migrationBuilder.DropIndex(
                name: "IX_TokenDevices_TokenId_SlotIndex",
                table: "TokenDevices");

            migrationBuilder.DropColumn(
                name: "TokenId",
                table: "TokenDevices");

            migrationBuilder.CreateIndex(
                name: "IX_TokenDevices_SubscriptionId_DeviceKeyHash",
                table: "TokenDevices",
                columns: new[] { "SubscriptionId", "DeviceKeyHash" },
                unique: true);

            migrationBuilder.CreateIndex(
                name: "IX_TokenDevices_SubscriptionId_SlotIndex",
                table: "TokenDevices",
                columns: new[] { "SubscriptionId", "SlotIndex" },
                unique: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_TokenDevices_SubscriptionId_DeviceKeyHash",
                table: "TokenDevices");

            migrationBuilder.DropIndex(
                name: "IX_TokenDevices_SubscriptionId_SlotIndex",
                table: "TokenDevices");

            migrationBuilder.AddColumn<Guid>(
                name: "TokenId",
                table: "TokenDevices",
                type: "uuid",
                nullable: false,
                defaultValue: new Guid("00000000-0000-0000-0000-000000000000"));

            // Going back cannot restore which code a slot belonged to — several
            // may have pointed at the same subscription. Drop the rows rather than
            // pin them all to the zero Guid, where the unique index would collapse
            // them to one anyway.
            migrationBuilder.Sql("""DELETE FROM "TokenDevices";""");

            migrationBuilder.DropColumn(
                name: "SubscriptionId",
                table: "TokenDevices");

            migrationBuilder.DropColumn(
                name: "DeviceKeyHash",
                table: "PairingCodes");

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
        }
    }
}
