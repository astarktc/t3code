// Run by fork-infra/dry-run-migrations.sh, which copies this file into
// apps/server/src/persistence/ for the run and removes it afterwards. Never commit it there.
//
// Opens FORK_DRYRUN_DB through the server's own startup layer (layerFromPath: the same
// pragmas, migrations and stat cleanup as a real launch) and reports the ledger, schema
// size and integrity before and after, plus how long startup migration took.
import { describe, it } from "@effect/vitest";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as NodeSqliteClient from "@t3tools/shared/nodeSqliteClient";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as SqlClient from "effect/sql/SqlClient";

import { layerFromPath } from "./Sqlite.ts";

const dbPath = process.env.FORK_DRYRUN_DB ?? "";

const probe = Effect.gen(function* () {
  const sql = yield* SqlClient.SqlClient;
  const ledger = yield* sql<{ migration_id: number; name: string }>`
    SELECT migration_id, name FROM effect_sql_migrations ORDER BY migration_id DESC LIMIT 3`;
  const tables = yield* sql<{ n: number }>`
    SELECT COUNT(*) AS n FROM sqlite_schema WHERE type = 'table'`;
  const pages = yield* sql<{ page_count: number }>`PRAGMA page_count`;
  const free = yield* sql<{ freelist_count: number }>`PRAGMA freelist_count`;
  return {
    ledger: ledger.map((row) => `${row.migration_id}=${row.name}`).join(", "),
    tables: tables[0]?.n,
    pages: pages[0]?.page_count,
    freePages: free[0]?.freelist_count,
  };
});

describe("fork-infra migration dry run", () => {
  it.effect(
    "migrates the copy",
    () =>
      Effect.scoped(
        Effect.gen(function* () {
          if (dbPath === "") return yield* Effect.die("set FORK_DRYRUN_DB");
          const before = yield* probe.pipe(
            Effect.provide(NodeSqliteClient.layer({ filename: dbPath, readonly: true })),
          );
          console.log("BEFORE", JSON.stringify(before));
          const startedAt = Date.now();
          const context = yield* Layer.build(layerFromPath(dbPath));
          console.log("MIGRATED_MS", Date.now() - startedAt);
          const sql = Context.get(context, SqlClient.SqlClient);
          console.log(
            "AFTER",
            JSON.stringify(yield* probe.pipe(Effect.provideService(SqlClient.SqlClient, sql))),
          );
          const checkStartedAt = Date.now();
          const check = yield* sql<{ integrity_check: string }>`PRAGMA integrity_check`;
          console.log(
            "INTEGRITY",
            check.map((row) => row.integrity_check).join("; "),
            `${Date.now() - checkStartedAt}ms`,
          );
        }),
      ).pipe(Effect.provide(NodeServices.layer)),
    3_600_000,
  );
});
