import 'package:seshat_maat/seshat_maat.dart';
import 'package:seshat_maat/testing.dart';
import 'package:test/test.dart';

void main() {
  final db = RefreshDatabase(migrations: [CreateWidgets(), CreateGadgets()]);
  late final Connection opened;

  setUpAll(db.migrate);
  setUpAll(() => opened = DB.connection);
  tearDownAll(db.close);

  // The real wiring, plus proof that it worked. Asserting here rather than
  // in the next test's setUp makes a leak fail after EVERY test in ANY
  // order, instead of only when a test that writes rows happens to be
  // followed by one that looks.
  tearDown(() async {
    await db.truncate();
    expect(await DB.table('widgets').count(), 0, reason: 'tearDown must empty');
    expect(await DB.table('gadgets').count(), 0, reason: 'tearDown must empty');
  });

  setUp(() async {
    expect(
      identical(DB.connection, opened),
      isTrue,
      reason: 'the database must be opened and migrated once, in setUpAll',
    );
    expect(
      await DB.table('widgets').count(),
      0,
      reason: 'a previous test leaked rows into this one',
    );
  });

  test('a row written in one test does not survive into the next', () async {
    // Deliberately leaves rows behind: the tearDown assertions above and the
    // setUp assertions of whichever test runs next are what catch a leak.
    await DB.table('widgets').insert({'name': 'leaky'});
    expect(await DB.table('widgets').count(), 1);
  });

  test('the schema survives a truncation', () async {
    await db.truncate();
    final schema = Schema.on(DB.connection);
    expect(await schema.hasTable('widgets'), isTrue);
    expect(await schema.hasTable('gadgets'), isTrue);
  });

  test('a child row does not block deleting its parent', () async {
    // widgets is created before gadgets, so the table listing hits the parent
    // first — a foreign key violation unless enforcement is deferred.
    final id = await DB.table('widgets').insertGetId({'name': 'parent'});
    await DB.table('gadgets').insert({'widget_id': id, 'label': 'child'});
    expect(await DB.table('gadgets').count(), 1);

    await db.truncate();

    expect(await DB.table('gadgets').count(), 0);
    expect(await DB.table('widgets').count(), 0);
  });

  test('foreign keys are still enforced after a truncation', () async {
    await db.truncate();
    await expectLater(
      DB.table('gadgets').insert({'widget_id': 999, 'label': 'orphan'}),
      throwsA(
        isA<QueryException>().having(
          (e) => e.toString(),
          'message',
          contains('FOREIGN KEY'),
        ),
      ),
      reason: 'defer_foreign_keys must not leak past the truncation',
    );
  });

  test('autoincrement ids restart at 1 after a truncation', () async {
    await DB.table('widgets').insert({'name': 'a'});
    await DB.table('widgets').insert({'name': 'b'});
    expect(await DB.table('widgets').insertGetId({'name': 'c'}), 3);

    await db.truncate();

    expect(await DB.table('widgets').insertGetId({'name': 'fresh'}), 1);
  });

  test('a truncation resets table sequences but not the migrations '
      'sequence', () async {
    await DB.table('widgets').insert({'name': 'a'});

    await db.truncate();

    // Wiping the migrations sequence too would hand a rolled-back-and-rerun
    // migration an id already used by a surviving bookkeeping row.
    expect(await DB.select('select name, seq from sqlite_sequence'), [
      {'name': 'migrations', 'seq': 2},
    ]);
  });

  test('the migrations bookkeeping survives a truncation', () async {
    await db.truncate();
    expect(
      await DB.table('migrations').count(),
      2,
      reason: 'wiping it would undo the single setUpAll migration run',
    );
  });

  test('one instance does not truncate another instance', () async {
    final mine = DB.connection;
    final other = RefreshDatabase(migrations: [CreateWidgets()]);
    await other.migrate();
    final theirs = DB.connection;
    addTearDown(() async {
      await other.close();
      DB.use(mine);
    });
    DB.use(mine); // the default connection is this suite's database again

    await DB.table('widgets', connection: mine).insert({'name': 'mine'});
    await DB.table('widgets', connection: theirs).insert({'name': 'theirs'});

    await other.truncate();

    expect(
      await DB.table('widgets', connection: mine).count(),
      1,
      reason: 'truncate must use the connection its own migrate() opened',
    );
    expect(await DB.table('widgets', connection: theirs).count(), 0);
  });
}

class CreateWidgets extends Migration {
  @override
  Future<void> up(SchemaBuilder schema) => schema.create('widgets', (t) {
    t.id();
    t.string('name');
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('widgets');
}

class CreateGadgets extends Migration {
  @override
  Future<void> up(SchemaBuilder schema) => schema.create('gadgets', (t) {
    t.id();
    t.foreignId('widget_id').constrained();
    t.string('label');
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('gadgets');
}
