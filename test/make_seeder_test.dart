import 'dart:io';

import 'package:maat/maat.dart';
import 'package:seshat_maat/seshat_maat.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_application.dart';

void main() {
  late Directory root;
  late Sesh maat;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('makeseed');
    out = StringBuffer();
    err = StringBuffer();
    final app = await buildTestApplication(basePath: root.path);
    maat = Sesh(app, out: out, err: err, commands: databaseCommands());
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    Application.reset();
  });

  String read(String relative) =>
      File(p.join(root.path, relative)).readAsStringSync();

  test('writes a seeder class', () async {
    expect(await maat.run(['make:seeder', 'UserSeeder']), 0);

    final code = read('database/seeders/user_seeder.dart');
    expect(code, contains("import 'package:seshat_maat/seshat_maat.dart';"));
    expect(code, contains('class UserSeeder extends Seeder'));
    expect(code, contains('Future<void> run() async {}'));
    expect(out.toString(), contains('created successfully'));
  });

  test('refuses to overwrite unless --force', () async {
    await maat.run(['make:seeder', 'UserSeeder']);

    expect(await maat.run(['make:seeder', 'UserSeeder']), 1);
    expect(err.toString(), contains('already exists'));

    expect(await maat.run(['make:seeder', 'UserSeeder', '--force']), 0);
  });
}
