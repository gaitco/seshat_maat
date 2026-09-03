import 'package:maat/maat.dart';
import 'package:maat_seshat/maat_seshat.dart';
import 'package:test/test.dart';

void main() {
  Request req(String path) => Request.create(method: 'GET', path: path);

  test('resolvePerPage takes the request value', () {
    expect(resolvePerPage(req('/users?per_page=30')), 30);
  });

  test('resolvePerPage falls back when absent or unparseable', () {
    expect(resolvePerPage(req('/users')), 15);
    expect(resolvePerPage(req('/users?per_page=abc')), 15);
  });

  test('resolvePerPage CAPS the value', () {
    expect(resolvePerPage(req('/users?per_page=1000000')), 100);
    expect(resolvePerPage(req('/users?per_page=1000000'), max: 50), 50);
  });

  test('resolvePerPage rejects zero and negatives', () {
    expect(resolvePerPage(req('/users?per_page=0')), 15);
    expect(resolvePerPage(req('/users?per_page=-5')), 15);
    expect(resolvePerPage(req('/users?per_page=0'), fallback: 25), 25);
  });

  test('resolvePage defaults to 1 and rejects junk', () {
    expect(resolvePage(req('/users')), 1);
    expect(resolvePage(req('/users?page=0')), 1);
    expect(resolvePage(req('/users?page=-3')), 1);
    expect(resolvePage(req('/users?page=abc')), 1);
    expect(resolvePage(req('/users?page=4')), 4);
  });

  test('the envelope is data/links/meta, not the flat paginator shape', () {
    final page = Paginator<int>(
      data: [1, 2],
      total: 134,
      perPage: 15,
      currentPage: 2,
    );
    final out = paginatedResponse(page, req('/users?page=2'));

    expect(out.keys, containsAll(['data', 'links', 'meta']));
    expect(out.containsKey('total'), isFalse, reason: 'flat keys go in meta');
    expect(out['data'], [1, 2]);
    expect(out['meta'], {
      'current_page': 2,
      'per_page': 15,
      'total': 134,
      'last_page': 9,
      'from': 16,
      'to': 17,
    });
  });

  test('resourceCollection over a plain list wraps in data only', () {
    final out =
        resourceCollection([_User(1), _User(2)], _UserResource.new, req('/u'))!
            as Map;
    expect(out.keys, ['data']);
    expect(out['data']! as List, hasLength(2));
    expect((out['data']! as List).first, {'id': 1});
  });

  test('resourceCollection over a paginator produces data/links/meta', () {
    final page = Paginator<_User>(
      data: [_User(1)],
      total: 1,
      perPage: 15,
      currentPage: 1,
    );
    final out =
        resourceCollection(page, _UserResource.new, req('/users'))! as Map;
    expect(out.keys, containsAll(['data', 'links', 'meta']));
    expect(out['data'], [
      {'id': 1},
    ]);
  });

  test('resourceCollection passes a missing value straight through', () {
    // whenLoaded returns the sentinel for an unloaded relation; the key must
    // stay absent from the parent resource rather than becoming an empty list.
    final resource = _ParentResource(_User(1));
    final out = resource.resolve(req('/users'))['data']! as Map;
    expect(out.containsKey('friends'), isFalse);
    expect(out['id'], 1);
  });

  test('resourceCollection passes null through', () {
    expect(resourceCollection(null, _UserResource.new, req('/u')), isNull);
  });

  test('resourceCollection rejects a shape it cannot render', () {
    expect(
      () => resourceCollection('nope', _UserResource.new, req('/u')),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('an empty untyped list is a collection, not an error', () {
    // A bare `[]` infers List<dynamic>, so an exact `is Iterable<T>` test
    // would reject the most natural way to write an empty collection.
    final out = resourceCollection([], _UserResource.new, req('/u'))! as Map;
    expect(out, {'data': <Object?>[]});
  });

  test('an upcast List<Object> of the right elements still renders', () {
    final items = <Object>[_User(1)];
    final out = resourceCollection(items, _UserResource.new, req('/u'))! as Map;
    expect(out['data'], [
      {'id': 1},
    ]);
  });

  test('an empty collection stays distinguishable from a missing one', () {
    // Both are falsy to a naive client; only one of them is a claim about the
    // data. `{"data": []}` says "no rows"; the sentinel says "not loaded".
    final empty = resourceCollection(<_User>[], _UserResource.new, req('/u'));
    final missing =
        _ParentResource(_User(1)).resolve(req('/u'))['data']! as Map;
    expect(empty, {'data': <Object?>[]});
    expect(missing.containsKey('friends'), isFalse);
  });

  test('a wrong element type raises a TypeError naming it', () {
    expect(
      () => resourceCollection(<Object>['nope'], _UserResource.new, req('/u')),
      throwsA(
        isA<TypeError>().having(
          (e) => '$e',
          'message',
          allOf(contains('String'), contains('_User')),
        ),
      ),
    );
  });

  test('a per-item additional() survives whichever way the item wraps', () {
    // `wrap` controls the envelope, not the payload: taking `out['data']`
    // and stopping there kept additional() keys under `wrap: false` and
    // dropped them under the default, so one flag silently changed two
    // things. Both spellings must render the same item.
    Object? render(JsonResource<_User> Function(_User) using) =>
        (resourceCollection([_User(1)], using, req('/u'))! as Map)['data'];

    const expected = [
      {'note': 'hi', 'id': 1},
    ];
    expect(
      render((u) => _UserResource(u).additional({'note': 'hi'})),
      expected,
    );
    expect(
      render((u) => _UnwrappedResource(u).additional({'note': 'hi'})),
      expected,
    );

    // The body still wins over the extras, exactly as it does for a single
    // resource — additional() cannot rewrite a column.
    expect(render((u) => _UserResource(u).additional({'id': 99})), [
      {'id': 1},
    ]);
  });

  test('a hidden field inside a collection item is stripped', () {
    // Items go through JsonResource.resolve, not toJson: a raw sentinel would
    // otherwise reach jsonEncode and die inside the response encoder, far from
    // the resource that produced it.
    final out =
        resourceCollection([_User(1)], _HidingResource.new, req('/u'))! as Map;
    final first = (out['data']! as List).first as Map;
    expect(first.containsKey('secret'), isFalse);
    expect(first, {'id': 1});
  });

  test('links preserve REPEATED query parameters', () {
    // Uri.queryParameters is a Map<String, String> and collapses repeats, so
    // building links from it turns ?tag=a&tag=b into ?tag=b and silently
    // rewrites the client's filter as it pages.
    final page = Paginator<int>(
      data: [1],
      total: 30,
      perPage: 15,
      currentPage: 2,
    );
    final links =
        paginatedResponse(page, req('/users?tag=a&tag=b&page=2'))['links']!
            as Map;

    expect(links['first'], contains('tag=a'));
    expect(links['first'], contains('tag=b'));
    expect(links['prev'], contains('tag=a'));
    expect(links['prev'], contains('tag=b'));
  });

  test('links preserve existing query parameters', () {
    final page = Paginator<int>(
      data: [1],
      total: 30,
      perPage: 15,
      currentPage: 2,
    );
    final links =
        paginatedResponse(page, req('/users?include=posts&page=2'))['links']!
            as Map;

    expect(links['prev'], contains('include=posts'));
    expect(links['prev'], contains('page=1'));
    expect(links['next'], isNull);
    expect(links['first'], contains('page=1'));
    expect(links['last'], contains('page=2'));
  });
}

class _User {
  _User(this.id);

  final int id;
}

class _UserResource extends JsonResource<_User> {
  _UserResource(super.resource);

  @override
  Map<String, Object?> toJson(Request request) => {'id': resource.id};
}

class _ParentResource extends JsonResource<_User> {
  _ParentResource(super.resource);

  @override
  Map<String, Object?> toJson(Request request) => {
    'id': resource.id,
    // `_User` is not a model, so `whenLoaded` reports the relation absent and
    // returns the sentinel; `resourceCollection` must hand it back untouched.
    'friends': resourceCollection(
      whenLoaded('friends'),
      _UserResource.new,
      request,
    ),
  };
}

class _UnwrappedResource extends JsonResource<_User> {
  _UnwrappedResource(super.resource);

  @override
  bool get wrap => false;

  @override
  Map<String, Object?> toJson(Request request) => {'id': resource.id};
}

class _HidingResource extends JsonResource<_User> {
  _HidingResource(super.resource);

  @override
  Map<String, Object?> toJson(Request request) => {
    'id': resource.id,
    'secret': when(false, () => 'nope'),
  };
}
