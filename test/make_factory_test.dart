import 'dart:io';

import 'package:maat/maat.dart';
import 'package:maat_seshat/maat_seshat.dart';
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
    root = Directory.systemTemp.createTempSync('makefactory');
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

  /// The model the generated factory imports, so the default run has one.
  void writeModel([String relative = 'lib/app/models/post.dart']) {
    File(p.join(root.path, relative))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('class Post {}\n');
  }

  const factoryPath = 'database/factories/post_factory.dart';

  test('generates a factory keyed to the model definition', () async {
    writeModel();
    expect(await maat.run(['make:factory', 'PostFactory']), 0);

    final code = read(factoryPath);
    expect(code, contains('class PostFactory extends Factory<Post>'));
    expect(
      code,
      contains(
        'PostFactory({super.faker, super.count, super.states}) '
        ': super(Post.def);',
      ),
    );
    expect(code, contains('Map<String, Object?> definition(Faker faker)'));
    expect(code, contains("import 'package:maat_seshat/maat_seshat.dart';"));
  });

  test('imports the model through the application package', () async {
    writeModel();
    await maat.run(['make:factory', 'PostFactory']);

    expect(
      read(factoryPath),
      contains("import 'package:genapp/app/models/post.dart';"),
      reason:
          'a factory lives outside lib/, so it cannot reach the model '
          'relatively',
    );
  });

  test('state() and count() return NEW factories', () async {
    writeModel();
    await maat.run(['make:factory', 'PostFactory']);

    // Task 3 leaves both abstract, so this stub is where most users will
    // copy the pattern from. Mutating and returning `this` leaks one test's
    // states into the next.
    final code = read(factoryPath);
    final state = code.substring(
      code.indexOf('PostFactory state('),
      code.indexOf('PostFactory count('),
    );
    expect(state, contains('PostFactory('));
    expect(state, contains('faker: faker'));
    expect(state, contains('count: countOf'));
    expect(state, contains('states: [...states, attributes]'));

    final count = code.substring(code.indexOf('PostFactory count('));
    expect(count, contains('PostFactory('));
    expect(count, contains('count: n'));
    expect(count, contains('states: states'));
    expect(count, isNot(contains('return this')));
  });

  test('a bare model name gains the Factory suffix', () async {
    writeModel();
    expect(await maat.run(['make:factory', 'Post']), 0);

    expect(
      read(factoryPath),
      contains('class PostFactory extends Factory<Post>'),
      reason: 'taken literally this would be class Post extends Factory<Post>',
    );
  });

  test('--model overrides the inferred model', () async {
    writeModel('lib/app/models/user.dart');
    expect(await maat.run(['make:factory', 'AdminFactory', '--model=User']), 0);

    final code = read('database/factories/admin_factory.dart');
    expect(code, contains('class AdminFactory extends Factory<User>'));
    expect(code, contains('super(User.def)'));
    expect(code, contains("import 'package:genapp/app/models/user.dart';"));
  });

  test('--model is studly-cased like the name argument', () async {
    writeModel('lib/app/models/blog_post.dart');
    expect(
      await maat.run(['make:factory', 'PostFactory', '--model=blog_post']),
      0,
    );

    final code = read(factoryPath);
    expect(code, contains('Factory<BlogPost>'));
    expect(
      code,
      contains("import 'package:genapp/app/models/blog_post.dart';"),
    );
  });

  test('a nested name nests the factory and the model import', () async {
    writeModel('lib/app/models/blog/post.dart');
    expect(await maat.run(['make:factory', 'blog/PostFactory']), 0);

    expect(
      read('database/factories/blog/post_factory.dart'),
      contains("import 'package:genapp/app/models/blog/post.dart';"),
    );
  });

  test('warns, but still generates, when the model does not exist', () async {
    expect(await maat.run(['make:factory', 'PostFactory']), 0);

    expect(out.toString(), contains('WARNING'));
    expect(out.toString(), contains('lib/app/models/post.dart'));
    expect(out.toString(), contains('--model'));
    expect(exists(factoryPath), isTrue);
  });

  test('says nothing when the model does exist', () async {
    writeModel();
    await maat.run(['make:factory', 'PostFactory']);

    expect(out.toString(), isNot(contains('WARNING')));
  });

  test('refuses to overwrite without --force', () async {
    writeModel();
    expect(await maat.run(['make:factory', 'PostFactory']), 0);
    expect(await maat.run(['make:factory', 'PostFactory']), 1);
    expect(err.toString(), contains('already exists'));

    expect(await maat.run(['make:factory', 'PostFactory', '--force']), 0);
  });

  group('unusable names', () {
    // The generated-project analyze test proves valid input produces valid
    // output and says nothing about bad input. Every case here exits 0
    // without validation and writes a file that does not compile.
    Future<void> refuses(List<String> args, Matcher message) async {
      err.clear();
      expect(
        await maat.run(['make:factory', ...args]),
        1,
        reason: 'make:factory ${args.join(' ')} must be refused',
      );
      expect(err.toString(), message);
      expect(
        Directory(p.join(root.path, 'database')).existsSync(),
        isFalse,
        reason: 'nothing may be written for input that is refused',
      );
    }

    test('a name starting with a digit is refused', () async {
      await refuses(['1post'], contains('not a usable class name'));
    });

    test('a name with punctuation in it is refused', () async {
      await refuses(['post!'], contains('not a usable class name'));
    });

    test('an empty name is refused', () async {
      // Studly of '' is '', so the class would be the bare base class name.
      await refuses([''], contains('which model'));
    });

    test('naming it after the base class alone is refused', () async {
      await refuses(['Factory'], contains('which model'));
      expect(err.toString(), contains('--model'));
    });

    test('an unusable --model is refused', () async {
      await refuses(['PostFactory', '--model=1post'], contains('--model'));
      await refuses(['PostFactory', '--model=  '], contains('--model'));
    });

    test('--model equal to the generated class name is refused', () async {
      // The suffix-appending rule exists to stop the generated class
      // shadowing the model it wraps; `--model` must not be able to walk
      // around it.
      await refuses([
        'ImageFactory',
        '--model=ImageFactory',
      ], contains('cannot share a name'));
    });
  });

  group('without a resolvable package name', () {
    // The generated factory can only reach the model through a `package:`
    // import, which needs the application's own name. Guessing one writes a
    // file that does not compile, so the command refuses instead.
    test('reports when there is no pubspec at all', () async {
      File(p.join(root.path, 'pubspec.yaml')).deleteSync();

      expect(await maat.run(['make:factory', 'PostFactory']), 1);
      expect(err.toString(), contains('pubspec.yaml'));
      expect(exists(factoryPath), isFalse);
    });

    test('reports when the pubspec declares no name', () async {
      File(
        p.join(root.path, 'pubspec.yaml'),
      ).writeAsStringSync('description: nameless\n');

      expect(await maat.run(['make:factory', 'PostFactory']), 1);
      expect(err.toString(), contains('pubspec.yaml'));
      expect(exists(factoryPath), isFalse);
    });
  });

  test('the generated factory analyzes, is formatted, and creates a row '
      'against sqlite', () async {
    expect(
      await maat.run(['make:model', 'Post', '--fields=title:string', '-m']),
      0,
    );
    expect(await maat.run(['make:factory', 'PostFactory']), 0);
    // A long class name, over a model that exists, so the analyze below is
    // real: `dart format` wraps the constructor, `state` and `count` at a
    // width `PostFactory` never reaches, and the stub has to wrap them the
    // same way or land unformatted in the user's repository.
    expect(
      await maat.run([
        'make:factory',
        'TransactionCategoryFactory',
        '--model=Post',
      ]),
      0,
    );

    final frameworkPath = p.normalize(Directory.current.path);
    File(
      p.join(root.path, 'pubspec.yaml'),
    ).writeAsStringSync(testConsumerPubspec(frameworkPath));
    File(p.join(root.path, 'analysis_options.yaml')).writeAsStringSync(
      File(
        p.join(
          frameworkPath,
          '..',
          'maat_ptah',
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

    // No `dart format --set-exit-if-changed` assertion here: `writeGenerated`
    // formats every file it writes before this test can look at it, so such a
    // check passes even against a grossly mis-formatted stub. The formatting
    // guarantee lives in `writeGenerated` (and in the `WARNING` assertion
    // above, which catches the case where formatting fails), not here.

    // Analyzing proves it compiles; only running it proves the stub's
    // state()/count() pattern actually threads through to a saved row.
    final migration = Directory(
      p.join(root.path, 'database', 'migrations'),
    ).listSync().whereType<File>().single;
    migration.writeAsStringSync(
      migration.readAsStringSync().replaceFirst(
        '    t.id();\n',
        "    t.id();\n    t.string('title').nullable();\n",
      ),
    );
    expect(
      migration.readAsStringSync(),
      contains("t.string('title').nullable();"),
      reason: 'the empty definition() in the stub writes no title at all',
    );

    File(p.join(root.path, 'bin', 'check.dart'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''
import 'package:maat_seshat/maat_seshat.dart';
import 'package:genapp/app/models/post.dart';

import '../database/factories/post_factory.dart';
import '../database/migrations.dart';

Future<void> main() async {
  final connection = SqliteConnection.open(':memory:');
  DB.use(connection);
  await Migrator(connection, migrations).run();

  final base = PostFactory();
  final titled = base.state({'title': 'Hello'});
  if (base.states.isNotEmpty) throw StateError('state() mutated the original');

  final posts = await titled.count(2).create();
  if (posts.length != 2) throw StateError('count(2) did not create two rows');
  if (posts.first.title != 'Hello') throw StateError('the state was lost');

  final plain = await base.createOne();
  if (plain.title != null) throw StateError('the state leaked into the base');
}
''');

    final run = await Process.run('dart', [
      'run',
      'bin/check.dart',
    ], workingDirectory: root.path);
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
