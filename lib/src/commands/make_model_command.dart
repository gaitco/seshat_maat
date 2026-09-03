import 'dart:io';

import 'package:maat/maat.dart';
import 'package:path/path.dart' as p;

import 'make_migration_command.dart';
import 'model_generator_command.dart';

/// One `--fields` entry, resolved to the Dart it generates.
///
/// A model spells the same column in four places — the constructor, the
/// field, `fromMap` and `toMap`, plus a cast entry — and they drift apart
/// the moment one is edited by hand. Parsing the column once and emitting
/// all four from this record is the whole point of `--fields`.
class _Field {
  const _Field(this.column, this.dartName, this.type);

  /// Database column, e.g. `published_at`.
  final String column;

  /// Dart identifier, e.g. `publishedAt`. Always lowerCamelCase:
  /// `non_constant_identifier_names` fires on a capitalised parameter.
  final String dartName;

  final _FieldType type;
}

class _FieldType {
  const _FieldType(
    this.dart, {
    this.cast,
    this.defaultValue,
    required this.fake,
  });

  /// Declared type, e.g. `String?`.
  final String dart;

  /// `Cast` expression for the definition's `casts` map, when the column
  /// needs decoding on the way out of the database.
  final String? cast;

  /// Constructor default. Non-null only for a non-nullable type.
  final String? defaultValue;

  /// Faker expression `make:model -f` puts in the factory's `definition`.
  final String fake;
}

/// Supported `--fields` types. Deliberately small and closed: an unknown
/// type is an error naming these, never a silent `dynamic` field that
/// compiles and then fails at the first `hydrate`.
const _fieldTypes = <String, _FieldType>{
  'string': _FieldType('String?', fake: 'faker.sentence()'),
  'text': _FieldType('String?', fake: 'faker.sentence()'),
  'int': _FieldType('int?', fake: 'faker.number()'),
  'bool': _FieldType(
    'bool',
    cast: 'Cast.boolean',
    defaultValue: 'false',
    fake: 'faker.boolean()',
  ),
  'datetime': _FieldType(
    'DateTime?',
    cast: 'Cast.dateTime',
    fake: 'faker.dateTime()',
  ),
};

/// Columns the stub always generates. A `--fields` entry naming one of them
/// would emit a duplicate constructor parameter, so it is refused.
const _reservedColumns = {'id', 'created_at', 'updated_at'};

/// Dart's reserved words. None may be an identifier, so none may be a field
/// name: `--fields class:string` would emit `this.class,`. Built-in
/// identifiers (`dynamic`, `late`, `required`, ...) are legal as variable
/// names and are deliberately absent.
const _dartReservedWords = {
  'assert',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'default',
  'do',
  'else',
  'enum',
  'extends',
  'false',
  'final',
  'finally',
  'for',
  'if',
  'in',
  'is',
  'new',
  'null',
  'rethrow',
  'return',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'var',
  'void',
  'while',
  'with',
};

/// Members the generated model declares itself or inherits from `Model`. A
/// field of the same name is a `conflicting_field_and_method` (or
/// `conflicting_static_and_instance`) error rather than a shadow, so the
/// generated file would not compile.
const _reservedMembers = {
  'def',
  'query',
  'definition',
  'toMap',
  'toJson',
  'toString',
  'connection',
  'pivot',
  'exists',
  'key',
  'original',
  'dirty',
  'isDirty',
  'setOriginal',
  'newQuery',
  'onConnection',
  'save',
  'update',
  'forceUpdate',
  'fill',
  'delete',
  'forceDelete',
  'refresh',
  'requireKey',
  'relationLoaded',
  'getRelation',
  'setRelation',
  'loadedRelations',
  'load',
  'wasRecentlyCreated',
  'hashCode',
  'runtimeType',
  'noSuchMethod',
};

/// A field's Dart name has to be a plain lowerCamelCase identifier: a
/// leading digit is not an identifier at all, and a capital fires
/// `non_constant_identifier_names` under `--fatal-infos`.
final _identifier = RegExp(r'^[a-z][A-Za-z0-9]*$');

/// Creates a model under `lib/app/models`, optionally with its migration
/// (`-m`), factory (`-f`) and API resource (`-r`).
///
/// `--fields "title:string published:bool"` is the reason this command
/// exists: it writes the declared field, the constructor parameter, the
/// `fromMap` read, the `toMap` write, the cast entry and the `fillable`
/// entry from one source, so they cannot disagree.
class MakeModelCommand extends GeneratorCommand {
  List<_Field> _fields = const [];

  @override
  String get name => 'make:model';

  @override
  String get description => 'Create a new Seshat model';

  @override
  String get type => 'Model';

  @override
  String get directory => 'lib/app/models';

  @override
  String get signature =>
      '{name} {--fields=} {--m|migration} {--f|factory} {--r|resource} '
      '{--force}';

  @override
  Future<int> handle() async {
    try {
      _fields = _parseFields(option('fields'));
    } on FormatException catch (e) {
      error(e.message);
      return 1;
    }

    // The factory's import needs the app's own package name, and a factory
    // lives outside `lib/` so it cannot reach the model relatively. Resolve
    // it before anything is written: a half-generated model plus a factory
    // with a broken import is worse than nothing generated at all.
    final String? packageName;
    if (flag('factory')) {
      packageName = _packageName();
      if (packageName == null) {
        error(
          'Cannot read the package name from pubspec.yaml, which the '
          'generated factory needs to import the model. Run this from the '
          'application root.',
        );
        return 1;
      }
    } else {
      packageName = null;
    }

    final created = await super.handle();
    if (created != 0) return created;

    if (flag('migration')) {
      final code = await _makeMigration();
      if (code != 0) return code;
    }
    if (flag('factory')) {
      final code = _write(
        _pathFor('database/factories', suffix: '_factory'),
        'Factory',
        _factoryStub(packageName!),
      );
      if (code != 0) return code;
    }
    if (flag('resource')) {
      final path = _pathFor('lib/app/http/resources', suffix: '_resource');
      final code = _write(
        path,
        'Resource',
        _resourceStub(p.url.relative(_modelPath, from: p.url.dirname(path))),
      );
      if (code != 0) return code;
    }
    return 0;
  }

  // ---------------------------------------------------------------------------
  // Names and paths
  // ---------------------------------------------------------------------------

  /// Mirrors [GeneratorCommand.handle]'s own splitting so the extra files
  /// land beside the model even for `make:model blog/Post`.
  List<String> get _nameParts => argument(
    'name',
  )!.replaceAll(RegExp(r'\.dart$'), '').split(RegExp(r'[/\\]'));

  String get _className => Str.studly(_nameParts.last);

  String get _fileBase => Str.snake(_className);

  List<String> get _subdirectories =>
      _nameParts.take(_nameParts.length - 1).map(Str.snake).toList();

  String get _modelPath => _pathFor(directory);

  String _pathFor(String base, {String suffix = ''}) =>
      p.url.joinAll([base, ..._subdirectories, '$_fileBase$suffix.dart']);

  String get _table => _plural(_fileBase);

  /// Enough English to stop `Category` becoming `categorys`. Laravel has a
  /// full inflector; this covers the regular cases and an irregular noun is
  /// a one-word edit in the generated `table:`.
  static String _plural(String word) {
    if (RegExp(r'[^aeiou]y$').hasMatch(word)) {
      return '${word.substring(0, word.length - 1)}ies';
    }
    if (RegExp(r'(s|x|z|ch|sh)$').hasMatch(word)) return '${word}es';
    return '${word}s';
  }

  static String _camel(String column) {
    final studly = Str.studly(column);
    return studly.isEmpty
        ? studly
        : studly[0].toLowerCase() + studly.substring(1);
  }

  // `this.app`: the `maat` umbrella library exports a top-level
  // `app<T>()` helper of the same name as the inherited field.
  String? _packageName() => packageNameAt(this.app.path('pubspec.yaml'));

  // ---------------------------------------------------------------------------
  // Field parsing
  // ---------------------------------------------------------------------------

  List<_Field> _parseFields(String? spec) {
    if (spec == null || spec.trim().isEmpty) return const [];
    final fields = <_Field>[];
    for (final token in spec.trim().split(RegExp(r'\s+'))) {
      final field = _parseField(token);
      // Two entries for one column emit two constructor parameters of the
      // same name, which does not compile. `dartName` is derived from
      // `column`, so checking the column catches both spellings —
      // `published_at` and `publishedAt` are the same field.
      if (fields.any((f) => f.column == field.column)) {
        throw FormatException(
          'Field [${field.column}] is declared twice. Remove the duplicate '
          'from --fields.',
        );
      }
      fields.add(field);
    }
    return fields;
  }

  _Field _parseField(String token) {
    final parts = token.split(':');
    if (parts.length != 2 || parts.any((part) => part.isEmpty)) {
      throw FormatException(
        'Field [$token] must be written name:type, e.g. title:string. '
        'Supported types: ${_supported()}.',
      );
    }
    final column = Str.snake(parts[0]);
    if (_reservedColumns.contains(column)) {
      throw FormatException(
        'Field [$column] is generated automatically; remove it from --fields.',
      );
    }
    final dartName = _camel(column);
    if (!_identifier.hasMatch(dartName)) {
      throw FormatException(
        'Field [${parts[0]}] is not a usable Dart name. Use letters and '
        'digits starting with a letter, e.g. published_at.',
      );
    }
    if (_dartReservedWords.contains(dartName)) {
      throw FormatException(
        'Field [$column] is a Dart keyword and cannot be a field name. '
        'Rename it, e.g. ${column}_name.',
      );
    }
    if (_reservedMembers.contains(dartName)) {
      throw FormatException(
        'Field [$column] collides with [$dartName], which the generated '
        'model already declares. Rename it, e.g. ${column}_value.',
      );
    }
    final type = _fieldTypes[parts[1].toLowerCase()];
    if (type == null) {
      throw FormatException(
        'Unknown field type [${parts[1]}] for [$column]. '
        'Supported types: ${_supported()}.',
      );
    }
    return _Field(column, dartName, type);
  }

  static String _supported() => _fieldTypes.keys.join(', ');

  // ---------------------------------------------------------------------------
  // Generation
  // ---------------------------------------------------------------------------

  int _write(String relative, String label, String contents) {
    final file = File(this.app.path(relative));
    if (file.existsSync() && !flag('force')) {
      error('$label [$relative] already exists. Use --force to overwrite.');
      return 1;
    }
    writeGenerated(relative, contents);
    info('$label [$relative] created successfully.');
    return 0;
  }

  /// Delegates to [MakeMigrationCommand] rather than writing a migration
  /// here, so the registry-append logic — the fiddly part — has one
  /// implementation. The body is the plain `t.id()` create stub: `--fields`
  /// describes Dart types, not column modifiers (length, nullability,
  /// indexes), so inferring a schema from them would guess.
  Future<int> _makeMigration() async {
    final command = MakeMigrationCommand()
      ..app = this.app
      ..out = out
      ..err = err;
    command.bind([
      'create_${_table}_table',
      '--create=$_table',
      if (flag('force')) '--force',
    ]);
    return command.handle();
  }

  @override
  String stub(String className) {
    final buffer = StringBuffer()
      ..writeln("import 'package:maat_seshat/maat_seshat.dart';")
      ..writeln()
      ..writeln('class $className extends Model<$className> {')
      ..writeln('  $className({')
      ..writeln('    this.id,');
    for (final field in _fields) {
      final fallback = field.type.defaultValue;
      buffer.writeln(
        '    this.${field.dartName}${fallback == null ? '' : ' = $fallback'},',
      );
    }
    buffer
      ..writeln('    this.createdAt,')
      ..writeln('    this.updatedAt,')
      ..writeln('  });')
      ..writeln()
      ..writeln(
        '  static final ModelDefinition<$className> def = '
        'ModelDefinition<$className>(',
      )
      ..writeln("    table: '$_table',")
      ..writeln('    fromMap: (m) => $className(')
      ..writeln("      id: m['id'] as int?,");
    for (final field in _fields) {
      final fallback = field.type.defaultValue;
      buffer.writeln(
        "      ${field.dartName}: m['${field.column}'] as "
        '${field.type.dart.endsWith('?') ? field.type.dart : '${field.type.dart}?'}'
        '${fallback == null ? '' : ' ?? $fallback'},',
      );
    }
    buffer
      ..writeln("      createdAt: m['created_at'] as DateTime?,")
      ..writeln("      updatedAt: m['updated_at'] as DateTime?,")
      ..writeln('    ),')
      ..writeln(
        '    fillable: [${_fields.map((f) => "'${f.column}'").join(', ')}],',
      )
      ..writeln('    casts: {');
    for (final field in _fields) {
      if (field.type.cast != null) {
        buffer.writeln("      '${field.column}': ${field.type.cast},");
      }
    }
    buffer
      ..writeln("      'created_at': Cast.dateTime,")
      ..writeln("      'updated_at': Cast.dateTime,")
      ..writeln('    },')
      ..writeln('  );')
      ..writeln()
      ..writeln('  @override')
      ..writeln('  ModelDefinition<$className> get definition => def;')
      ..writeln()
      ..writeln('  static QueryBuilder<$className> query() => def.query();')
      ..writeln()
      ..writeln('  final int? id;');
    for (final field in _fields) {
      buffer.writeln('  final ${field.type.dart} ${field.dartName};');
    }
    buffer
      ..writeln('  final DateTime? createdAt;')
      ..writeln('  final DateTime? updatedAt;')
      ..writeln()
      ..writeln('  @override')
      ..writeln('  Map<String, Object?> toMap() => {')
      ..writeln("    'id': id,");
    for (final field in _fields) {
      buffer.writeln("    '${field.column}': ${field.dartName},");
    }
    buffer
      ..writeln("    'created_at': createdAt,")
      ..writeln("    'updated_at': updatedAt,")
      ..writeln('  };')
      ..writeln('}');
    return buffer.toString();
  }

  /// `state` and `count` construct a NEW factory instead of mutating this
  /// one: a factory held in a variable and reused across tests otherwise
  /// leaks the first test's states into the second. Most users will copy
  /// their first factory from this stub, so the stub has to be the correct
  /// pattern rather than the convenient one.
  String _factoryStub(String packageName) {
    final buffer = StringBuffer()
      ..writeln("import 'package:maat_seshat/maat_seshat.dart';")
      ..writeln("import 'package:$packageName/${_modelPath.substring(4)}';")
      ..writeln()
      ..writeln('class ${_className}Factory extends Factory<$_className> {')
      ..writeln(
        '  ${_className}Factory({super.faker, super.count, super.states}) '
        ': super($_className.def);',
      )
      ..writeln()
      ..writeln('  @override')
      ..writeln('  Map<String, Object?> definition(Faker faker) => {');
    for (final field in _fields) {
      buffer.writeln("    '${field.column}': ${field.type.fake},");
    }
    buffer
      ..writeln('  };')
      ..writeln()
      ..writeln('  @override')
      ..writeln(
        '  ${_className}Factory state(Map<String, Object?> attributes) => '
        '${_className}Factory(faker: faker, count: countOf, '
        'states: [...states, attributes]);',
      )
      ..writeln()
      ..writeln('  @override')
      ..writeln(
        '  ${_className}Factory count(int n) => '
        '${_className}Factory(faker: faker, count: n, states: states);',
      )
      ..writeln('}');
    return buffer.toString();
  }

  String _resourceStub(String modelImport) {
    final buffer = StringBuffer()
      ..writeln("import 'package:maat/maat.dart';")
      ..writeln()
      ..writeln("import '$modelImport';")
      ..writeln()
      ..writeln(
        'class ${_className}Resource extends JsonResource<$_className> {',
      )
      ..writeln('  ${_className}Resource(super.resource);')
      ..writeln()
      ..writeln('  @override')
      ..writeln('  Map<String, Object?> toJson(Request request) => {')
      ..writeln("    'id': resource.id,");
    for (final field in _fields) {
      // DateTime is not JSON-encodable, so a date is serialised here rather
      // than handed to the encoder as-is.
      final value = field.type.dart.startsWith('DateTime')
          ? '${field.dartName}?.toIso8601String()'
          : field.dartName;
      buffer.writeln("    '${field.column}': resource.$value,");
    }
    buffer
      ..writeln("    'created_at': resource.createdAt?.toIso8601String(),")
      ..writeln("    'updated_at': resource.updatedAt?.toIso8601String(),")
      ..writeln('  };')
      ..writeln('}');
    return buffer.toString();
  }
}
