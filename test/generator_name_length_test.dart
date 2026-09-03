import 'dart:io';

import 'package:maat/maat.dart';
import 'package:seshat_maat/seshat_maat.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_application.dart';

/// The shape `dart format` chooses depends on how long the generated names
/// are: the same stub that is tidy for `Post` is rejoined or re-split for
/// `Tag` and for `SubscriptionCancellation`. Asserting on one hand-picked
/// name therefore proves nothing about the next one, which is how the
/// hand-formatted stubs stayed broken. Every generator is swept across the
/// whole realistic range of name lengths instead.
void main() {
  /// A studly model name of exactly [length] characters.
  String modelName(int length) => 'M${'x' * (length - 1)}';

  /// Every length that the hand-formatted stubs actually broke at, plus the
  /// two ends of the realistic range.
  ///
  /// Generated code can no longer be mis-formatted by construction — the
  /// generator runs `dart format` over what it wrote — so sweeping all forty
  /// lengths spends about eighty seconds re-proving that `dart format`
  /// formats. These ten are the ones with a reason: 1 and 2 are degenerate
  /// class names, 3 is where the formatter reaches for a shape no hand-written
  /// stub expressed, 4 and 23 bounded the old factory stub's correct range, 20
  /// bounded the resource stub's, 24 is where the constructor stops fitting on
  /// one line, and 31 is `SubscriptionCancellationFactory`. 40 is past any
  /// name a real application uses.
  ///
  /// Widen this back to a full range if the stubs ever go back to carrying
  /// their own line breaks; short of that, a slow suite is a suite people
  /// stop running.
  final lengths = [1, 2, 3, 4, 20, 21, 23, 24, 31, 40];

  const fields = 'title:string published:bool published_at:datetime views:int';

  /// Generates once per name length into a throwaway application, then holds
  /// everything written to the bar generated code has to meet: it analyzes
  /// clean, and the generator never warned that it could not format it.
  Future<void> sweep(
    Future<void> Function(Sesh maat, String model) generate,
  ) async {
    final root = Directory.systemTemp.createTempSync('sweep');
    addTearDown(() {
      root.deleteSync(recursive: true);
      Application.reset();
    });

    final framework = p.normalize(Directory.current.path);
    File(
      p.join(root.path, 'pubspec.yaml'),
    ).writeAsStringSync(testConsumerPubspec(framework));
    File(p.join(root.path, 'analysis_options.yaml')).writeAsStringSync(
      File(
        p.join(
          framework,
          '..',
          'ptah',
          'lib',
          'skeleton',
          'analysis_options.yaml',
        ),
      ).readAsStringSync(),
    );

    final out = StringBuffer();
    final err = StringBuffer();
    final app = await buildTestApplication(basePath: root.path);
    final maat = Sesh(app, out: out, err: err, commands: databaseCommands());

    for (final length in lengths) {
      await generate(maat, modelName(length));
    }
    expect(err.toString(), isEmpty);
    // The generator warns instead of failing when it cannot format what it
    // wrote, so this is the assertion that catches a formatting breakdown —
    // the file on disk would be valid Dart, merely untidy.
    expect(out.toString(), isNot(contains('WARNING')));

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
    // guarantee lives in `writeGenerated`; the `WARNING` assertion above is
    // what catches it breaking down, because the generator warns rather than
    // failing when it cannot format.
  }

  Future<void> run(Sesh maat, List<String> args) async =>
      expect(await maat.run(args), 0, reason: args.join(' '));

  const timeout = Timeout(Duration(minutes: 5));

  test(
    'make:model analyzes clean at every name length',
    () => sweep((maat, model) => run(maat, ['make:model', model])),
    timeout: timeout,
  );

  test(
    'make:model --fields analyzes clean at every name length',
    () => sweep(
      (maat, model) => run(maat, ['make:model', model, '--fields=$fields']),
    ),
    timeout: timeout,
  );

  test(
    'make:model -f analyzes clean at every name length',
    () => sweep(
      (maat, model) =>
          run(maat, ['make:model', model, '--fields=$fields', '-f']),
    ),
    timeout: timeout,
  );

  test(
    'make:model -r analyzes clean at every name length',
    () => sweep(
      (maat, model) =>
          run(maat, ['make:model', model, '--fields=$fields', '-r']),
    ),
    timeout: timeout,
  );

  test(
    'make:factory analyzes clean at every name length',
    () => sweep((maat, model) async {
      await run(maat, ['make:model', model]);
      await run(maat, ['make:factory', '${model}Factory']);
    }),
    timeout: timeout,
  );

  test(
    'make:resource analyzes clean at every name length',
    () => sweep((maat, model) async {
      await run(maat, ['make:model', model]);
      await run(maat, ['make:resource', '${model}Resource']);
    }),
    timeout: timeout,
  );
}
