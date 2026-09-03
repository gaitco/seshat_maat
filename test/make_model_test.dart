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
    root = Directory.systemTemp.createTempSync('makemodel');
    Directory(
      p.join(root.path, 'database', 'migrations'),
    ).createSync(recursive: true);
    File(p.join(root.path, 'database', 'migrations.dart')).writeAsStringSync('''
import 'package:seshat_maat/seshat_maat.dart';

final migrations = <Migration>[
];
''');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: genapp\n');

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

  bool exists(String relative) =>
      File(p.join(root.path, relative)).existsSync();

  File migrationFile() => Directory(
    p.join(root.path, 'database', 'migrations'),
  ).listSync().whereType<File>().single;

  Future<int> makePost([List<String> extra = const []]) => maat.run([
    'make:model',
    'Post',
    '--fields=title:string body:text published:bool published_at:datetime '
        'views:int',
    ...extra,
  ]);

  test('generates a model with a ModelDefinition static', () async {
    expect(await makePost(), 0);

    final code = read('lib/app/models/post.dart');
    expect(code, contains('class Post extends Model<Post>'));
    expect(code, contains('static final ModelDefinition<Post> def'));
    expect(code, contains("table: 'posts'"));
    expect(code, contains('ModelDefinition<Post> get definition => def;'));
    expect(code, contains('static QueryBuilder<Post> query() => def.query();'));
  });

  test('declares a typed field per --fields entry', () async {
    expect(await makePost(), 0);

    final code = read('lib/app/models/post.dart');
    expect(code, contains('final String? title;'));
    expect(code, contains('final String? body;'));
    expect(code, contains('final bool published;'));
    expect(code, contains('final DateTime? publishedAt;'));
    expect(code, contains('final int? views;'));
    expect(code, contains('final int? id;'));
  });

  test('reads every field in fromMap', () async {
    expect(await makePost(), 0);

    final code = read('lib/app/models/post.dart');
    final from = code.substring(
      code.indexOf('fromMap:'),
      code.indexOf('fillable:'),
    );
    expect(from, contains("title: m['title'] as String?"));
    expect(from, contains("body: m['body'] as String?"));
    expect(from, contains("published: m['published'] as bool? ?? false"));
    expect(from, contains("publishedAt: m['published_at'] as DateTime?"));
    expect(from, contains("views: m['views'] as int?"));
  });

  test('writes every field in toMap, under its column name', () async {
    expect(await makePost(), 0);

    final code = read('lib/app/models/post.dart');
    final toMap = code.substring(code.indexOf('Map<String, Object?> toMap()'));
    expect(toMap, contains("'title': title,"));
    expect(toMap, contains("'published': published,"));
    expect(toMap, contains("'published_at': publishedAt,"));
    expect(toMap, contains("'views': views,"));
    expect(toMap, contains("'created_at': createdAt,"));
  });

  test('casts the bool and datetime fields', () async {
    expect(await makePost(), 0);

    final code = read('lib/app/models/post.dart');
    final casts = code.substring(
      code.indexOf('casts: {'),
      code.indexOf('ModelDefinition<Post> get definition'),
    );
    expect(casts, contains("'published': Cast.boolean"));
    expect(casts, contains("'published_at': Cast.dateTime"));
    expect(casts, contains("'created_at': Cast.dateTime"));
    expect(casts, contains("'updated_at': Cast.dateTime"));
  });

  test('lists every field as fillable, and never the key', () async {
    expect(await makePost(), 0);

    final code = read('lib/app/models/post.dart');
    final fillable = RegExp(r'fillable: \[([^\]]*)\]').firstMatch(code)![1]!;
    expect(fillable, contains("'title'"));
    expect(fillable, contains("'body'"));
    expect(fillable, contains("'published'"));
    expect(fillable, contains("'published_at'"));
    expect(fillable, contains("'views'"));
    expect(fillable, isNot(contains("'id'")));
  });

  test('pluralises the table name', () async {
    await maat.run(['make:model', 'Category']);
    expect(
      read('lib/app/models/category.dart'),
      contains("table: 'categories'"),
    );

    await maat.run(['make:model', 'BlogPost']);
    expect(
      read('lib/app/models/blog_post.dart'),
      contains("table: 'blog_posts'"),
    );
  });

  test('works with no --fields at all', () async {
    expect(await maat.run(['make:model', 'Post']), 0);

    final code = read('lib/app/models/post.dart');
    expect(code, contains('final int? id;'));
    expect(code, contains('fillable: [],'));
  });

  test('an empty --fields= is not a malformed field', () async {
    expect(await maat.run(['make:model', 'Post', '--fields=  ']), 0);
    expect(read('lib/app/models/post.dart'), contains('fillable: [],'));
  });

  group('unknown field types', () {
    test('are refused, listing what is supported', () async {
      expect(await maat.run(['make:model', 'Post', '--fields=price:money']), 1);
      expect(err.toString(), contains('money'));
      // The message must name the alternatives, not just the mistake.
      for (final type in ['string', 'text', 'int', 'bool', 'datetime']) {
        expect(err.toString(), contains(type));
      }
    });

    test('never fall back to dynamic', () async {
      await maat.run(['make:model', 'Post', '--fields=price:money']);
      expect(exists('lib/app/models/post.dart'), isFalse);
    });

    test('a field with no type at all is refused', () async {
      expect(await maat.run(['make:model', 'Post', '--fields=title']), 1);
      expect(exists('lib/app/models/post.dart'), isFalse);
    });

    test('a field colliding with a generated column is refused', () async {
      expect(
        await maat.run(['make:model', 'Post', '--fields=id:int']),
        1,
        reason: 'a second `id` parameter would not compile',
      );
      expect(exists('lib/app/models/post.dart'), isFalse);
    });
  });

  group('invalid field names', () {
    // Every one of these exits 0 without validation and writes a file that
    // does not compile — the analyze test cannot catch them, because it only
    // proves valid input produces valid output. Each message has to name the
    // fix: an agent driving this command through MCP self-corrects from the
    // message or not at all.
    Future<void> refuses(String fields, Matcher message) async {
      err.clear();
      expect(
        await maat.run(['make:model', 'Post', '--fields=$fields']),
        1,
        reason: 'make:model Post --fields "$fields" must be refused',
      );
      expect(err.toString(), message);
      expect(err.toString(), contains('Field'));
      expect(exists('lib/app/models/post.dart'), isFalse);
    }

    test('a duplicated field is refused', () async {
      await refuses('title:string title:int', contains('declared twice'));
    });

    test('the same column spelled two ways is still a duplicate', () async {
      // `publishedAt` and `published_at` snake down to one column, so they
      // would emit two `this.publishedAt` parameters.
      await refuses(
        'published_at:datetime publishedAt:datetime',
        contains('declared twice'),
      );
    });

    test('a Dart keyword is refused', () async {
      await refuses('class:string', contains('Dart keyword'));
      expect(err.toString(), contains('Rename it'));
    });

    test('a name starting with a digit is refused', () async {
      await refuses('1title:string', contains('not a usable Dart name'));
    });

    test('a collision with a generated member is refused', () async {
      await refuses('to_map:string', contains('toMap'));
      await refuses('def:string', contains('def'));
      await refuses('query:string', contains('query'));
      await refuses('save:bool', contains('save'));
      expect(err.toString(), contains('Rename it'));
    });
  });

  test('-m creates a migration and registers it', () async {
    expect(await makePost(['-m']), 0);

    final registry = read(p.join('database', 'migrations.dart'));
    // No trailing comma expected: a single short entry, so the write's own
    // `dart format` pass (routed through `writeGenerated`) collapses the
    // list onto one line.
    expect(registry, contains('CreatePostsTable()'));
    expect(registry, contains("import 'migrations/"));

    final created = Directory(
      p.join(root.path, 'database', 'migrations'),
    ).listSync().whereType<File>().single;
    expect(p.basename(created.path), endsWith('_create_posts_table.dart'));
    expect(
      p.basename(created.path),
      matches(RegExp(r'^m\d{4}_\d{2}_\d{2}_\d{6}_')),
      reason: 'file_names rejects a name starting with a digit',
    );
    expect(created.readAsStringSync(), contains("schema.create('posts'"));
  });

  test('-f creates a factory that returns new instances', () async {
    expect(await makePost(['-f']), 0);

    final code = read(p.join('database', 'factories', 'post_factory.dart'));
    expect(code, contains('class PostFactory extends Factory<Post>'));
    expect(code, contains('super(Post.def)'));
    expect(code, contains("import 'package:genapp/app/models/post.dart';"));
    // Immutability: both overrides must construct a NEW PostFactory rather
    // than mutating and returning `this` — a factory held in a variable and
    // reused across tests leaks state otherwise.
    final state = code.substring(
      code.indexOf('PostFactory state('),
      code.indexOf('PostFactory count('),
    );
    expect(state, contains('PostFactory('));
    expect(state, contains('states: [...states, attributes]'));
    expect(state, contains('count: countOf'));
    final count = code.substring(code.indexOf('PostFactory count('));
    expect(count, contains('PostFactory('));
    expect(count, contains('count: n'));
    expect(count, contains('states: states'));
    // A faker value per declared field, so the stub is usable as written.
    expect(code, contains("'title': faker.sentence()"));
    expect(code, contains("'published': faker.boolean()"));
    expect(code, contains("'published_at': faker.dateTime()"));
    expect(code, contains("'views': faker.number()"));
  });

  test('-r creates a resource over the model', () async {
    expect(await makePost(['-r']), 0);

    final code = read(
      p.join('lib', 'app', 'http', 'resources', 'post_resource.dart'),
    );
    expect(code, contains('class PostResource extends JsonResource<Post>'));
    expect(code, contains("import '../../models/post.dart';"));
    expect(code, contains("'title': resource.title,"));
    // DateTime is not JSON-encodable; the stub must not hand one to the encoder.
    expect(
      code,
      contains("'published_at': resource.publishedAt?.toIso8601String(),"),
    );
  });

  test('refuses to overwrite without --force', () async {
    expect(await makePost(), 0);
    expect(await makePost(), 1);
    expect(err.toString(), contains('already exists'));

    expect(await makePost(['--force']), 0);
  });

  test('strips a trailing .dart from the name argument', () async {
    expect(await maat.run(['make:model', 'Post.dart']), 0);
    expect(
      read('lib/app/models/post.dart'),
      contains('class Post extends Model<Post>'),
    );
  });

  group('-f without a resolvable package name', () {
    // A factory lives outside `lib/`, so it can only reach the model through
    // a `package:` import — which needs the app's own name. Guessing one
    // writes a file that does not compile, so the command refuses instead,
    // and refuses before anything is written.
    test('reports when there is no pubspec at all', () async {
      File(p.join(root.path, 'pubspec.yaml')).deleteSync();

      expect(await makePost(['-f']), 1);
      expect(err.toString(), contains('pubspec.yaml'));
      expect(exists('lib/app/models/post.dart'), isFalse);
      expect(
        exists(p.join('database', 'factories', 'post_factory.dart')),
        isFalse,
      );
    });

    test('reports when the pubspec declares no name', () async {
      File(
        p.join(root.path, 'pubspec.yaml'),
      ).writeAsStringSync('description: nameless\n');

      expect(await makePost(['-f']), 1);
      expect(err.toString(), contains('pubspec.yaml'));
      expect(
        exists(p.join('database', 'factories', 'post_factory.dart')),
        isFalse,
      );
    });
  });

  test('the generated files analyze, are formatted, and migrate-then-save '
      'against sqlite', () async {
    expect(await makePost(['-m', '-f', '-r']), 0);

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

    // Generated code lands in the user's repo, so it must already be in
    // `dart format` shape — otherwise the first unrelated `dart format .`
    // shows up as noise in their diff.
    final format = await Process.run('dart', [
      'format',
      '--output=none',
      '--set-exit-if-changed',
      'lib/app/models/post.dart',
      'lib/app/http/resources/post_resource.dart',
      'database/factories/post_factory.dart',
      // The -m migration is generated code too, held to the same bar.
      p.join('database', 'migrations', p.basename(migrationFile().path)),
    ], workingDirectory: root.path);
    expect(format.exitCode, 0, reason: '${format.stdout}${format.stderr}');

    // Each generated file being individually plausible is not enough: the
    // model's definition defaults `timestamps: true`, so every insert names
    // created_at/updated_at, and a migration without `t.timestamps()`
    // produces a table the model cannot save to. Only running the pair
    // catches that, which is why this goes through sqlite rather than
    // asserting on the migration's text.
    // `--fields` describes Dart types, not column modifiers, so the create
    // stub deliberately does not infer a schema — the developer fills it in.
    // Do that here, leaving the generated `t.id()`/`t.timestamps()` alone:
    // without `t.timestamps()` the insert still fails on created_at even
    // once every user column exists, which is the point being proved.
    final migration = migrationFile();
    final withColumns = migration.readAsStringSync().replaceFirst(
      '    t.id();\n',
      "    t.id();\n"
          "    t.string('title');\n"
          "    t.text('body');\n"
          "    t.boolean('published');\n"
          "    t.dateTime('published_at');\n"
          "    t.integer('views');\n",
    );
    expect(
      withColumns,
      contains("t.string('title')"),
      reason: 'the create stub must still open with t.id();',
    );
    expect(withColumns, contains('t.timestamps();'));
    migration.writeAsStringSync(withColumns);

    File(p.join(root.path, 'bin', 'check.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
import 'package:seshat_maat/seshat_maat.dart';
import 'package:genapp/app/models/post.dart';

import '../database/factories/post_factory.dart';
import '../database/migrations.dart';

Future<void> main() async {
  final connection = SqliteConnection.open(':memory:');
  DB.use(connection);
  await Migrator(connection, migrations).run();

  final saved = await PostFactory().createOne();
  if (saved.key == null) throw StateError('no key was assigned');

  final found = await Post.def.findOrFail(saved.key!);
  if (found.title == null) throw StateError('title did not round-trip');
  if (found.createdAt == null) throw StateError('created_at was not written');
}
''');

    final run = await Process.run('dart', [
      'run',
      'bin/check.dart',
    ], workingDirectory: root.path);
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
