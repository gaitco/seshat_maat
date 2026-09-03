import 'package:maat_seshat_core/maat_seshat_core.dart';
import 'package:maat/maat.dart';

/// Page size from `?per_page=`, clamped to [max].
///
/// The cap is not optional: `?per_page=1000000` is a trivial denial-of-service
/// against any paginated endpoint. Laravel leaves this to the developer and it
/// is routinely forgotten.
int resolvePerPage(Request request, {int fallback = 15, int max = 100}) {
  final raw = int.tryParse(request.query('per_page') ?? '');
  if (raw == null || raw < 1) return fallback;
  return raw > max ? max : raw;
}

/// Page number from `?page=`, defaulting to the first page.
int resolvePage(Request request) {
  final raw = int.tryParse(request.query('page') ?? '');
  return (raw == null || raw < 1) ? 1 : raw;
}

extension RequestPagination<T> on QueryBuilder<T> {
  /// `paginateRequest(request)` — reads `?page=` and `?per_page=` and delegates
  /// to maat_seshat_core's `paginate({page, perPage})`.
  ///
  /// An explicit [perPage] overrides `?per_page=` entirely AND bypasses the
  /// cap in [resolvePerPage]. That is deliberate: the cap defends against a
  /// *client*-supplied page size, and this argument is chosen by the developer
  /// in server code. Pass [resolvePerPage] yourself if you want it clamped.
  ///
  /// Named `paginateRequest`, not `paginate`: Dart resolves instance members
  /// before extension members, so a `paginate(Request)` extension would be
  /// unreachable behind [QueryBuilder.paginate]. The ORM is peer-owned and
  /// stays HTTP-unaware, so the extension yields the name instead.
  Future<Paginator<T>> paginateRequest(Request request, {int? perPage}) =>
      paginate(
        page: resolvePage(request),
        perPage: perPage ?? resolvePerPage(request),
      );
}

/// Laravel's `data`/`links`/`meta` envelope. [Paginator.toJson] returns a flat
/// map, so the shape is built here rather than delegated.
Map<String, Object?> paginatedResponse<T>(
  Paginator<T> page,
  Request request, {
  Object? Function(T item)? item,
}) {
  String url(int n) {
    // queryParametersAll, not queryParameters: the latter is a
    // Map<String, String> and collapses repeats, so `?tag=a&tag=b` would come
    // back as `?tag=b` and a client following `next` would silently lose half
    // its filter.
    final q = Map<String, List<String>>.from(request.uri.queryParametersAll)
      ..['page'] = ['$n'];
    // publicUri, not uri: behind a reverse proxy the accepted hop is plain
    // HTTP on a private port, and a `next` link built from it sends an
    // HTTPS client back to HTTP.
    return request.publicUri.replace(queryParameters: q).toString();
  }

  return {
    'data': [for (final d in page.data) item == null ? d : item(d)],
    'links': {
      'first': url(1),
      'last': url(page.lastPage),
      'prev': page.previousPage == null ? null : url(page.previousPage!),
      'next': page.nextPage == null ? null : url(page.nextPage!),
    },
    'meta': {
      'current_page': page.currentPage,
      'per_page': page.perPage,
      'total': page.total,
      'last_page': page.lastPage,
      'from': page.from,
      'to': page.to,
    },
  };
}

/// Shapes many [T] through [using], Laravel's `UserResource::collection(...)`.
///
/// A top-level function taking a constructor tear-off, never a static on
/// [JsonResource]: Dart does not inherit statics, so `UserResource.collection`
/// would not resolve.
///
/// [items] may be:
/// * an `Iterable<T>` — produces `{"data": [...]}`;
/// * a [Paginator] of `T` — produces `data`/`links`/`meta`, which is why
///   [request] exists;
/// * the missing-value sentinel from [JsonResource.whenLoaded] — passed
///   straight through so the key stays *absent* from the parent resource. An
///   empty list here would tell the client the relation is empty, which is a
///   different and false claim;
/// * `null` — a nullable relation stays null.
///
/// [request] is required, not optional. Every item is shaped by
/// `toJson(request)`, so a fabricated request would render each one against
/// `GET http://localhost/` — headers gone, path wrong, `when(isAdmin, ...)`
/// silently false. Callers are already inside `toJson(Request request)` and
/// have one to hand.
Object? resourceCollection<T>(
  Object? items,
  JsonResource<T> Function(T) using,
  Request request,
) {
  if (JsonResource.isMissing(items)) return items;
  if (items == null) return null;

  if (items is Paginator<T>) {
    return paginatedResponse<T>(
      items,
      request,
      item: (i) => _shape(using(i), request),
    );
  }

  // `Iterable`, not `Iterable<T>`: `items` is `Object?`, so a bare `[]` infers
  // `List<dynamic>` and an exact generic test would reject the most natural way
  // to write an empty collection. The per-element cast keeps it honest — a
  // genuinely wrong element raises a TypeError naming its real type.
  if (items is Iterable) {
    return {
      'data': [for (final i in items) _shape(using(i as T), request)],
    };
  }

  throw ArgumentError.value(
    items,
    'items',
    'expected an Iterable, a Paginator<$T>, or a missing value',
  );
}

/// One item's body, without its own `data` envelope — the collection already
/// provides one. Goes through [JsonResource.resolve] so missing values and
/// nested resources are stripped by the same code as a single resource.
///
/// Keys from [JsonResource.additional] survive the unwrapping and are merged
/// into the item, ahead of the body so the body still wins — the same rule
/// `resolve` applies for a `wrap: false` resource. Reading `out['data']` and
/// stopping there would drop them under `wrap: true` and keep them under
/// `wrap: false`, so the same resource would render differently depending on
/// a flag that is supposed to control only the envelope.
///
/// This is a divergence from Laravel, where `additional()` is applied by the
/// response object and a per-item call is ignored.
Object? _shape(JsonResource<Object?> resource, Request request) {
  final out = resource.resolve(request);
  if (!resource.wrap) return out;
  final body = out['data'];
  if (out.length == 1 || body is! Map<String, Object?>) return body;
  final extra = {...out}..remove('data');
  return {...extra, ...body};
}
