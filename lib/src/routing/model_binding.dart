import 'package:seshat/seshat.dart';
import 'package:maat/maat.dart';

/// One registered binding: which model a route parameter resolves to, and the
/// column its value is matched against.
class _Binding {
  const _Binding(this.def, this.key);
  final ModelDefinition<Object?> def;
  final String key;
}

/// Laravel's route-model binding: `/widgets/{widget}` arrives at the handler
/// as a loaded model, and a missing row is a 404 raised before the handler
/// runs.
///
/// Laravel resolves the type hint on `fn(Widget $widget)` at runtime. That
/// cannot port — the router detects handler arity with `is` checks against
/// `Function(Request, String, ...)`, and there is no way to test
/// `handler is Function(Request, Widget)` without knowing `Widget` at the
/// router level, which is the reflection this framework does not use. So the
/// binding resolves in middleware (Laravel's `SubstituteBindings`) and the
/// handler reads the value:
///
/// ```dart
/// ModelBinding.bind('widget', Widget.def);            // once, in a provider
///
/// Route.get('/widgets/{widget}', (Request req) {
///   return WidgetResource(req.bound<Widget>('widget'));
/// }).middleware(['bindings']);
/// ```
///
/// The registry is process-wide, exactly like Laravel's, which keeps bindings
/// on the router singleton. Tests that register a binding must call [reset] in
/// `tearDown` or the binding leaks into the next test.
abstract final class ModelBinding {
  static final Map<String, _Binding> _bindings = {};
  static final Middleware _middleware = _SubstituteBindings();

  /// Bind route parameter [name] to [def], matched on [key] (the model's
  /// primary key by default). Pass `key: 'slug'` to bind by a slug column.
  /// Re-binding a name replaces the previous binding.
  ///
  /// **Which keys are protected from a malformed URL segment.** Route values
  /// are always strings, so `/posts/abc` sends `'abc'` to the driver. SQLite
  /// finds no row and 404s. Postgres infers the parameter from its context
  /// and raises `22P02 invalid input syntax for type integer` — a 500.
  /// Exactly one case is guarded here: [key] is [def]'s primary key *and*
  /// `def.incrementing` is true, which is the only integer column a
  /// [ModelDefinition] declares. Every other key — `key: 'author_id'` or any
  /// other integer column — is **not** guarded and will 500 on Postgres for a
  /// non-numeric segment. Constrain the route instead, which costs nothing
  /// and works for any column type:
  ///
  /// ```dart
  /// Route.get('/posts/{post}', show).where('post', r'\d+');
  /// ```
  // ponytail: a ModelDefinition knows no column types beyond `incrementing`,
  // so a general guard needs schema introspection the schema builder does not
  // expose yet. Widen this when it does; do not guess from the column name.
  static void bind(String name, ModelDefinition<Object?> def, {String? key}) =>
      _bindings[name] = _Binding(def, key ?? def.primaryKey);

  /// Drops every binding. Registered by an application once at boot; reset
  /// only by tests.
  static void reset() => _bindings.clear();

  /// The middleware that substitutes bindings. Add it to a route or a group —
  /// **not** to the global stack, which runs before the router matches, so
  /// `request.params` is still empty there and nothing would resolve.
  /// [DatabaseServiceProvider] registers it under the alias `'bindings'`.
  static Middleware middleware() => _middleware;
}

class _SubstituteBindings extends Middleware {
  @override
  Future<Response> handle(Request request, Next next) async {
    for (final entry in request.params.entries) {
      final binding = ModelBinding._bindings[entry.key];
      if (binding == null) continue;
      final model = await _resolve(binding, entry.value);
      if (model == null) {
        throw NotFoundHttpException(
          'No query results for model [${binding.def.modelName}] ${entry.value}.',
        );
      }
      request.attributes[Request.boundAttribute(entry.key)] = model;
    }
    return await next(request);
  }

  Future<Object?> _resolve(_Binding binding, String raw) {
    // `/widgets/abc` cannot match an auto-incrementing key. Bail out before
    // the driver sees it: route values are always strings, and Postgres —
    // which infers an untyped parameter from its context — raises "invalid
    // input syntax for type integer", a 500 where Laravel gives a 404.
    // SQLite finds no row instead, so this guard is invisible to the
    // suite's driver; the 404 it produces is asserted, the 500 it prevents
    // cannot be.
    if (binding.key == binding.def.primaryKey &&
        binding.def.incrementing &&
        int.tryParse(raw) == null) {
      return Future.value();
    }
    return binding.def.query().where(binding.key, raw).first();
  }
}
