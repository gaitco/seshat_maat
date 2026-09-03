import 'package:maat_seshat_core/maat_seshat_core.dart';
import 'package:maat_seshat_core/postgres.dart';
import 'package:maat_seshat_core/sqlite.dart';
import 'package:maat/maat.dart';

import 'routing/model_binding.dart';
import 'validation/database_rules.dart';

/// Opens a connection from a `config('database')` entry.
typedef ConnectionFactory =
    Future<Connection> Function(Map<String, dynamic> config);

/// Maps a `config('database.connections.pgsql')` entry to the arguments
/// `PostgresConnection.open` accepts.
///
/// Pulled out as a pure function, separate from the factory that calls it,
/// so the mapping — in particular that `ssl` is actually forwarded — is
/// testable without opening a socket.
///
/// `PostgresConnection.open` only has an on/off `ssl` switch (it always
/// requires TLS when on, never verifies a certificate), so any value other
/// than `'disable'` — `'require'`, `'verify-full'`, whatever an operator
/// writes — turns it on. `'disable'` is the only value that turns it off.
({
  String host,
  int port,
  String database,
  String? username,
  String? password,
  bool ssl,
  int maxConnections,
})
pgsqlConnectionArgs(Map config) => (
  host: (config['host'] ?? '127.0.0.1') as String,
  port: (config['port'] ?? 5432) as int,
  database: config['database'] as String,
  username: config['username'] as String?,
  password: config['password'] as String?,
  ssl: config['ssl'] != null && config['ssl'] != 'disable',
  maxConnections: ((config['pool'] as Map?)?['max'] ?? 5) as int,
);

/// Reads `config('database')`, opens the default connection and installs it as
/// the process-wide default, so applications configure a database in `.env`
/// rather than in code.
///
/// An application with no `database` config boots normally with no connection —
/// an API-only application must not be forced to have a database.
class DatabaseServiceProvider extends ServiceProvider {
  DatabaseServiceProvider(super.app);

  static final Map<String, ConnectionFactory> _factories = {
    'sqlite': (config) async =>
        SqliteConnection.open((config['database'] ?? ':memory:') as String),
    'pgsql': (config) async {
      final args = pgsqlConnectionArgs(config);
      return PostgresConnection.open(
        host: args.host,
        port: args.port,
        database: args.database,
        username: args.username,
        password: args.password,
        ssl: args.ssl,
        maxConnections: args.maxConnections,
      );
    },
  };

  Connection? _connection;

  /// Registers an adapter for a driver name, so a package outside this one can
  /// add a dialect without editing it.
  static void extend(String driver, ConnectionFactory factory) =>
      _factories[driver] = factory;

  /// Drops every registered adapter back to the built-in pair (tests).
  static void resetExtensions() {
    _factories.removeWhere((key, _) => key != 'sqlite' && key != 'pgsql');
  }

  /// Runs before [boot], and deliberately so: registering the rules only puts
  /// closures in a map, and those closures resolve the connection when a
  /// request is validated — long after [boot] has opened it.
  @override
  void register() {
    registerDatabaseRules();
    // Laravel registers SubstituteBindings for the framework and lets the
    // application put it in a route group. Same here: the alias exists from
    // boot, and a route opts in with `.middleware(['bindings'])`.
    this.app.make<MiddlewareConfig>().alias({
      'bindings': ModelBinding.middleware(),
    });
  }

  @override
  Future<void> boot() async {
    final settings = this.app.config.get('database');
    if (settings is! Map) {
      return;
    }

    final name = (settings['default'] ?? 'sqlite') as String;
    final connections = (settings['connections'] ?? const {}) as Map;
    final entry = connections[name];
    if (entry == null) {
      throw ConnectionException(
        'No connection named "$name" in config("database.connections").',
      );
    }

    final options = Map<String, dynamic>.from(entry as Map);
    final driver = (options['driver'] ?? name) as String;
    final factory = _factories[driver];
    if (factory == null) {
      throw ConnectionException(
        'No adapter registered for driver "$driver". Register one with '
        'DatabaseServiceProvider.extend("$driver", ...) before creating the '
        'application.',
      );
    }

    final connection = await factory(options);
    _connection = connection;
    DB.use(connection);
    this.app.instance<Connection>(connection);
  }

  @override
  Future<void> shutdown() => _connection?.close() ?? Future.value();
}
