import 'dart:io';

import 'package:maat/maat.dart';
import 'package:seshat_maat/seshat_maat.dart';
import 'package:test/test.dart';

Future<Application> buildApp(Map<String, dynamic> database) async {
  final dir = Directory.systemTemp.createTempSync('dbprov');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/.env').writeAsStringSync('APP_ENV=testing\n');

  return Application.configure(basePath: dir.path, environment: {})
      .withConfig({
        'app': {'name': 'Test', 'debug': true},
        'database': database,
      })
      .withProviders([DatabaseServiceProvider.new])
      .create();
}

void main() {
  tearDown(() {
    DB.reset();
    Application.reset();
  });

  test('opens the default connection and installs it on DB', () async {
    await buildApp({
      'default': 'sqlite',
      'connections': {
        'sqlite': {'driver': 'sqlite', 'database': ':memory:'},
      },
    });

    expect(DB.hasConnection, isTrue);

    await DB.statement('create table t (id integer primary key, name text)');
    await DB.table('t').insert({'name': 'ada'});
    expect(await DB.table('t').count(), 1);
  });

  test('binds the Connection in the container', () async {
    final app = await buildApp({
      'default': 'sqlite',
      'connections': {
        'sqlite': {'driver': 'sqlite', 'database': ':memory:'},
      },
    });

    expect(app.make<Connection>(), same(DB.connection));
  });

  test('application shutdown closes the database connection', () async {
    final app = await buildApp({
      'default': 'sqlite',
      'connections': {
        'sqlite': {'driver': 'sqlite', 'database': ':memory:'},
      },
    });
    final connection = app.make<Connection>();

    await app.shutdown();

    await expectLater(
      connection.select('select 1'),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('an application with no database config still boots', () async {
    final dir = Directory.systemTemp.createTempSync('nodb');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/.env').writeAsStringSync('APP_ENV=testing\n');

    final app = await Application.configure(basePath: dir.path, environment: {})
        .withConfig({
          'app': {'name': 'Test'},
        })
        .withProviders([DatabaseServiceProvider.new])
        .create();

    expect(app.environment, 'testing');
    expect(DB.hasConnection, isFalse);
  });

  test(
    'names the missing connection when one is configured but absent',
    () async {
      await expectLater(
        () => buildApp({'default': 'nope', 'connections': {}}),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('nope'),
          ),
        ),
      );
    },
  );

  test('names the driver and how to register it when unknown', () async {
    await expectLater(
      () => buildApp({
        'default': 'weird',
        'connections': {
          'weird': {'driver': 'weird'},
        },
      }),
      throwsA(
        isA<Exception>()
            .having((e) => e.toString(), 'message', contains('weird'))
            .having(
              (e) => e.toString(),
              'message',
              contains('DatabaseServiceProvider.extend'),
            ),
      ),
    );
  });

  test('a registered adapter is used for its driver name', () async {
    var called = false;
    DatabaseServiceProvider.extend('fake', (config) async {
      called = true;
      return SqliteConnection.open(':memory:');
    });
    addTearDown(() => DatabaseServiceProvider.resetExtensions());

    await buildApp({
      'default': 'fake',
      'connections': {
        'fake': {'driver': 'fake'},
      },
    });

    expect(called, isTrue);
    expect(DB.hasConnection, isTrue);
  });
}
