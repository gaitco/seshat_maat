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
    root = Directory.systemTemp.createTempSync('makeresource');
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

  void writeModel([String relative = 'lib/app/models/post.dart']) {
    File(p.join(root.path, relative))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('class Post {}\n');
  }

  const resourcePath = 'lib/app/http/resources/post_resource.dart';

  test('generates a resource over the model', () async {
    writeModel();
    expect(await maat.run(['make:resource', 'PostResource']), 0);

    final code = read(resourcePath);
    expect(code, contains('class PostResource extends JsonResource<Post>'));
    expect(code, contains('PostResource(super.resource);'));
    expect(code, contains('Map<String, Object?> toJson(Request request)'));
    expect(code, contains("import 'package:maat/maat.dart';"));
  });

  test('serialises the key and the timestamps', () async {
    writeModel();
    await maat.run(['make:resource', 'PostResource']);

    final code = read(resourcePath);
    expect(code, contains("'id': resource.id,"));
    // DateTime is not JSON-encodable; the stub must not hand one to the
    // encoder.
    expect(
      code,
      contains("'created_at': resource.createdAt?.toIso8601String(),"),
    );
    expect(
      code,
      contains("'updated_at': resource.updatedAt?.toIso8601String(),"),
    );
  });

  test('imports the model relatively', () async {
    writeModel();
    await maat.run(['make:resource', 'PostResource']);

    expect(read(resourcePath), contains("import '../../models/post.dart';"));
  });

  test('a bare model name gains the Resource suffix', () async {
    writeModel();
    expect(await maat.run(['make:resource', 'Post']), 0);

    expect(
      read(resourcePath),
      contains('class PostResource extends JsonResource<Post>'),
      reason:
          'taken literally this would be class Post extends '
          'JsonResource<Post>, which does not compile',
    );
  });

  test('--model overrides the inferred model', () async {
    writeModel('lib/app/models/user.dart');
    expect(
      await maat.run(['make:resource', 'AuthorResource', '--model=User']),
      0,
    );

    final code = read('lib/app/http/resources/author_resource.dart');
    expect(code, contains('class AuthorResource extends JsonResource<User>'));
    expect(code, contains("import '../../models/user.dart';"));
  });

  test('a nested name nests the resource and its relative import', () async {
    writeModel('lib/app/models/blog/post.dart');
    expect(await maat.run(['make:resource', 'blog/PostResource']), 0);

    expect(
      read('lib/app/http/resources/blog/post_resource.dart'),
      contains("import '../../../models/blog/post.dart';"),
    );
  });

  test('warns, but still generates, when the model does not exist', () async {
    expect(await maat.run(['make:resource', 'PostResource']), 0);

    expect(out.toString(), contains('WARNING'));
    expect(out.toString(), contains('lib/app/models/post.dart'));
    expect(out.toString(), contains('--model'));
    expect(exists(resourcePath), isTrue);
  });

  test('says nothing when the model does exist', () async {
    writeModel();
    await maat.run(['make:resource', 'PostResource']);

    expect(out.toString(), isNot(contains('WARNING')));
  });

  test('refuses to overwrite without --force', () async {
    writeModel();
    expect(await maat.run(['make:resource', 'PostResource']), 0);
    expect(await maat.run(['make:resource', 'PostResource']), 1);
    expect(err.toString(), contains('already exists'));

    expect(await maat.run(['make:resource', 'PostResource', '--force']), 0);
  });

  group('unusable names', () {
    Future<void> refuses(List<String> args, Matcher message) async {
      err.clear();
      expect(
        await maat.run(['make:resource', ...args]),
        1,
        reason: 'make:resource ${args.join(' ')} must be refused',
      );
      expect(err.toString(), message);
      expect(
        Directory(p.join(root.path, 'lib', 'app', 'http')).existsSync(),
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
      await refuses([''], contains('which model'));
    });

    test('naming it after the base class alone is refused', () async {
      await refuses(['Resource'], contains('which model'));
      expect(err.toString(), contains('--model'));
    });

    test('an unusable --model is refused', () async {
      await refuses(['PostResource', '--model=1post'], contains('--model'));
      await refuses(['PostResource', '--model=  '], contains('--model'));
    });

    test('--model equal to the generated class name is refused', () async {
      // The suffix-appending rule exists to stop the generated class
      // shadowing the model it wraps; `--model` must not be able to walk
      // around it.
      await refuses([
        'ImageResource',
        '--model=ImageResource',
      ], contains('cannot share a name'));
    });
  });

  test(
    'the generated resource analyzes, is formatted, and renders',
    () async {
      expect(
        await maat.run(['make:model', 'Post', '--fields=title:string']),
        0,
      );
      expect(await maat.run(['make:resource', 'PostResource']), 0);

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

      // Analyzing proves it compiles. Only rendering it proves the stub emits
      // JSON an encoder accepts — a raw DateTime passes the analyzer and then
      // throws at the first request.
      File(p.join(root.path, 'bin', 'check.dart'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('''
import 'dart:convert';

import 'package:maat/maat.dart';
import 'package:genapp/app/http/resources/post_resource.dart';
import 'package:genapp/app/models/post.dart';

void main() {
  final request = Request.create(method: 'GET', path: '/posts/1');
  final body = PostResource(
    Post(id: 1, title: 'Hello', createdAt: DateTime.utc(2026)),
  ).resolve(request);

  final json = jsonDecode(jsonEncode(body)) as Map<String, Object?>;
  final data = json['data']! as Map<String, Object?>;
  if (data['id'] != 1) throw StateError('the key did not render');
  if (data['created_at'] != '2026-01-01T00:00:00.000Z') {
    throw StateError('created_at did not render as ISO-8601');
  }
}
''');

      final run = await Process.run('dart', [
        'run',
        'bin/check.dart',
      ], workingDirectory: root.path);
      expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
