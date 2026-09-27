internal import GRDB

enum Schema {
    /// Version of the materialized tables, kept in `PRAGMA user_version`. When it changes, the
    /// tables are dropped and rebuilt by replaying the log (design.md §5.4); no migration code.
    static let materializedVersion = 2

    /// Migrations for the op log and device-local tables only.
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try createLog(db)
        }
        return migrator
    }

    static let materializedTables = [
        "posting", "balance", "balance_assertion", "price", "conflict_dismissal", "setting", "entry", "account",
        "commodity",
    ]

    /// Drops and recreates the materialized tables if their version changed. Returns whether
    /// they need to be rebuilt from the log.
    static func prepareMaterialized(_ db: Database) throws -> Bool {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard version != materializedVersion else { return false }
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        for table in materializedTables {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
        try createMaterialized(db)
        try db.execute(sql: "PRAGMA user_version = \(materializedVersion)")
        return true
    }

    /// The op log and device-local bookkeeping. Changes here need real migrations.
    static func createLog(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE op (
              id           TEXT PRIMARY KEY,
              status       TEXT NOT NULL CHECK (status IN ('main', 'pending')),
              seq          INTEGER UNIQUE,
              local_order  INTEGER,
              body         BLOB NOT NULL,
              resolution   BLOB,
              kind         TEXT NOT NULL,
              target       TEXT NOT NULL,
              version      INTEGER NOT NULL,
              prev_hash    BLOB,
              state_digest BLOB,
              hash         BLOB
            );
            CREATE INDEX op_by_target ON op(target, seq);

            CREATE TABLE op_undo (
              op_id   TEXT NOT NULL,
              step    INTEGER NOT NULL,
              tbl     TEXT NOT NULL,
              row_key TEXT NOT NULL,
              before  BLOB,
              PRIMARY KEY (op_id, step)
            );

            CREATE TABLE market_price (
              base_id    TEXT NOT NULL,
              quote_id   TEXT NOT NULL,
              date       TEXT NOT NULL,
              rate       TEXT NOT NULL,
              provider   TEXT NOT NULL,
              fetched_at TEXT NOT NULL,
              PRIMARY KEY (base_id, quote_id, date, provider)
            ) WITHOUT ROWID;

            CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
            """)
    }

    /// Tables derived from the op log. They can always be dropped and rebuilt by replay.
    static func createMaterialized(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE commodity (
              id       TEXT PRIMARY KEY,
              code     TEXT NOT NULL,
              kind     TEXT NOT NULL,
              scale    INTEGER NOT NULL,
              name     TEXT,
              quote_id TEXT REFERENCES commodity(id),
              feed     TEXT,
              archived INTEGER NOT NULL DEFAULT 0,
              rev      TEXT NOT NULL
            );
            CREATE INDEX commodity_by_code ON commodity(code);

            CREATE TABLE account (
              id          TEXT PRIMARY KEY,
              parent_id   TEXT REFERENCES account(id),
              name        TEXT NOT NULL,
              type        TEXT NOT NULL,
              role        TEXT,
              opened_on   TEXT NOT NULL,
              closed_on   TEXT,
              archived    INTEGER NOT NULL DEFAULT 0,
              deleted     INTEGER NOT NULL DEFAULT 0,
              merged_into TEXT REFERENCES account(id),
              sort_order  INTEGER NOT NULL DEFAULT 0,
              note        TEXT,
              rev         TEXT NOT NULL
            );
            CREATE INDEX account_by_parent ON account(parent_id);

            CREATE TABLE entry (
              id         TEXT PRIMARY KEY,
              date       TEXT NOT NULL,
              created_at TEXT NOT NULL,
              payee      TEXT,
              memo       TEXT,
              rev        TEXT NOT NULL
            );
            CREATE INDEX entry_by_date ON entry(date, created_at, id);

            -- account_id is as authored; resolved_account_id follows merges and is what
            -- balances and registers use. Merging rewrites only the resolved column.
            -- date and created_at copy the entry's, so registers read from one index in order.
            CREATE TABLE posting (
              entry_id            TEXT NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
              idx                 INTEGER NOT NULL,
              date                TEXT NOT NULL,
              created_at          TEXT NOT NULL,
              account_id          TEXT NOT NULL REFERENCES account(id),
              resolved_account_id TEXT NOT NULL REFERENCES account(id),
              commodity_id        TEXT NOT NULL REFERENCES commodity(id),
              amount              INTEGER NOT NULL,
              PRIMARY KEY (entry_id, idx)
            ) WITHOUT ROWID;
            CREATE INDEX posting_by_account
              ON posting(resolved_account_id, date, created_at, entry_id, commodity_id, amount);
            CREATE INDEX posting_by_date ON posting(date, resolved_account_id, commodity_id, amount);

            -- Current balance of every account, kept by triggers so reading all balances
            -- doesn't aggregate every posting.
            CREATE TABLE balance (
              account_id   TEXT NOT NULL,
              commodity_id TEXT NOT NULL,
              amount       INTEGER NOT NULL,
              PRIMARY KEY (account_id, commodity_id)
            ) WITHOUT ROWID;
            CREATE TRIGGER posting_inserted AFTER INSERT ON posting BEGIN
              INSERT INTO balance (account_id, commodity_id, amount)
              VALUES (NEW.resolved_account_id, NEW.commodity_id, NEW.amount)
              ON CONFLICT (account_id, commodity_id) DO UPDATE SET amount = amount + excluded.amount;
            END;
            CREATE TRIGGER posting_deleted AFTER DELETE ON posting BEGIN
              UPDATE balance SET amount = amount - OLD.amount
              WHERE account_id = OLD.resolved_account_id AND commodity_id = OLD.commodity_id;
            END;
            CREATE TRIGGER posting_moved AFTER UPDATE OF resolved_account_id, commodity_id, amount ON posting BEGIN
              UPDATE balance SET amount = amount - OLD.amount
              WHERE account_id = OLD.resolved_account_id AND commodity_id = OLD.commodity_id;
              INSERT INTO balance (account_id, commodity_id, amount)
              VALUES (NEW.resolved_account_id, NEW.commodity_id, NEW.amount)
              ON CONFLICT (account_id, commodity_id) DO UPDATE SET amount = amount + excluded.amount;
            END;

            CREATE TABLE price (
              id       TEXT PRIMARY KEY,
              base_id  TEXT NOT NULL REFERENCES commodity(id),
              quote_id TEXT NOT NULL REFERENCES commodity(id),
              date     TEXT NOT NULL,
              rate     TEXT NOT NULL,
              rev      TEXT NOT NULL
            );
            CREATE INDEX price_by_pair ON price(base_id, quote_id, date);

            CREATE TABLE balance_assertion (
              id           TEXT PRIMARY KEY,
              account_id   TEXT NOT NULL REFERENCES account(id),
              commodity_id TEXT NOT NULL REFERENCES commodity(id),
              date         TEXT NOT NULL,
              amount       INTEGER NOT NULL,
              rev          TEXT NOT NULL
            );
            CREATE INDEX balance_assertion_by_account ON balance_assertion(account_id, date);

            CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL, rev TEXT NOT NULL);

            CREATE TABLE conflict_dismissal (op_id TEXT PRIMARY KEY);
            """)
    }
}
