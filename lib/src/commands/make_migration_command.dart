import 'dart:io';

import 'package:maat/maat.dart';

/// Creates a timestamped migration file under `database/migrations` and
/// registers it — both an `import` and a list entry — in
/// `database/migrations.dart`.
///
/// Doesn't extend [GeneratorCommand]: migration file names carry a
/// `yyyy_MM_dd_HHmmss` prefix that [GeneratorCommand.handle] has no hook to
/// inject, and this command also has to rewrite the migrations registry —
/// work no other `make:*` command needs to do.
class MakeMigrationCommand extends Command with GeneratesFiles {
  /// [clock] is injectable so tests can control the timestamp deterministically.
  MakeMigrationCommand({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const _registryHeader =
      "import 'package:maat_seshat/maat_seshat.dart';\n"
      '\n'
      'final migrations = <Migration>[\n'
      '];\n';

  @override
  String get name => 'make:migration';

  @override
  String get description => 'Create a new migration file';

  @override
  String get signature => '{name} {--create=} {--table=} {--force}';

  @override
  Future<int> handle() async {
    // Strip a trailing `.dart` the way GeneratorCommand.handle does, so
    // tab-completing the argument doesn't emit an invalid `Foo.dart` class.
    final raw = argument('name')!.replaceAll(RegExp(r'\.dart$'), '');
    final className = Str.studly(raw);
    final migrationName = '${_timestamp(_clock())}_${Str.snake(className)}';
    // `m` prefix: an identifier (and so a `file_names`-lint-clean file name)
    // can't start with a digit. `Migration.name` (the migrations-table
    // identity) stays unprefixed — run order comes from the registry list,
    // not the file name, so this is purely cosmetic for the file system.
    final fileName = 'm$migrationName.dart';
    final relative = 'database/migrations/$fileName';
    // `this.app`: `Command.app` is inherited, and this file imports the
    // `maat` umbrella library, which also exports the top-level
    // `app<T>()` helper of the same name — qualify to reach the field.
    final file = File(this.app.path(relative));

    final create = _nonEmpty(option('create'));
    final table = _nonEmpty(option('table'));

    final registryFile = File(this.app.path('database/migrations.dart'));
    final existingRegistry = registryFile.existsSync()
        ? registryFile.readAsStringSync()
        : _registryHeader;

    final fileAlreadyExists = file.existsSync();
    if (fileAlreadyExists && !flag('force')) {
      error('Migration [$relative] already exists. Use --force to overwrite.');
      return 1;
    }
    // A *different* file registering the same class name is refused
    // outright — two migrations declaring `class $className` is an
    // `ambiguous_import` the moment the project is analyzed. Re-running the
    // very same migration with --force (same file, same class) is not a
    // duplicate: it's caught by [fileAlreadyExists] above, and the registry
    // insert below is idempotent for it.
    //
    if (!fileAlreadyExists && _registers(existingRegistry, className)) {
      error(
        'Migration [$className] is already registered in database/migrations.dart.',
      );
      return 1;
    }

    final updatedRegistry = _buildUpdatedRegistry(
      existingRegistry,
      fileName,
      className,
    );
    if (updatedRegistry == null) {
      error(
        'database/migrations.dart has no `final migrations = <Migration>[...]` '
        'list to register into. Fix it by hand, or delete the file so it can '
        'be recreated.',
      );
      return 1;
    }

    writeGenerated(relative, _stub(className, migrationName, create, table));
    writeGenerated('database/migrations.dart', updatedRegistry);

    info('Migration [$relative] created successfully.');
    return 0;
  }

  /// Whether [content] already constructs `ClassName()`.
  ///
  /// Matched on an identifier boundary, not a substring: `CreatePostsTable()`
  /// appears inside `RecreatePostsTable()`, and refusing the second as a
  /// duplicate of the first would be wrong. The trailing comma is not part of
  /// the needle — the registry is written through `writeGenerated`, and
  /// `dart format` collapses a short list onto one line and drops the comma
  /// on its last entry.
  static bool _registers(String content, String className) => RegExp(
    r'(?<![A-Za-z0-9_$])'
    '${RegExp.escape(className)}'
    r'\(\)',
  ).hasMatch(content);

  String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  String _timestamp(DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}_${two(now.month)}_${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  /// The parameter is the transaction-bound [SchemaBuilder] the migrator
  /// injects into `up`/`down` (`Migrator.run()` calls
  /// `m.up(SchemaBuilder(tx, grammar))`). It's named `schema`, matching
  /// `maat_seshat_core`'s own `Migration.up(SchemaBuilder schema)` signature —
  /// not the static `Schema` facade, which binds to `DB.connection` rather
  /// than the migration's own transaction, so using it here would silently
  /// run outside that transaction.
  String _stub(
    String className,
    String migrationName,
    String? create,
    String? table,
  ) {
    final buffer = StringBuffer()
      ..writeln("import 'package:maat_seshat/maat_seshat.dart';")
      ..writeln()
      ..writeln('class $className extends Migration {')
      ..writeln('  @override')
      ..writeln("  String get name => '$migrationName';")
      ..writeln();

    if (create != null) {
      buffer
        ..writeln('  @override')
        ..writeln(
          "  Future<void> up(SchemaBuilder schema) => schema.create('$create', (t) {",
        )
        ..writeln('    t.id();')
        // Seshat's `timestamps` defaults to true, so every insert names
        // created_at/updated_at. A create stub without these columns
        // produces a table the model cannot save to — the two files are
        // each internally plausible and broken together. Laravel's create
        // stub emits `$table->timestamps();` for the same reason.
        ..writeln('    t.timestamps();')
        ..writeln('  });')
        ..writeln()
        ..writeln('  @override')
        ..writeln(
          "  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('$create');",
        );
    } else if (table != null) {
      buffer
        ..writeln('  @override')
        ..writeln(
          "  Future<void> up(SchemaBuilder schema) => schema.table('$table', (t) {",
        )
        ..writeln('    //')
        ..writeln('  });')
        ..writeln()
        ..writeln('  @override')
        ..writeln(
          "  Future<void> down(SchemaBuilder schema) => schema.table('$table', (t) {",
        )
        ..writeln('    //')
        ..writeln('  });');
    } else {
      buffer
        ..writeln('  @override')
        ..writeln('  Future<void> up(SchemaBuilder schema) async {}')
        ..writeln()
        ..writeln('  @override')
        ..writeln('  Future<void> down(SchemaBuilder schema) async {}');
    }

    buffer.writeln('}');
    return buffer.toString();
  }

  /// Inserts the entry immediately before the closing `];` of the
  /// `final migrations = <Migration>[...]` declaration specifically (not
  /// whatever `];` happens to be last in the file — a second list or any
  /// other trailing content containing `];` must not steal the entry), and
  /// the import after the file's last directive line (`library`/`import`/
  /// `export`/`part`), never at line 0 where it could land above a
  /// `library` directive and fail to compile.
  ///
  /// Returns `null` when the registry has no migrations list to anchor on,
  /// so the caller can refuse rather than writing somewhere arbitrary.
  /// Idempotent: if [className] is already registered, returns [content]
  /// unchanged (the `--force` re-run-the-same-migration path).
  /// The list body (everything between `[` and `];`) with [className]
  /// appended, one entry per line. `dart format` collapses a short list onto
  /// one line and drops its trailing comma — `<Migration>[CreateATable()]` —
  /// so the previous entry gets the comma it needs rather than the insertion
  /// assuming the file is still shaped the way it was written.
  ///
  /// A comment-only line (the skeleton registry ships with one) is not code
  /// and never receives a comma.
  static String _appendEntry(String body, String className) {
    final lines = body.split('\n').map((line) => line.trimRight()).toList()
      ..removeWhere((line) => line.isEmpty);
    // ponytail: a trailing `// note` on the last entry line would swallow the
    // comma. `dart format` always leaves a trailing comma on a list it keeps
    // multi-line, so that shape doesn't occur in a formatted registry.
    final last = lines.lastIndexWhere(
      (line) => !line.trimLeft().startsWith('//'),
    );
    if (last != -1 && !lines[last].endsWith(',')) {
      lines[last] = '${lines[last]},';
    }
    return [
      '',
      for (final line in lines)
        line.startsWith('  ') ? line : '  ${line.trimLeft()}',
      '  $className(),',
      '',
    ].join('\n');
  }

  String? _buildUpdatedRegistry(
    String content,
    String fileName,
    String className,
  ) {
    if (_registers(content, className)) {
      return content;
    }

    final anchor = RegExp(
      r'final\s+migrations\s*=\s*(const\s+)?<Migration>\s*\[',
    ).firstMatch(content);
    if (anchor == null) return null;
    final closing = content.indexOf('];', anchor.end);
    if (closing == -1) return null;

    final withEntry =
        '${content.substring(0, anchor.end)}'
        '${_appendEntry(content.substring(anchor.end, closing), className)}'
        '${content.substring(closing)}';

    final directive = RegExp(r'^\s*(library\b|import\b|export\b|part\b)');
    final lines = withEntry.split('\n');
    var lastDirective = -1;
    for (var i = 0; i < lines.length; i++) {
      if (directive.hasMatch(lines[i])) lastDirective = i;
    }
    lines.insert(lastDirective + 1, "import 'migrations/$fileName';");
    return lines.join('\n');
  }
}
