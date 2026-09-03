import 'dart:io';

import 'package:maat/maat.dart';
import 'package:path/path.dart' as p;

/// A plain ASCII Dart identifier: letters and digits, starting with a letter.
///
/// [Str.studly] only upper-cases the first character, so it turns `1post`
/// into `1post` and `post!` into `Post!` — both of which are accepted by
/// every generator that does not check, and neither of which compiles. It
/// cannot produce a reserved word either (they are all lower case), which is
/// why there is no keyword check here.
final _identifier = RegExp(r'^[A-Za-z][A-Za-z0-9]*$');

/// The `name:` the pubspec at [path] declares, or null when there is no
/// pubspec or it declares no name.
///
/// Generated files that live outside `lib/` can only reach the application's
/// own code through a `package:` import, and that needs this name.
String? packageNameAt(String path) {
  final pubspec = File(path);
  if (!pubspec.existsSync()) return null;
  return RegExp(
    r'''^name:\s*["']?([A-Za-z_][A-Za-z0-9_]*)''',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync())?[1];
}

/// Shared shape of `make:factory` and `make:resource`: a generator named
/// after a model, whose own class name carries a fixed [suffix].
///
/// `make:factory Post` and `make:factory PostFactory` both produce
/// `PostFactory` over the model `Post`. Appending the suffix rather than
/// taking the name literally is not politeness: taken literally,
/// `make:resource Post` emits `class Post extends JsonResource<Post>`, which
/// does not compile — the class would shadow the model it wraps.
abstract class ModelGeneratorCommand extends GeneratorCommand {
  /// `Factory` or `Resource`. The class name ends with it, and the model
  /// name is what remains once it is removed.
  String get suffix;

  @override
  String get signature => '{name} {--model=} {--force}';

  String _className = '';
  List<String> _subdirectories = const [];

  /// The model's path segments: snake-cased subdirectories under
  /// `lib/app/models`, then its studly class name.
  List<String> _model = const [];

  /// The class the stub declares, e.g. `PostFactory`.
  String get className => _className;

  /// The model the stub is written against, e.g. `Post`.
  String get modelClass => _model.last;

  /// Where that model lives, e.g. `lib/app/models/blog/post.dart`.
  String get modelPath => p.url.joinAll([
    'lib/app/models',
    ..._model.take(_model.length - 1),
    '${Str.snake(modelClass)}.dart',
  ]);

  /// Where the generated file lands, relative to the application root.
  String get relativePath => p.url.joinAll([
    directory,
    ..._subdirectories,
    '${Str.snake(_className)}.dart',
  ]);

  @override
  Future<int> handle() async {
    try {
      _resolveNames();
    } on FormatException catch (e) {
      error(e.message);
      return 1;
    }

    final file = File(this.app.path(relativePath));
    if (file.existsSync() && !flag('force')) {
      error('$type [$relativePath] already exists. Use --force to overwrite.');
      return 1;
    }
    // A warning, not an error: the model may be about to be written, and
    // refusing would make `make:resource` useless in a scaffolding script.
    // Silence would not do either — a mistyped name generates a file whose
    // import resolves to nothing, and the analyzer reports that far from the
    // command that caused it.
    if (!File(this.app.path(modelPath)).existsSync()) {
      warn(
        'Model [$modelPath] does not exist, and the generated $type imports '
        'it. Create the model first, or point --model at the one you meant.',
      );
    }
    writeGenerated(relativePath, stub(_className));
    info('$type [$relativePath] created successfully.');
    return 0;
  }

  /// Splits `blog/PostFactory` into its directory segments and class name.
  static List<String> _split(String raw) {
    final parts = raw
        .replaceAll(RegExp(r'\.dart$'), '')
        .split(RegExp(r'[/\\]'));
    return [
      ...parts.take(parts.length - 1).map(Str.snake),
      Str.studly(parts.last),
    ];
  }

  void _resolveNames() {
    final parts = _split(argument('name')!);
    final base = parts.last;
    _className = base.endsWith(suffix) ? base : '$base$suffix';
    if (!_identifier.hasMatch(_className)) {
      throw FormatException(
        '[$base] is not a usable class name. Use letters and digits starting '
        'with a letter, e.g. `$name Post$suffix`.',
      );
    }
    _subdirectories = parts.take(parts.length - 1).toList();

    final declared = option('model');
    _model = declared == null
        ? [
            ..._subdirectories,
            base.endsWith(suffix)
                ? base.substring(0, base.length - suffix.length)
                : base,
          ]
        : _split(declared);

    if (declared != null && !_identifier.hasMatch(modelClass)) {
      throw FormatException(
        '[${declared.trim()}] is not a usable model class name. Pass '
        '`--model` as letters and digits starting with a letter, e.g. '
        '`--model=Post`.',
      );
    }
    if (modelClass.isEmpty) {
      throw FormatException(
        'Cannot work out which model [$_className] is for — nothing is left '
        'once [$suffix] is removed. Name it after the model, e.g. '
        '`$name Post$suffix`, or pass `--model=Post`.',
      );
    }
    if (modelClass == _className) {
      throw FormatException(
        'Model [$modelClass] and the generated class [$_className] cannot '
        'share a name — the $type would shadow the model it wraps. Point '
        '`--model` at the actual model instead, e.g. `--model=Post`.',
      );
    }
  }
}
