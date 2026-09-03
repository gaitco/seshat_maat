import 'package:seshat/seshat.dart';
import 'package:maat/maat.dart';

extension RequestIncludes<T> on QueryBuilder<T> {
  /// Eager loads the relations named by `?include=posts,posts.comments`,
  /// restricted to [allow] and to [maxDepth] levels.
  ///
  /// Laravel ships no such feature; this follows `spatie/laravel-query-builder`,
  /// where the allowlist is the first thing the documentation insists on. It is
  /// mandatory here — there is no allow-everything mode — because an
  /// unrestricted `?include=` is two holes at once: `?include=user.paymentMethods`
  /// walks a relation graph the endpoint never meant to expose, and nested
  /// includes multiply queries until a client can walk the server over.
  ///
  /// A rejected include is a 422 naming the permitted values, never a silent
  /// drop: a drop reaches the client as missing data with a 200, and they
  /// cannot tell a typo from an empty relation. The body is `{"message": ...}`
  /// with no `errors` key — unlike a validation 422, which is a different
  /// exception. (spatie answers 400; the 422 here is deliberate, matching the
  /// rest of this framework's input rejections.) Nothing is applied to the
  /// builder unless *every* value passes, so a rejected request leaves no
  /// half-built query behind.
  ///
  /// Matching is exact and case-sensitive, with one deliberate widening:
  /// allowlisting `posts.comments` also permits `posts`. The nested load
  /// already returns the parent — the eager loader groups both under the root
  /// `posts` and loads it either way — so demanding both entries would be a
  /// usability trap, not a security boundary. The implication runs one way
  /// only: allowing `posts` does *not* permit `posts.comments`.
  ///
  /// [maxDepth] is enforced independently of [allow] — a carelessly
  /// allowlisted `a.b.c.d` is still refused. Depth counts levels, not dots:
  /// `posts` is 1, `posts.comments` is 2.
  ///
  /// Throws [StateError], not a 422, for the two developer mistakes: a query
  /// with no [ModelDefinition] (a bare `DB.table(...)` cannot eager-load at
  /// all, so its includes would be recorded and then ignored — a silent drop
  /// by another name), and an [allow] entry naming a relation the model does
  /// not declare (which would otherwise surface as `Server Error` from the
  /// eager loader, after the endpoint's own 422 had advertised the misspelling
  /// as permitted). Neither is anything a client can provoke or fix.
  QueryBuilder<T> includes(
    Request request, {
    required List<String> allow,
    int maxDepth = 2,
  }) {
    final raw = request.query('include');
    if (raw == null) return this;

    final wanted = <String>[];
    // ponytail: O(segments x allow.length) string compares, bounded only by
    // the HTTP layer's URL limit. Distinct eager loads are already bounded by
    // allow.length; index `allow` if the parse loop ever shows up in a profile.
    for (final part in raw.split(',')) {
      final include = part.trim();
      if (include.isEmpty) continue;

      if (!allow.any((a) => a == include || a.startsWith('$include.'))) {
        throw HttpException(
          422,
          'Include [$include] is not allowed. Permitted includes: '
          '${allow.isEmpty ? '(none)' : allow.join(', ')}.',
        );
      }
      final depth = '.'.allMatches(include).length + 1;
      if (depth > maxDepth) {
        throw HttpException(
          422,
          'Include [$include] is $depth relations deep; at most $maxDepth '
          'are allowed. Each dot adds a level, so "a.b" is 2 levels.',
        );
      }
      wanted.add(include);
    }
    if (wanted.isEmpty) return this;

    final def = definition;
    if (def == null) {
      throw StateError(
        'includes([${wanted.join(', ')}]) needs a model query. This builder '
        'has no ModelDefinition — a bare DB.table(...) query records eager '
        'loads and then ignores them, answering 200 with the relations '
        'missing. Query the model instead: Model.def.query().',
      );
    }
    for (final include in wanted) {
      _assertDeclared(def, include);
    }

    // Duplicates are harmless: with_() uses putIfAbsent, and the eager loader
    // groups "posts" and "posts.comments" into one query per level.
    return with_(wanted);
  }
}

/// Walks [include] segment by segment through the relation graph so a typo in
/// the *allowlist* fails here, naming itself, instead of surfacing later as a
/// `DatabaseException` from the eager loader. Whole-path, never root-only:
/// checking only `posts` would pass `posts.commnts` while implying the whole
/// path had been verified.
void _assertDeclared(ModelDefinition<Object?> def, String include) {
  var current = def;
  for (final segment in include.split('.')) {
    final relation = current.relations[segment];
    if (relation == null) {
      final declared = current.relations.keys;
      throw StateError(
        'The allow list permits include [$include], but '
        "${current.modelName} declares no relation '$segment', so this "
        'include can never load. Fix the allow list. Relations on '
        '${current.modelName}: ${declared.isEmpty ? '(none)' : declared.join(', ')}.',
      );
    }
    current = relation.related;
  }
}
