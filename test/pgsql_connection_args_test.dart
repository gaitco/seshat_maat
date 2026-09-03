import 'package:seshat_maat/seshat_maat.dart';
import 'package:test/test.dart';

/// `ptah`'s skeleton ships `ssl` and `pool` alongside the
/// pgsql connection basics. `PostgresConnection.open` has no pooling
/// concept at all, so `pool` was dropped from the skeleton (see
/// `config/database.dart`); `ssl`, though, is real — it just wasn't being
/// forwarded. `pgsqlConnectionArgs` is the pure argument mapping the
/// `pgsql` factory calls before ever opening a socket, so this proves the
/// value survives the mapping with no server involved.
void main() {
  test('forwards ssl:true for any value other than disable', () {
    for (final value in ['require', 'verify-full', 'prefer', 'anything']) {
      expect(
        pgsqlConnectionArgs({'database': 'd', 'ssl': value}).ssl,
        isTrue,
        reason: value,
      );
    }
  });

  test('forwards ssl:false for disable, and when ssl is absent', () {
    expect(
      pgsqlConnectionArgs({'database': 'd', 'ssl': 'disable'}).ssl,
      isFalse,
    );
    expect(pgsqlConnectionArgs({'database': 'd'}).ssl, isFalse);
  });

  test('carries the rest of the skeleton-shaped config through untouched', () {
    final args = pgsqlConnectionArgs({
      'driver': 'pgsql',
      'host': 'db.internal',
      'port': 5433,
      'database': 'maat',
      'username': 'app',
      'password': 's3cret',
      'ssl': 'require',
    });

    expect(args.host, 'db.internal');
    expect(args.port, 5433);
    expect(args.database, 'maat');
    expect(args.username, 'app');
    expect(args.password, 's3cret');
    expect(args.ssl, isTrue);
  });

  test('reads pool.max and defaults to five connections', () {
    expect(
      pgsqlConnectionArgs({
        'database': 'd',
        'pool': {'max': 12},
      }).maxConnections,
      12,
    );
    expect(pgsqlConnectionArgs({'database': 'd'}).maxConnections, 5);
  });
}
