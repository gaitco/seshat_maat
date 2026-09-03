import 'dart:io';

import 'package:maat/maat.dart';
import 'package:seshat_maat/seshat_maat.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_application.dart';

void main() {
  late Directory root;
  late Application app;
  late Sesh maat;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('makemig');
    Directory(
      p.join(root.path, 'database', 'migrations'),
    ).createSync(recursive: true);
    File(p.join(root.path, 'database', 'migrations.dart')).writeAsStringSync('''
import 'package:seshat_maat/seshat_maat.dart';

final migrations = <Migration>[
];
''');

    out = StringBuffer();
    err = StringBuffer();
    app = await buildTestApplication(basePath: root.path);
    maat = Sesh(app, out: out, err: err, commands: databaseCommands());
  });

  tearDown(() {
    root.deleteSync(recursive: true);
    Application.reset();
  });

  String read(String relative) =>
      File(p.join(root.path, relative)).readAsStringSync();

  List<File> migrationFiles() => Directory(
    p.join(root.path, 'database', 'migrations'),
  ).listSync().whereType<File>().toList();

  test('writes a timestamped migration with a create body', () async {
    expect(
      await maat.run([
        'make:migration',
        'create_posts_table',
        '--create=posts',
      ]),
      0,
    );

    final created = migrationFiles().single;

    // `m` prefix: a file name starting with a digit isn't a legal Dart
    // identifier, so it fails the `file_names` lint under --fatal-infos.
    expect(p.basename(created.path), endsWith('_create_posts_table.dart'));
    expect(
      p.basename(created.path),
      matches(RegExp(r'^m\d{4}_\d{2}_\d{2}_\d{6}_')),
    );

    final code = created.readAsStringSync();
    expect(code, contains('class CreatePostsTable extends Migration'));
    expect(code, contains('String get name =>'));
    // Order-sensitive: catches an `up`/`down` body swap, which a plain
    // `contains` on the whole file would miss (both strings would still be
    // present, just on the wrong method).
    final upIndex = code.indexOf('Future<void> up');
    final downIndex = code.indexOf('Future<void> down');
    expect(upIndex, greaterThan(-1));
    expect(downIndex, greaterThan(upIndex));
    expect(
      code.substring(upIndex, downIndex),
      contains("schema.create('posts'"),
    );
    // Without this the generated table has no created_at/updated_at, and a
    // model whose definition defaults `timestamps: true` cannot insert into
    // it. See the end-to-end migrate-then-save test in make_model_test.dart.
    expect(code.substring(upIndex, downIndex), contains('t.timestamps();'));
    expect(code.substring(downIndex), contains("schema.dropIfExists('posts')"));
  });

  test('writes a table body when --table is given', () async {
    await maat.run(['make:migration', 'add_slug_to_posts', '--table=posts']);

    final code = migrationFiles().single.readAsStringSync();

    expect(code, contains("schema.table('posts'"));
  });

  test('appends to whatever shape dart format left the list in', () async {
    // `dart format` collapses a short list onto one line, dropping the
    // trailing comma: `<Migration>[CreateATable()]`. Inserting before the
    // `];` without restoring that comma produced
    // `[CreateATable()  CreateBTable(),` — a syntax error the command still
    // reported as "created successfully".
    Future<String> insertInto(String list, String name) async {
      File(p.join(root.path, 'database', 'migrations.dart')).writeAsStringSync(
        "import 'package:seshat_maat/seshat_maat.dart';\n"
        '\n'
        '$list\n',
      );
      expect(await maat.run(['make:migration', name]), 0);
      return read(p.join('database', 'migrations.dart'));
    }

    final collapsedEntry = await insertInto(
      'final migrations = <Migration>[CreateATable()];',
      'create_b_table',
    );
    // Both entries fit on one line, so the write's own `dart format` pass
    // collapses them right back and drops the trailing comma — the same
    // thing it did to the incoming list. A comma is not part of the needle.
    expect(collapsedEntry, contains('CreateATable()'));
    expect(collapsedEntry, contains('CreateBTable()'));
    expect(
      collapsedEntry.indexOf('CreateATable()'),
      lessThan(collapsedEntry.indexOf('CreateBTable()')),
    );

    final collapsedEmpty = await insertInto(
      'final migrations = <Migration>[];',
      'create_c_table',
    );
    expect(collapsedEmpty, contains('<Migration>[CreateCTable()];'));

    // A comment-only body is what the skeleton ships; it must not be given a
    // trailing comma of its own.
    final commented = await insertInto(
      'final migrations = <Migration>[\n  // make:migration adds them here.\n];',
      'create_d_table',
    );
    expect(
      commented,
      contains('  // make:migration adds them here.\n  CreateDTable(),\n];'),
    );
  });

  test('registers the migration in the registry, import and entry', () async {
    await maat.run(['make:migration', 'create_posts_table', '--create=posts']);

    final registry = read(p.join('database', 'migrations.dart'));
    expect(registry, contains("import 'migrations/"));
    expect(registry, contains('CreatePostsTable()'));
  });

  test('appends rather than replacing, keeping chronological order', () async {
    await maat.run(['make:migration', 'create_a_table', '--create=a']);
    await maat.run(['make:migration', 'create_b_table', '--create=b']);

    final registry = read(p.join('database', 'migrations.dart'));
    // Presence first: `indexOf` returns -1 for an absent entry, and -1 is
    // "less than" every real index — a registry that wipes itself on every
    // run would satisfy a bare ordering check.
    expect(registry, contains('CreateATable()'));
    expect(registry, contains('CreateBTable()'));
    expect(
      registry.indexOf('CreateATable()'),
      lessThan(registry.indexOf('CreateBTable()')),
    );
  });

  test('reports the created path', () async {
    await maat.run(['make:migration', 'create_posts_table', '--create=posts']);
    expect(out.toString(), contains('created successfully'));
  });

  test(
    'creates the registry with the standard header when it does not exist',
    () async {
      final freshRoot = Directory.systemTemp.createTempSync('makemig_missing');
      Directory(
        p.join(freshRoot.path, 'database', 'migrations'),
      ).createSync(recursive: true);
      // database/migrations.dart is deliberately not created.

      final freshOut = StringBuffer();
      final freshApp = await buildTestApplication(basePath: freshRoot.path);
      final freshSesh = Sesh(
        freshApp,
        out: freshOut,
        commands: databaseCommands(),
      );

      expect(
        await freshSesh.run([
          'make:migration',
          'create_widgets_table',
          '--create=widgets',
        ]),
        0,
      );

      final registry = File(
        p.join(freshRoot.path, 'database', 'migrations.dart'),
      ).readAsStringSync();
      expect(
        registry,
        contains("import 'package:seshat_maat/seshat_maat.dart';"),
      );
      expect(registry, contains("import 'migrations/"));
      expect(registry, contains('final migrations = <Migration>['));
      expect(registry, contains('CreateWidgetsTable()'));

      freshRoot.deleteSync(recursive: true);
    },
  );

  test('strips a trailing .dart from the name argument', () async {
    expect(
      await maat.run([
        'make:migration',
        'create_posts_table.dart',
        '--create=posts',
      ]),
      0,
    );

    final code = migrationFiles().single.readAsStringSync();
    expect(code, contains('class CreatePostsTable extends Migration'));
    expect(read('database/migrations.dart'), contains('CreatePostsTable()'));
    expect(read('database/migrations.dart'), isNot(contains(r'.dart(),')));
  });

  test('an empty --create= does not generate schema.create(\'\')', () async {
    await maat.run(['make:migration', 'create_posts_table', '--create=']);

    final code = migrationFiles().single.readAsStringSync();
    expect(code, isNot(contains("schema.create('')")));
    expect(code, contains('Future<void> up(SchemaBuilder schema) async {}'));
  });

  test('an empty --table= does not generate schema.table(\'\')', () async {
    await maat.run(['make:migration', 'add_slug_to_posts', '--table=']);

    final code = migrationFiles().single.readAsStringSync();
    expect(code, isNot(contains("schema.table('')")));
    expect(code, contains('Future<void> up(SchemaBuilder schema) async {}'));
  });

  group('anchoring on the migrations list', () {
    test(
      'inserts into the migrations list, not trailing content also containing "];"',
      () async {
        File(
          p.join(root.path, 'database', 'migrations.dart'),
        ).writeAsStringSync('''
import 'package:seshat_maat/seshat_maat.dart';

final migrations = <Migration>[
];

/// Only used by integration tests.
final extraMigrations = <Migration>[];
''');

        expect(
          await maat.run([
            'make:migration',
            'create_posts_table',
            '--create=posts',
          ]),
          0,
        );

        final registry = read('database/migrations.dart');
        final migrationsSection = registry.substring(
          registry.indexOf('final migrations'),
          registry.indexOf('final extraMigrations'),
        );
        expect(migrationsSection, contains('CreatePostsTable()'));
        final extraSection = registry.substring(
          registry.indexOf('final extraMigrations'),
        );
        expect(extraSection, isNot(contains('CreatePostsTable')));
      },
    );

    test(
      'inserts the import after a library directive, never above it',
      () async {
        File(
          p.join(root.path, 'database', 'migrations.dart'),
        ).writeAsStringSync('''
library c_registry;

final migrations = <Migration>[
];
''');

        expect(
          await maat.run([
            'make:migration',
            'create_posts_table',
            '--create=posts',
          ]),
          0,
        );

        final registry = read('database/migrations.dart');
        expect(
          registry.indexOf('library c_registry;'),
          lessThan(registry.indexOf("import 'migrations/")),
        );
      },
    );

    test(
      'refuses when the registry has no migrations list to anchor on',
      () async {
        File(
          p.join(root.path, 'database', 'migrations.dart'),
        ).writeAsStringSync('// nothing here\n');

        expect(
          await maat.run([
            'make:migration',
            'create_posts_table',
            '--create=posts',
          ]),
          1,
        );
        expect(err.toString(), contains('migrations'));
        expect(migrationFiles(), isEmpty);
      },
    );
  });

  group('duplicate registration', () {
    test('--force re-run does not duplicate the registry entry', () async {
      final fixed = DateTime(2026, 1, 1, 12, 0, 0);
      final fixedSesh = Sesh(
        app,
        out: out,
        err: err,
        commands: [MakeMigrationCommand(clock: () => fixed)],
      );

      expect(
        await fixedSesh.run([
          'make:migration',
          'create_posts_table',
          '--create=posts',
        ]),
        0,
      );
      expect(
        await fixedSesh.run([
          'make:migration',
          'create_posts_table',
          '--create=posts',
          '--force',
        ]),
        0,
      );

      final registry = read('database/migrations.dart');
      // No trailing comma expected: one entry is short enough that the
      // write's own `dart format` pass collapses the list onto one line.
      final firstIndex = registry.indexOf('CreatePostsTable()');
      expect(firstIndex, greaterThan(-1));
      expect(
        registry.indexOf('CreatePostsTable()', firstIndex + 1),
        -1,
        reason: 'the entry must appear exactly once',
      );
      expect(
        RegExp(
          r"import 'migrations/[^']*create_posts_table\.dart';",
        ).allMatches(registry).length,
        1,
      );
      expect(migrationFiles(), hasLength(1));
    });

    test(
      'refuses a different file that would register an already-used class name',
      () async {
        final first = Sesh(
          app,
          out: out,
          err: err,
          commands: [
            MakeMigrationCommand(clock: () => DateTime(2026, 1, 1, 12, 0, 0)),
          ],
        );
        expect(
          await first.run([
            'make:migration',
            'create_posts_table',
            '--create=posts',
          ]),
          0,
        );

        final second = Sesh(
          app,
          out: out,
          err: err,
          commands: [
            MakeMigrationCommand(clock: () => DateTime(2026, 1, 1, 12, 0, 1)),
          ],
        );
        expect(
          await second.run([
            'make:migration',
            'create_posts_table',
            '--create=posts',
          ]),
          1,
        );
        expect(err.toString(), contains('already registered'));
        expect(
          migrationFiles(),
          hasLength(1),
          reason: 'the second, colliding file must never be written',
        );
      },
    );

    test(
      'accepts a class name that merely ends with a registered one',
      () async {
        final first = Sesh(
          app,
          out: out,
          err: err,
          commands: [
            MakeMigrationCommand(clock: () => DateTime(2026, 1, 1, 12, 0, 0)),
          ],
        );
        expect(
          await first.run([
            'make:migration',
            're_create_posts_table',
            '--create=posts_v2',
          ]),
          0,
        );

        // `CreatePostsTable()` is a substring of the registered
        // `ReCreatePostsTable()`. Only a left identifier boundary tells the
        // two apart; without one the second migration is refused as a
        // duplicate of a class name it merely ends with.
        final second = Sesh(
          app,
          out: out,
          err: err,
          commands: [
            MakeMigrationCommand(clock: () => DateTime(2026, 1, 1, 12, 0, 1)),
          ],
        );
        expect(
          await second.run([
            'make:migration',
            'create_posts_table',
            '--create=posts',
          ]),
          0,
          reason: err.toString(),
        );
        expect(err.toString(), isEmpty);
        expect(migrationFiles(), hasLength(2));
        expect(
          read('database/migrations.dart'),
          contains('CreatePostsTable()'),
        );
      },
    );
  });

  test('generated migration and registry are dart format-clean at a name long '
      'enough to force the formatter to break lines', () async {
    // A name this long forces `dart format` to wrap the `create(...)` call
    // and the registry's import/entry lines onto multiple lines. Both
    // writes must route through `writeGenerated` (which formats on write)
    // rather than a raw `writeAsStringSync` — otherwise the file left on
    // disk is valid but unformatted, and `dart format
    // --set-exit-if-changed` rejects it.
    expect(
      await maat.run([
        'make:migration',
        'CreateSubscriptionCancellationRecordsTable',
        '--create=subscription_cancellation_records',
      ]),
      0,
    );

    final migrationFile = migrationFiles().single;
    final registryFile = File(p.join(root.path, 'database/migrations.dart'));

    for (final file in [migrationFile, registryFile]) {
      final result = await Process.run('dart', [
        'format',
        '--output=none',
        '--set-exit-if-changed',
        file.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason:
            '${file.path} was not left dart format-clean:\n'
            '${result.stdout}${result.stderr}',
      );
    }
  });

  test(
    'generated migration and registry analyze clean in a consumer project',
    () async {
      await maat.run([
        'make:migration',
        'create_posts_table',
        '--create=posts',
      ]);

      final frameworkPath = p.normalize(Directory.current.path);
      File(
        p.join(root.path, 'pubspec.yaml'),
      ).writeAsStringSync(testConsumerPubspec(frameworkPath));
      File(p.join(root.path, 'analysis_options.yaml')).writeAsStringSync(
        File(
          p.join(
            frameworkPath,
            '..',
            'ptah',
            'lib',
            'skeleton',
            'analysis_options.yaml',
          ),
        ).readAsStringSync(),
      );

      final pubGet = await Process.run('dart', [
        'pub',
        'get',
      ], workingDirectory: root.path);
      expect(pubGet.exitCode, 0, reason: pubGet.stderr.toString());

      final analyze = await Process.run('dart', [
        'analyze',
        '--fatal-infos',
      ], workingDirectory: root.path);
      expect(analyze.exitCode, 0, reason: '${analyze.stdout}${analyze.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
