import 'package:maat/maat.dart';
import 'package:maat_seshat/maat_seshat.dart';
import 'package:test/test.dart';

import 'support/test_application.dart';

class CreateUsersTable extends Migration {
  @override
  String get name => '2026_09_02_000001_create_users_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('users', (t) {
    t.id();
    t.string('email');
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('users');
}

class CreatePostsTable extends Migration {
  @override
  String get name => '2026_09_02_000002_create_posts_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('posts', (t) {
    t.id();
    t.string('title');
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('posts');
}

class AddBioToUsers extends Migration {
  @override
  String get name => '2026_09_02_000003_add_bio_to_users';

  @override
  Future<void> up(SchemaBuilder schema) =>
      schema.table('users', (t) => t.string('bio').nullable());

  @override
  Future<void> down(SchemaBuilder schema) =>
      schema.table('users', (t) => t.dropColumn('bio'));
}

/// A migration whose down() is broken — the exact case that motivates
/// migrate:fresh actually dropping tables rather than rolling back.
class CreateTagsTableWithBrokenDown extends Migration {
  @override
  String get name => '2026_09_02_000004_create_tags_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('tags', (t) {
    t.id();
    t.string('label');
  });

  @override
  Future<void> down(SchemaBuilder schema) => throw StateError('down is broken');
}

class _RecordingSeeder extends Seeder {
  _RecordingSeeder(this._onRun);

  final void Function() _onRun;

  @override
  Future<void> run() async => _onRun();
}

void main() {
  late StringBuffer out;
  late StringBuffer err;
  late Sesh maat;
  late Application app;

  final migrations = [CreateUsersTable(), CreatePostsTable()];

  setUp(() async {
    DB.use(SqliteConnection.open(':memory:'));
    out = StringBuffer();
    err = StringBuffer();
    app = await buildTestApplication();
    maat = Sesh(
      app,
      out: out,
      err: err,
      commands: databaseCommands(migrations: migrations),
    );
  });

  tearDown(() async {
    await DB.connection.close();
    DB.reset();
    Application.reset();
  });

  test('migrate runs every pending migration and reports each', () async {
    expect(await maat.run(['migrate']), 0);

    expect(out.toString(), contains('create_users_table'));
    expect(out.toString(), contains('create_posts_table'));
    expect(await Schema.hasTable('users'), isTrue);
    expect(await Schema.hasTable('posts'), isTrue);
  });

  test('migrate is idempotent', () async {
    await maat.run(['migrate']);
    out.clear();

    expect(await maat.run(['migrate']), 0);
    expect(out.toString(), contains('Nothing to migrate'));
  });

  test('migrate:status lists ran and pending migrations', () async {
    await maat.run(['migrate']);
    out.clear();

    expect(await maat.run(['migrate:status']), 0);
    expect(out.toString(), contains('Ran'));
    expect(out.toString(), contains('create_users_table'));
  });

  test('migrate:rollback reverses the last batch', () async {
    await maat.run(['migrate']);

    expect(await maat.run(['migrate:rollback']), 0);
    expect(await Schema.hasTable('users'), isFalse);
    expect(await Schema.hasTable('posts'), isFalse);
  });

  test('migrate:rollback --step=1 unwinds only the last batch', () async {
    await maat.run(['migrate']); // batch 1: users, posts
    final withThird = [...migrations, AddBioToUsers()];
    final maat2 = Sesh(
      app,
      out: out,
      err: err,
      commands: databaseCommands(migrations: withThird),
    );
    await maat2.run(['migrate']); // batch 2: bio column
    expect(await Schema.hasColumn('users', 'bio'), isTrue);

    out.clear();
    expect(await maat2.run(['migrate:rollback', '--step=1']), 0);
    expect(out.toString(), contains('Rolled back'));
    expect(await Schema.hasColumn('users', 'bio'), isFalse);
    expect(await Schema.hasTable('users'), isTrue);
    expect(await Schema.hasTable('posts'), isTrue);
  });

  test('migrate:rollback --step=2 unwinds both batches', () async {
    await maat.run(['migrate']); // batch 1: users, posts
    final withThird = [...migrations, AddBioToUsers()];
    final maat2 = Sesh(
      app,
      out: out,
      err: err,
      commands: databaseCommands(migrations: withThird),
    );
    await maat2.run(['migrate']); // batch 2: bio column

    expect(await maat2.run(['migrate:rollback', '--step=2']), 0);
    expect(await Schema.hasTable('users'), isFalse);
    expect(await Schema.hasTable('posts'), isFalse);
  });

  test(
    'migrate:rollback with a malformed --step falls back to one batch',
    () async {
      await maat.run(['migrate']); // batch 1: users, posts
      final withThird = [...migrations, AddBioToUsers()];
      final maat2 = Sesh(
        app,
        out: out,
        err: err,
        commands: databaseCommands(migrations: withThird),
      );
      await maat2.run(['migrate']); // batch 2: bio column

      expect(await maat2.run(['migrate:rollback', '--step=abc']), 0);
      // Fell back to 1: only batch 2 (the bio column) unwound.
      expect(await Schema.hasColumn('users', 'bio'), isFalse);
      expect(await Schema.hasTable('users'), isTrue);
      expect(await Schema.hasTable('posts'), isTrue);
    },
  );

  test('migrate:fresh drops and re-runs', () async {
    await maat.run(['migrate']);
    await DB.table('users').insert({'email': 'a@b.c'});

    expect(await maat.run(['migrate:fresh']), 0);
    expect(await Schema.hasTable('users'), isTrue);
    expect(await DB.table('users').count(), 0);
  });

  test('migrate:fresh succeeds despite a broken down() and drops orphaned '
      'tables no migration owns', () async {
    final broken = [CreateUsersTable(), CreateTagsTableWithBrokenDown()];
    final brokenSesh = Sesh(
      app,
      out: out,
      err: err,
      commands: databaseCommands(migrations: broken),
    );
    await brokenSesh.run(['migrate']);
    expect(await Schema.hasTable('tags'), isTrue);

    // A table no registered migration owns — migrate:refresh (reset then
    // run) would never touch this; only a real drop-every-table does.
    await DB.statement('create table orphan (id integer primary key)');
    expect(await Schema.hasTable('orphan'), isTrue);

    // CreateTagsTableWithBrokenDown.down() throws — reset()-based fresh
    // would propagate that exception. dropAllTables() never calls down().
    expect(await brokenSesh.run(['migrate:fresh']), 0);

    expect(await Schema.hasTable('users'), isTrue);
    expect(await Schema.hasTable('tags'), isTrue);
    expect(await Schema.hasTable('orphan'), isFalse);
  });

  test('migrate:fresh --seed runs the registered seeders', () async {
    var seeded = false;
    final seeder = _RecordingSeeder(() => seeded = true);
    final seededSesh = Sesh(
      app,
      out: out,
      err: err,
      commands: databaseCommands(migrations: migrations, seeders: [seeder]),
    );
    await seededSesh.run(['migrate']);

    expect(await seededSesh.run(['migrate:fresh']), 0);
    expect(seeded, isFalse);

    expect(await seededSesh.run(['migrate:fresh', '--seed']), 0);
    expect(seeded, isTrue);
  });

  test('migrate refuses to run in production without --force', () async {
    final prod = await buildTestApplication(environment: 'production');
    final guarded = Sesh(
      prod,
      out: out,
      err: err,
      commands: databaseCommands(migrations: migrations),
    );

    expect(await guarded.run(['migrate']), 1);
    expect(err.toString(), contains('production'));
    expect(err.toString(), contains('--force'));
    expect(await Schema.hasTable('users'), isFalse);

    err.clear();
    expect(await guarded.run(['migrate', '--force']), 0);
    expect(await Schema.hasTable('users'), isTrue);
  });

  test('migrate:fresh refuses in production without --force', () async {
    final prod = await buildTestApplication(environment: 'production');
    final guarded = Sesh(
      prod,
      out: out,
      err: err,
      commands: databaseCommands(migrations: migrations),
    );

    expect(await guarded.run(['migrate:fresh']), 1);
    expect(err.toString(), contains('--force'));
  });

  test('migrate:rollback refuses in production without --force', () async {
    await maat.run(['migrate']);

    final prod = await buildTestApplication(environment: 'production');
    final guarded = Sesh(
      prod,
      out: out,
      err: err,
      commands: databaseCommands(migrations: migrations),
    );

    expect(await guarded.run(['migrate:rollback']), 1);
    expect(err.toString(), contains('production'));
    expect(err.toString(), contains('--force'));
    expect(await Schema.hasTable('users'), isTrue);

    err.clear();
    expect(await guarded.run(['migrate:rollback', '--force']), 0);
    expect(await Schema.hasTable('users'), isFalse);
  });
}
