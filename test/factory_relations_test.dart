import 'package:maat_seshat/maat_seshat.dart';
import 'package:test/test.dart';

void main() {
  setUp(() async {
    DB.use(SqliteConnection.open(':memory:'));
    await DB.statement(
      'create table widgets (id integer primary key autoincrement, '
      'name text, code text)',
    );
    await DB.statement(
      'create table parts (id integer primary key autoincrement, '
      'widget_id integer, label text)',
    );
    await DB.statement(
      'create table badges (id integer primary key autoincrement, '
      'widget_code text, tag text)',
    );
  });

  tearDown(() async {
    await DB.connection.close();
    DB.reset();
  });

  test('has() creates the children with the foreign key set', () async {
    final w = await WidgetFactory()
        .has(PartFactory().count(3), 'parts')
        .createOne();

    final parts = await DB.table('parts').where('widget_id', w.id).get();
    expect(parts, hasLength(3));
  });

  test('belongsTo() attaches to an existing parent', () async {
    final w = await WidgetFactory().createOne();

    final p = await PartFactory().belongsTo(w, 'widget').createOne();

    expect(p.widgetId, w.id);
  });

  test('an unknown relation name throws immediately and lists the real '
      'ones', () {
    expect(
      () => WidgetFactory().has(PartFactory(), 'prts'),
      throwsA(
        isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('prts'))
            .having((e) => '$e', 'message', contains('parts')),
      ),
    );
  });

  test('a relation that exists but is of the wrong kind is rejected', () {
    // `widget` IS declared on Part — as a belongsTo, which has() cannot use.
    expect(
      () => PartFactory().has(WidgetFactory(), 'widget'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '$e',
          'message',
          allOf(
            contains('widget'),
            contains('hasOne/hasMany'),
            contains('Part'),
          ),
        ),
      ),
    );

    // `parts` IS declared on Widget — as a hasMany, which belongsTo cannot use.
    expect(
      () => WidgetFactory().belongsTo(Part(label: 'x'), 'parts'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '$e',
          'message',
          allOf(contains('parts'), contains('belongsTo'), contains('Widget')),
        ),
      ),
    );
  });

  test('has() runs after the parent is saved so the key exists', () async {
    final w = await WidgetFactory()
        .has(PartFactory().count(2), 'parts')
        .createOne();

    expect(w.id, isNotNull);
    final orphans = await DB.table('parts').whereNull('widget_id').count();
    expect(
      orphans,
      0,
      reason: 'children must never be written before the parent has an id',
    );
  });

  test('every parent gets its own children', () async {
    final widgets = await WidgetFactory()
        .has(PartFactory().count(2), 'parts')
        .count(3)
        .create();

    expect(widgets, hasLength(3));
    for (final w in widgets) {
      expect(await DB.table('parts').where('widget_id', w.id).count(), 2);
    }
  });

  test('has() does not mutate the factory it was called on', () async {
    final base = WidgetFactory();

    base.has(PartFactory().count(2), 'parts');
    await base.createOne();

    expect(
      await DB.table('parts').count(),
      0,
      reason: 'has() must return a new factory, not mutate in place',
    );
  });

  test('pending children survive a state() applied after has()', () async {
    final w = await WidgetFactory().has(PartFactory().count(2), 'parts').state({
      'name': 'gizmo',
    }).createOne();

    expect(w.name, 'gizmo');
    expect(await DB.table('parts').where('widget_id', w.id).count(), 2);
  });

  test('two has() calls keep both relations', () async {
    final w = await WidgetFactory()
        .has(PartFactory().count(2), 'parts')
        .has(BadgeFactory(), 'badge')
        .state({'code': 'XYZ'})
        .createOne();

    expect(await DB.table('parts').where('widget_id', w.id).count(), 2);
    expect(await DB.table('badges').where('widget_code', 'XYZ').count(), 1);
  });

  test('a factory for the wrong model is rejected, not written to its own '
      'table', () async {
    expect(
      () => WidgetFactory().has(BadgeFactory(), 'parts'),
      throwsA(
        isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('Badge'))
            .having((e) => '$e', 'message', contains('parts')),
      ),
    );
    expect(await DB.table('badges').count(), 0);
  });

  test('a parent of the wrong model is rejected', () async {
    // Saved, so its key is set: an unsaved parent would trip the null-key
    // guard instead and the test would pass for the wrong reason.
    final badge = await BadgeFactory().createOne();

    expect(
      () => PartFactory().belongsTo(badge, 'widget'),
      throwsA(
        isA<ArgumentError>().having((e) => '$e', 'message', contains('Badge')),
      ),
    );
  });

  test('belongsTo() refuses an unsaved parent rather than writing a null '
      'key', () {
    expect(
      () => PartFactory().belongsTo(Widget(name: 'ghost'), 'widget'),
      throwsA(
        isA<ArgumentError>()
            .having((e) => '$e', 'message', contains('Widget'))
            .having((e) => '$e', 'message', contains('widget_id')),
      ),
    );
  });

  test('has() refuses to write children whose local key is unset', () async {
    // `badge` links widgets.code → badges.widget_code, and this widget has
    // no code: without the guard every badge lands orphaned.
    await expectLater(
      WidgetFactory().has(BadgeFactory(), 'badge').createOne(),
      throwsA(
        isA<StateError>().having((e) => '$e', 'message', contains('code')),
      ),
    );
    expect(await DB.table('badges').count(), 0);
  });

  test('has() keeps a subclass makeOne() and countOf override', () {
    final made = TaggedWidgetFactory().has(PartFactory(), 'parts').make();

    expect(made.map((w) => w.name), everyElement('MADE-BY-OVERRIDE'));
    expect(
      made,
      hasLength(4),
      reason: "the wrapper must carry the subclass's countOf",
    );
  });
}

class Widget extends Model<Widget> {
  Widget({this.id, required this.name, this.code});

  static final ModelDefinition<Widget> def = ModelDefinition<Widget>(
    table: 'widgets',
    fromMap: Widget.fromMap,
    timestamps: false,
    relations: (r) => r
      ..hasMany('parts', Part.def, foreignKey: 'widget_id')
      ..hasOne('badge', Badge.def, foreignKey: 'widget_code', localKey: 'code'),
  );

  @override
  ModelDefinition<Widget> get definition => def;

  final int? id;
  final String name;
  final String? code;

  static Widget fromMap(Map<String, Object?> map) => Widget(
    id: map['id'] as int?,
    name: map['name'] as String,
    code: map['code'] as String?,
  );

  @override
  Map<String, Object?> toMap() => {'id': id, 'name': name, 'code': code};
}

class Part extends Model<Part> {
  Part({this.id, this.widgetId, required this.label});

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
  final String label;

  static Part fromMap(Map<String, Object?> map) => Part(
    id: map['id'] as int?,
    widgetId: map['widget_id'] as int?,
    label: map['label'] as String,
  );

  @override
  Map<String, Object?> toMap() => {
    'id': id,
    'widget_id': widgetId,
    'label': label,
  };
}

class WidgetFactory extends Factory<Widget> {
  WidgetFactory({super.faker, super.count, super.states}) : super(Widget.def);

  @override
  Map<String, Object?> definition(Faker faker) => {'name': faker.name()};

  @override
  WidgetFactory state(Map<String, Object?> attributes) => WidgetFactory(
    faker: faker,
    count: countOf,
    states: [...states, attributes],
  );

  @override
  WidgetFactory count(int n) =>
      WidgetFactory(faker: faker, count: n, states: states);

  WidgetFactory named(String name) => state({'name': name});
}

class PartFactory extends Factory<Part> {
  PartFactory({super.faker, super.count, super.states}) : super(Part.def);

  @override
  Map<String, Object?> definition(Faker faker) => {'label': faker.name()};

  @override
  PartFactory state(Map<String, Object?> attributes) => PartFactory(
    faker: faker,
    count: countOf,
    states: [...states, attributes],
  );

  @override
  PartFactory count(int n) =>
      PartFactory(faker: faker, count: n, states: states);
}

class Badge extends Model<Badge> {
  Badge({this.id, this.widgetCode, required this.tag});

  static final ModelDefinition<Badge> def = ModelDefinition<Badge>(
    table: 'badges',
    fromMap: Badge.fromMap,
    timestamps: false,
  );

  @override
  ModelDefinition<Badge> get definition => def;

  final int? id;
  final String? widgetCode;
  final String tag;

  static Badge fromMap(Map<String, Object?> map) => Badge(
    id: map['id'] as int?,
    widgetCode: map['widget_code'] as String?,
    tag: map['tag'] as String,
  );

  @override
  Map<String, Object?> toMap() => {
    'id': id,
    'widget_code': widgetCode,
    'tag': tag,
  };
}

class BadgeFactory extends Factory<Badge> {
  BadgeFactory({super.faker, super.count, super.states}) : super(Badge.def);

  @override
  Map<String, Object?> definition(Faker faker) => {'tag': faker.name()};

  @override
  BadgeFactory state(Map<String, Object?> attributes) => BadgeFactory(
    faker: faker,
    count: countOf,
    states: [...states, attributes],
  );

  @override
  BadgeFactory count(int n) =>
      BadgeFactory(faker: faker, count: n, states: states);
}

/// Pins that the decorator keeps a subclass's overrides.
class TaggedWidgetFactory extends WidgetFactory {
  TaggedWidgetFactory({super.faker, super.count, super.states});

  @override
  int get countOf => 4;

  @override
  Widget makeOne() => Widget(name: 'MADE-BY-OVERRIDE');
}
