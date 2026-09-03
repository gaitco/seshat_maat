# Seshat ORM

<p align="center"><img src="assets/icon.svg" width="96" alt="Seshat icon"></p>

Wires the [`maat_seshat_core`](https://github.com/gaitco/maat_seshat_core) ORM into the Maat framework.

`maat` (the HTTP framework) depends only on `shelf`, `args` and
`path` — an API-only application must not be forced to resolve database
drivers. This package is the glue: it depends on both `maat` and
`maat_seshat_core` and gives you one provider to register.

## Usage

```dart
import 'package:maat/maat.dart';
import 'package:maat_seshat/maat_seshat.dart';

final app = await Application.configure(basePath: Directory.current.path)
    .withConfig({
      'database': {
        'default': 'sqlite',
        'connections': {
          'sqlite': {'driver': 'sqlite', 'database': 'storage/app.sqlite'},
        },
      },
    })
    .withProviders([DatabaseServiceProvider.new])
    .create();
```

`DatabaseServiceProvider.boot()` reads `config('database')`, opens the
connection named by `database.default`, installs it on the `DB` facade via
`DB.use(...)`, and binds it in the container so `app.make<Connection>()`
resolves it too. An application with no `database` config boots normally
with no connection.

Ships adapters for `sqlite` and `pgsql`. Register another driver (e.g. a
third-party MySQL adapter) without editing this package:

```dart
DatabaseServiceProvider.extend('mysql', (config) async {
  return MySqlConnection.open(...);
});
```

Re-exports `package:maat_seshat_core/maat_seshat_core.dart`,
`package:maat_seshat_core/sqlite.dart` and `package:maat_seshat_core/postgres.dart`,
so `DB`, `Schema`, `Migration`, `SqliteConnection` and `PostgresConnection`
all resolve from `package:maat_seshat/maat_seshat.dart` — one
import instead of three.
