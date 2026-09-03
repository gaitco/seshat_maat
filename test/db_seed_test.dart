import 'package:maat/maat.dart';
import 'package:maat_seshat/maat_seshat.dart';
import 'package:test/test.dart';

import 'support/test_application.dart';

class DatabaseSeeder extends Seeder {
  DatabaseSeeder(this._onRun);

  final void Function() _onRun;

  @override
  Future<void> run() async => _onRun();
}

class _UserSeeder extends Seeder {
  _UserSeeder(this._onRun);

  final void Function() _onRun;

  @override
  Future<void> run() async => _onRun();
}

void main() {
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() => Application.reset());

  test('runs the seeder matching --class and reports it', () async {
    var ran = false;
    final app = await buildTestApplication();
    final maat = Sesh(
      app,
      out: out,
      err: err,
      commands: databaseCommands(seeders: [_UserSeeder(() => ran = true)]),
    );

    expect(await maat.run(['db:seed', '--class=_UserSeeder']), 0);
    expect(ran, isTrue);
    expect(out.toString(), contains('Seeded: _UserSeeder'));
  });

  test('defaults to --class=DatabaseSeeder', () async {
    var ran = false;
    final app = await buildTestApplication();
    final maat = Sesh(
      app,
      out: out,
      err: err,
      commands: databaseCommands(seeders: [DatabaseSeeder(() => ran = true)]),
    );

    expect(await maat.run(['db:seed']), 0);
    expect(ran, isTrue);
  });

  test(
    'lists the registered seeder names when --class does not match',
    () async {
      final app = await buildTestApplication();
      final maat = Sesh(
        app,
        out: out,
        err: err,
        commands: databaseCommands(seeders: [_UserSeeder(() {})]),
      );

      expect(await maat.run(['db:seed', '--class=Nope']), 1);
      expect(err.toString(), contains('Nope'));
      expect(err.toString(), contains('_UserSeeder'));
    },
  );

  test('says no seeders are registered when the list is empty', () async {
    final app = await buildTestApplication();
    final maat = Sesh(app, out: out, err: err, commands: databaseCommands());

    expect(await maat.run(['db:seed']), 1);
    expect(err.toString(), contains('No seeders are registered'));
  });

  test('refuses to run in production without --force', () async {
    var ran = false;
    final app = await buildTestApplication(environment: 'production');
    final maat = Sesh(
      app,
      out: out,
      err: err,
      commands: databaseCommands(seeders: [DatabaseSeeder(() => ran = true)]),
    );

    expect(await maat.run(['db:seed']), 1);
    expect(err.toString(), contains('production'));
    expect(ran, isFalse);

    expect(await maat.run(['db:seed', '--force']), 0);
    expect(ran, isTrue);
  });
}
