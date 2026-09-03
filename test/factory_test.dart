import 'package:maat_seshat/maat_seshat.dart';
import 'package:test/test.dart';

void main() {
  setUp(() async {
    DB.use(SqliteConnection.open(':memory:'));
    await DB.statement(
      'create table widgets (id integer primary key autoincrement, '
      'name text, active integer)',
    );
  });

  tearDown(() async {
    await DB.connection.close();
    DB.reset();
  });

  test('make() does not touch the database', () async {
    final made = WidgetFactory().count(3).make();
    expect(made, hasLength(3));
    expect(await DB.table('widgets').count(), 0);
  });

  test('makeOne() does not touch the database either', () async {
    WidgetFactory().makeOne();
    expect(await DB.table('widgets').count(), 0);
  });

  test('create() persists and returns saved models', () async {
    final rows = await WidgetFactory().count(3).create();
    expect(rows, hasLength(3));
    expect(await DB.table('widgets').count(), 3);
    expect(rows.every((w) => w.id != null), isTrue);
  });

  test('createOne() persists exactly one row and returns it saved', () async {
    final w = await WidgetFactory().createOne();
    expect(await DB.table('widgets').count(), 1);
    expect(w.id, isNotNull);
    expect(w.exists, isTrue);
  });

  test('state overrides the definition', () async {
    final w = await WidgetFactory().inactive().createOne();
    expect(w.active, isFalse);
  });

  test('states compose, last write wins', () async {
    final w = await WidgetFactory().inactive().named('fixed').createOne();
    expect(w.active, isFalse);
    expect(w.name, 'fixed');
  });

  test('the last state wins even over an earlier state on the SAME key', () {
    final w = WidgetFactory().named('first').named('second').makeOne();
    expect(w.name, 'second');
  });

  test('state does not mutate the factory it was called on', () {
    final base = WidgetFactory();
    base.inactive();
    expect(
      base.makeOne().active,
      isTrue,
      reason: 'state() must return a new factory, not mutate in place',
    );
  });

  test('count does not mutate the factory it was called on', () {
    final base = WidgetFactory();
    base.count(5);
    expect(
      base.make(),
      hasLength(1),
      reason: 'count() must return a new factory, not mutate in place',
    );
  });

  test('count keeps the states already applied', () {
    final made = WidgetFactory().inactive().count(2).make();
    expect(made, hasLength(2));
    expect(made.every((w) => w.active == false), isTrue);
  });

  test('state keeps the count already applied', () {
    expect(WidgetFactory().count(2).inactive().make(), hasLength(2));
  });

  test('the exposed states list cannot be edited from outside', () {
    final f = WidgetFactory().inactive();
    expect(() => f.states.add({'name': 'x'}), throwsUnsupportedError);
  });

  test('the caller keeps no handle on the map it passed to state()', () {
    // Freezing only the outer list is worse than freezing nothing: it reads
    // as a guarantee, so nobody checks the map the caller still holds.
    final passed = <String, Object?>{'name': 'original'};
    final f = WidgetFactory().state(passed);

    passed['name'] = 'AFTER';

    expect(
      f.makeOne().name,
      'original',
      reason: 'the state map must be copied, not stored by reference',
    );
  });

  test('a state map reached through states cannot be edited', () {
    final f = WidgetFactory().named('original');

    expect(() => f.states[0]['name'] = 'INJECTED', throwsUnsupportedError);
    expect(f.makeOne().name, 'original');
  });

  test('a seeded factory replays the same attributes', () {
    expect(
      WidgetFactory(faker: Faker(42)).makeOne().name,
      WidgetFactory(faker: Faker(42)).makeOne().name,
    );
  });

  test('one factory advances its faker across the models it builds', () {
    final made = WidgetFactory(faker: Faker(42)).count(20).make();
    expect(
      made.map((w) => w.name).toSet().length,
      greaterThan(1),
      reason: 'every model shared one attribute map instead of regenerating',
    );
  });

  test('persisted values round-trip through the database', () async {
    final w = await WidgetFactory().named('round-trip').inactive().createOne();
    final row = (await DB.table('widgets').where('id', w.id).get()).single;

    expect(row['name'], 'round-trip');
    expect(Widget.def.decodeAttributes(row)['active'], isFalse);
  });
}

class Widget extends Model<Widget> {
  Widget({this.id, required this.name, required this.active});

  static final ModelDefinition<Widget> def = ModelDefinition<Widget>(
    table: 'widgets',
    fromMap: Widget.fromMap,
    timestamps: false,
    casts: {'active': Cast.boolean},
  );

  @override
  ModelDefinition<Widget> get definition => def;

  final int? id;
  final String name;
  final bool active;

  static Widget fromMap(Map<String, Object?> map) => Widget(
    id: map['id'] as int?,
    name: map['name'] as String,
    active: map['active'] as bool,
  );

  @override
  Map<String, Object?> toMap() => {'id': id, 'name': name, 'active': active};
}

class WidgetFactory extends Factory<Widget> {
  WidgetFactory({super.faker, super.count, super.states}) : super(Widget.def);

  @override
  Map<String, Object?> definition(Faker faker) => {
    'name': faker.name(),
    'active': true,
  };

  @override
  WidgetFactory state(Map<String, Object?> attributes) => WidgetFactory(
    faker: faker,
    count: countOf,
    states: [...states, attributes],
  );

  @override
  WidgetFactory count(int n) =>
      WidgetFactory(faker: faker, count: n, states: states);

  WidgetFactory inactive() => state({'active': false});

  WidgetFactory named(String name) => state({'name': name});
}
