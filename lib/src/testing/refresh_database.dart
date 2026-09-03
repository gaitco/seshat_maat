import 'package:seshat/seshat.dart';
import 'package:seshat/sqlite.dart';

/// Laravel's `RefreshDatabase`, for `package:test`: a fresh in-memory SQLite
/// database migrated once, emptied after every test so no row leaks into the
/// next one. The schema is migrated once, not per test.
///
/// It hands the hooks back instead of registering them, so this package needs
/// no dependency on a test runner — wire them in your `main()`:
///
/// ```dart
/// void main() {
///   final db = RefreshDatabase(migrations: [CreateWidgetsTable()]);
///   setUpAll(db.migrate);
///   tearDown(db.truncate);
///   tearDownAll(db.close); // optional
///
///   test('inserts a widget', () async {
///     await DB.table('widgets').insert({'name': 'wrench'});
///     expect(await DB.table('widgets').count(), 1);
///   });
/// }
/// ```
///
// ponytail: Laravel wraps each test in a transaction and rolls it back, which
// is faster and resets sequences for free. `Connection` exposes only the
// callback form `transaction(body)` — no raw begin/rollback — and a callback
// scope cannot span package:test's separate setUp / body / tearDown calls, so
// [truncate] deletes rows instead. If `Connection` ever gains begin/rollback,
// [truncate] becomes a rollback.
class RefreshDatabase {
  RefreshDatabase({this.migrations = const []});

  final List<Migration> migrations;

  /// The database [migrate] opened. `late final`, so calling [truncate] or
  /// [close] before [migrate] — or wiring [migrate] to `setUp` instead of
  /// `setUpAll` — fails loudly instead of quietly operating on whatever
  /// connection `DB` happens to hold.
  late final Connection _connection;

  /// Opens the database, makes it the default connection and migrates it.
  /// Wire into `setUpAll`.
  Future<void> migrate() async {
    _connection = SqliteConnection.inMemory();
    DB.use(_connection);
    await Migrator(_connection, migrations).run();
  }

  /// Deletes every row from every table except the migrator's own
  /// bookkeeping, keeping the schema, and resets autoincrement counters so
  /// ids restart at 1. Wire into `tearDown`.
  ///
  /// Deletion runs inside a transaction with `defer_foreign_keys` on, so
  /// tables can be emptied in any order: constraints are checked at commit,
  /// by which point every table is empty. The pragma is transaction-scoped
  /// and SQLite clears it on commit or rollback, so enforcement cannot stay
  /// off. `pragma foreign_keys = off` would NOT work here — SQLite ignores it
  /// inside a transaction.
  Future<void> truncate() async {
    const bookkeeping = 'migrations';
    final connection = _connection;
    final schema = Schema.on(connection);
    final rows = await connection.select(schema.grammar.compileTableListing());
    final tables = [
      for (final row in rows)
        if (row.values.first case final String name when name != bookkeeping)
          name,
    ];

    await connection.transaction((tx) async {
      await tx.execute('pragma defer_foreign_keys = on');
      for (final table in tables) {
        await tx.execute('delete from ${connection.grammar.wrapTable(table)}');
      }
      if (await schema.hasTable('sqlite_sequence')) {
        await tx.execute('delete from sqlite_sequence where name != ?', [
          bookkeeping,
        ]);
      }
    });
  }

  /// Closes the database and forgets it as the default connection. Wire into
  /// `tearDownAll` when a suite shares its isolate with other database tests.
  Future<void> close() async {
    await _connection.close();
    DB.reset();
  }
}
