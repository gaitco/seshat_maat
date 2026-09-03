import 'package:maat/maat.dart';
import 'package:seshat_maat/seshat_maat.dart';
import 'package:test/test.dart';

/// Pins the contract between `JsonResource.whenLoaded` and
/// `Model.loadedRelations`.
///
/// `whenLoaded` reads `(resource as dynamic).loadedRelations` inside a
/// `try / on NoSuchMethodError`, because `package:maat` cannot depend on
/// the ORM. That catch is necessary but silent: rename or remove
/// `Model.loadedRelations` and every `whenLoaded()` would report "not loaded"
/// forever — no error, no log line, relations quietly missing from every API
/// response. This package depends on both sides, so it is where the contract
/// can be checked. These tests turn that silent rename into a red build.
void main() {
  setUp(() async {
    DB.use(SqliteConnection.open(':memory:'));
    await DB.statement(
      'create table users (id integer primary key autoincrement, name text, '
      'created_at text, updated_at text)',
    );
    await DB.statement(
      'create table posts (id integer primary key autoincrement, '
      'user_id integer, title text, created_at text, updated_at text)',
    );
    final ann = await _User.def.query().create({'name': 'Ann'});
    await _Post.def.query().create({'user_id': ann.id, 'title': 'A1'});
    await _Post.def.query().create({'user_id': ann.id, 'title': 'A2'});
    await _User.def.query().create({'name': 'Bob'});
  });

  tearDown(() async {
    await DB.connection.close();
    DB.reset();
  });

  final request = Request.create(path: '/users');

  test(
    'an eager-loaded relation reaches the resource through whenLoaded',
    () async {
      final ann = await _User.def.with_(['posts']).firstOrFail();

      // Guards the contract from the ORM side too: if this is empty the
      // assertion below would pass for the wrong reason.
      expect(ann.loadedRelations.containsKey('posts'), isTrue);

      final out = _UserResource(ann).resolve(request)['data']! as Map;

      expect(out['posts'], isNotNull, reason: 'whenLoaded lost the relation');
      expect((out['posts']! as Map)['data'], [
        {'title': 'A1'},
        {'title': 'A2'},
      ]);
    },
  );

  test(
    'the same resource omits the relation when it was NOT eager-loaded',
    () async {
      final ann = await _User.def.query().firstOrFail();
      final out = _UserResource(ann).resolve(request)['data']! as Map;

      expect(out.containsKey('posts'), isFalse);
      expect(out['name'], 'Ann');
    },
  );

  test('paginateRequest reads page and per_page off the request', () async {
    final page = await _User.def
        .query()
        .orderBy('id')
        .paginateRequest(Request.create(path: '/users?page=2&per_page=1'));

    expect(page.currentPage, 2);
    expect(page.perPage, 1);
    expect(page.total, 2);
    expect(page.lastPage, 2);
    expect(page.data.single.name, 'Bob');
  });

  test('paginateRequest caps a hostile per_page', () async {
    final page = await _User.def.query().paginateRequest(
      Request.create(path: '/users?per_page=1000000'),
    );

    expect(page.perPage, 100);
  });

  test(
    'an explicit perPage wins over the query string and skips the cap',
    () async {
      // Deliberate: the cap defends against a CLIENT-supplied page size. An
      // explicit argument is developer-chosen server-side code, so it is honoured
      // as written — including above the cap.
      final beats = await _User.def.query().paginateRequest(
        Request.create(path: '/users?per_page=1'),
        perPage: 2,
      );
      expect(beats.perPage, 2, reason: 'the explicit argument wins');
      expect(beats.data, hasLength(2));

      final uncapped = await _User.def.query().paginateRequest(
        Request.create(path: '/users?per_page=1'),
        perPage: 100000,
      );
      expect(uncapped.perPage, 100000, reason: 'the cap is client-only');
    },
  );

  test('a paginated resource collection is a full Laravel envelope', () async {
    final request = Request.create(path: '/users?per_page=1');
    final page = await _User.def
        .with_(['posts'])
        .orderBy('id')
        .paginateRequest(request);
    final out =
        resourceCollection(page, _UserResource.new, request)!
            as Map<String, Object?>;

    expect(out['data'], [
      {
        'name': 'Ann',
        'posts': {
          'data': [
            {'title': 'A1'},
            {'title': 'A2'},
          ],
        },
      },
    ]);
    expect((out['meta']! as Map)['total'], 2);
    expect((out['links']! as Map)['next'], contains('page=2'));
  });
}

class _User extends Model<_User> {
  _User({this.id, required this.name});

  static final ModelDefinition<_User> def = ModelDefinition<_User>(
    table: 'users',
    fromMap: _User.fromMap,
    fillable: ['name'],
    relations: (r) => r..hasMany('posts', _Post.def, foreignKey: 'user_id'),
  );

  @override
  ModelDefinition<_User> get definition => def;

  final int? id;
  final String name;

  static _User fromMap(Map<String, Object?> map) =>
      _User(id: map['id'] as int?, name: map['name'] as String);

  @override
  Map<String, Object?> toMap() => {'id': id, 'name': name};
}

class _Post extends Model<_Post> {
  _Post({this.id, this.userId, required this.title});

  static final ModelDefinition<_Post> def = ModelDefinition<_Post>(
    table: 'posts',
    fromMap: _Post.fromMap,
    fillable: ['user_id', 'title'],
  );

  @override
  ModelDefinition<_Post> get definition => def;

  final int? id;
  final int? userId;
  final String title;

  static _Post fromMap(Map<String, Object?> map) => _Post(
    id: map['id'] as int?,
    userId: map['user_id'] as int?,
    title: map['title'] as String,
  );

  @override
  Map<String, Object?> toMap() => {'id': id, 'user_id': userId, 'title': title};
}

class _PostResource extends JsonResource<_Post> {
  _PostResource(super.resource);

  @override
  Map<String, Object?> toJson(Request request) => {'title': resource.title};
}

class _UserResource extends JsonResource<_User> {
  _UserResource(super.resource);

  @override
  Map<String, Object?> toJson(Request request) => {
    'name': resource.name,
    'posts': resourceCollection(
      whenLoaded('posts'),
      _PostResource.new,
      request,
    ),
  };
}
