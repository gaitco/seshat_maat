import 'package:maat/maat.dart';
import 'package:seshat_maat/seshat_maat.dart';
import 'package:test/test.dart';

void main() {
  // No tables: nothing here executes a query, and `def.query()` only needs a
  // connection to exist.
  setUp(() => DB.use(SqliteConnection.open(':memory:')));

  tearDown(() async {
    await DB.connection.close();
    DB.reset();
  });

  Request req(String path) => Request.create(method: 'GET', path: path);

  test('allowed includes reach with_()', () {
    final q = Widget.def.query().includes(
      req('/w?include=parts'),
      allow: ['parts'],
    );

    expect(q.eagerLoads.keys, ['parts']);
  });

  test('an unlisted include throws a 422 naming what IS allowed', () {
    expect(
      () => Widget.def.query().includes(
        req('/w?include=secrets'),
        allow: ['parts'],
      ),
      throwsA(
        isA<HttpException>()
            .having((e) => e.statusCode, 'statusCode', 422)
            .having((e) => '$e', 'message', contains('secrets'))
            .having((e) => '$e', 'message', contains('parts')),
      ),
    );
  });

  test('an unlisted include is NOT silently dropped', () {
    // A silent drop looks to the client like missing data with a 200: they
    // cannot tell a typo from an empty relation.
    final q = Widget.def.query();

    expect(
      () => q.includes(req('/w?include=parts,secrets'), allow: ['parts']),
      throwsA(isA<HttpException>()),
    );
    expect(
      q.eagerLoads,
      isEmpty,
      reason: 'the whole parameter is rejected, not partially applied',
    );
  });

  test('depth is capped even when the allowlist is careless', () {
    expect(
      () => Widget.def.query().includes(
        req('/w?include=parts.widget.parts'),
        allow: ['parts.widget.parts'],
      ),
      throwsA(
        isA<HttpException>()
            .having((e) => e.statusCode, 'statusCode', 422)
            .having((e) => '$e', 'message', contains('parts.widget.parts'))
            .having((e) => '$e', 'message', contains('2')),
      ),
    );
  });

  test('a value that is both unlisted and too deep reports the allowlist', () {
    // The allowlist message is the actionable one — it hands back the whole
    // permitted vocabulary. Reporting the depth first would make the client
    // fix the nesting and earn a second 422 for the same parameter.
    expect(
      () => Widget.def.query().includes(
        req('/w?include=a.b.c'),
        allow: ['parts'],
      ),
      throwsA(
        isA<HttpException>().having((e) => '$e', 'message', contains('parts')),
      ),
    );
  });

  test('a depth of exactly maxDepth is allowed', () {
    final q = Widget.def.query().includes(
      req('/w?include=parts.widget'),
      allow: ['parts.widget'],
    );

    expect(q.eagerLoads.keys, ['parts.widget']);
  });

  test('maxDepth moves the boundary in both directions', () {
    final shallow = Widget.def.query().includes(
      req('/w?include=parts'),
      allow: ['parts', 'parts.widget'],
      maxDepth: 1,
    );
    expect(shallow.eagerLoads.keys, ['parts']);

    expect(
      () => Widget.def.query().includes(
        req('/w?include=parts.widget'),
        allow: ['parts', 'parts.widget'],
        maxDepth: 1,
      ),
      throwsA(isA<HttpException>()),
      reason: 'one dot is two levels, which exceeds maxDepth: 1',
    );

    final deep = Widget.def.query().includes(
      req('/w?include=parts.widget.parts'),
      allow: ['parts.widget.parts'],
      maxDepth: 3,
    );
    expect(deep.eagerLoads.keys, ['parts.widget.parts']);
  });

  test('no include parameter is a no-op', () {
    final q = Widget.def.query().includes(req('/w'), allow: ['parts']);

    expect(q.eagerLoads, isEmpty);
  });

  test('an empty include parameter is a no-op, not a rejected value', () {
    final q = Widget.def.query().includes(req('/w?include='), allow: ['parts']);

    expect(q.eagerLoads, isEmpty);
  });

  test('whitespace and empty segments are ignored', () {
    final q = Widget.def.query().includes(
      req('/w?include=parts,,%20parts'),
      allow: ['parts'],
    );

    expect(q.eagerLoads.keys, ['parts']);
  });

  test('a repeated include loads the relation once', () {
    final q = Widget.def.query().includes(
      req('/w?include=parts,parts'),
      allow: ['parts'],
    );

    expect(q.eagerLoads.keys, ['parts']);
  });

  test('an include and its own nested child both survive', () {
    // `parts.widget` alone already loads `parts`, so the pair is not a
    // contradiction — the eager loader groups them into one query per level.
    final q = Widget.def.query().includes(
      req('/w?include=parts,parts.widget'),
      allow: ['parts', 'parts.widget'],
    );

    expect(q.eagerLoads.keys, ['parts', 'parts.widget']);
  });

  // Matching must be exact. Each case below is the input that separates the
  // shipped comparison from one plausible loosening of it — a green suite that
  // did not contain them would not notice the loosening.

  test('a longer name that starts with an allowed one is rejected', () {
    // `include.startsWith(allowed)`: `allow: ['posts']` would admit
    // `posts.paymentMethods`, the exact hole the allowlist exists to close.
    expect(
      () => Widget.def.query().includes(
        req('/w?include=partsx'),
        allow: ['parts'],
      ),
      throwsA(isA<HttpException>()),
    );
  });

  test('a child of an allowed relation is rejected', () {
    // Permission runs from child to parent, never parent to child.
    expect(
      () => Widget.def.query().includes(
        req('/w?include=parts.widget'),
        allow: ['parts'],
      ),
      throwsA(isA<HttpException>()),
    );
  });

  test('matching is case-sensitive', () {
    expect(
      () => Widget.def.query().includes(
        req('/w?include=PARTS'),
        allow: ['parts'],
      ),
      throwsA(isA<HttpException>()),
    );
  });

  test('a substring of an allowed name is rejected', () {
    // `allowed.contains(include)`: 'parts'.contains('art').
    expect(
      () =>
          Widget.def.query().includes(req('/w?include=art'), allow: ['parts']),
      throwsA(isA<HttpException>()),
    );
  });

  test('a prefix of an allowed name is rejected', () {
    // The ancestor rule matches on `'$include.'`, not on `include`: without
    // the dot, 'parts'.startsWith('part') would admit `part`.
    expect(
      () =>
          Widget.def.query().includes(req('/w?include=part'), allow: ['parts']),
      throwsA(isA<HttpException>()),
    );
  });

  test('allowing a nested path also allows its ancestors', () {
    // `parts.widget` returns the parts either way — the eager loader groups
    // both under the root `parts` — so demanding a separate `parts` entry
    // would be a usability trap, not a boundary.
    final q = Widget.def.query().includes(
      req('/w?include=parts'),
      allow: ['parts.widget'],
    );

    expect(q.eagerLoads.keys, ['parts']);
  });

  test('an allowlist naming an undeclared relation fails loudly, not as a '
      '500 at query time', () {
    // Without this the endpoint answers 422 "Permitted includes: psots", and
    // the client that copies that name back gets {"message":"Server Error"}.
    expect(
      () => Widget.def.query().includes(
        req('/w?include=psots'),
        allow: ['psots'],
      ),
      throwsA(
        isA<StateError>()
            .having((e) => '$e', 'message', contains('psots'))
            .having((e) => '$e', 'message', contains('allow list'))
            .having((e) => '$e', 'message', contains('parts')),
      ),
    );
  });

  test('a typo deeper in an allowed path is caught too, not just the '
      'root', () {
    expect(
      () => Widget.def.query().includes(
        req('/w?include=parts.widgt'),
        allow: ['parts.widgt'],
      ),
      throwsA(
        isA<StateError>().having((e) => '$e', 'message', contains('widgt')),
      ),
    );
  });

  test('includes on a bare table query throws instead of dropping them', () {
    // No ModelDefinition means QueryBuilder records the eager loads and then
    // skips them: a 200 with the relation missing, the silent drop this
    // feature exists to prevent.
    expect(
      () => DB
          .table('widgets')
          .includes(req('/w?include=parts'), allow: ['parts']),
      throwsA(
        isA<StateError>().having(
          (e) => '$e',
          'message',
          contains('ModelDefinition'),
        ),
      ),
    );
  });

  test('a bare table query without includes is still a no-op', () {
    expect(
      DB.table('widgets').includes(req('/w'), allow: ['parts']).eagerLoads,
      isEmpty,
    );
    expect(
      DB
          .table('widgets')
          .includes(req('/w?include='), allow: ['parts'])
          .eagerLoads,
      isEmpty,
    );
  });

  test('an empty allowlist rejects every include and says so', () {
    expect(
      () => Widget.def.query().includes(req('/w?include=parts'), allow: []),
      throwsA(
        isA<HttpException>()
            .having((e) => e.statusCode, 'statusCode', 422)
            .having((e) => '$e', 'message', contains('parts')),
      ),
    );
  });
}

class Widget extends Model<Widget> {
  Widget({this.id, required this.name});

  static final ModelDefinition<Widget> def = ModelDefinition<Widget>(
    table: 'widgets',
    fromMap: Widget.fromMap,
    timestamps: false,
    relations: (r) => r.hasMany('parts', Part.def, foreignKey: 'widget_id'),
  );

  @override
  ModelDefinition<Widget> get definition => def;

  final int? id;
  final String name;

  static Widget fromMap(Map<String, Object?> map) =>
      Widget(id: map['id'] as int?, name: map['name'] as String);

  @override
  Map<String, Object?> toMap() => {'id': id, 'name': name};
}

class Part extends Model<Part> {
  Part({this.id, this.widgetId});

  static final ModelDefinition<Part> def = ModelDefinition<Part>(
    table: 'parts',
    fromMap: Part.fromMap,
    timestamps: false,
    relations: (r) =>
        r.belongsTo('widget', Widget.def, foreignKey: 'widget_id'),
  );

  @override
  ModelDefinition<Part> get definition => def;

  final int? id;
  final int? widgetId;

  static Part fromMap(Map<String, Object?> map) =>
      Part(id: map['id'] as int?, widgetId: map['widget_id'] as int?);

  @override
  Map<String, Object?> toMap() => {'id': id, 'widget_id': widgetId};
}
