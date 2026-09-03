import 'package:seshat/seshat.dart';

import 'faker.dart';

/// Laravel's model factories. Keyed to the model's [ModelDefinition] because
/// Dart cannot find a factory by naming convention without reflection.
///
/// ```dart
/// class UserFactory extends Factory<User> {
///   UserFactory({super.faker, super.count, super.states}) : super(User.def);
///
///   @override
///   Map<String, Object?> definition(Faker faker) => {
///         'name': faker.name(),
///         'email': faker.uniqueEmail(),
///         'active': true,
///       };
///
///   @override
///   UserFactory state(Map<String, Object?> attributes) => UserFactory(
///         faker: faker,
///         count: countOf,
///         states: [...states, attributes],
///       );
///
///   @override
///   UserFactory count(int n) =>
///       UserFactory(faker: faker, count: n, states: states);
///
///   UserFactory inactive() => state({'active': false});
/// }
///
/// final users = await UserFactory().count(3).inactive().create();
/// ```
abstract class Factory<T extends Model<T>> {
  Factory(
    this.definitionOf, {
    Faker? faker,
    this._count = 1,
    List<Map<String, Object?>> states = const [],
  }) : faker = faker ?? Faker(),
       _states = List.unmodifiable([
         for (final state in states) Map<String, Object?>.unmodifiable(state),
       ]);

  final ModelDefinition<T> definitionOf;

  /// Shared by every model this factory builds, so a seeded factory
  /// produces one reproducible sequence across all of them.
  final Faker faker;

  final int _count;
  final List<Map<String, Object?>> _states;

  /// How many models [make] and [create] build.
  int get countOf => _count;

  /// The states applied over [definition], in application order. Both the
  /// list and every map in it are unmodifiable, and each map was copied at
  /// construction — a caller cannot reach back through the map it passed to
  /// [state] and change what this factory builds.
  List<Map<String, Object?>> get states => _states;

  /// Default attributes for one model.
  Map<String, Object?> definition(Faker faker);

  /// Returns a NEW factory with [attributes] appended — never mutates in
  /// place, so a shared base factory cannot be poisoned by a caller
  /// applying a state. Implement it by constructing your subclass with
  /// `states: [...states, attributes]`.
  Factory<T> state(Map<String, Object?> attributes);

  /// Returns a NEW factory that builds [n] models. Immutable for the same
  /// reason as [state].
  Factory<T> count(int n);

  /// Definition first, then each state in order: a later state wins.
  Map<String, Object?> attributes() => {
    ...definition(faker),
    for (final state in _states) ...state,
  };

  /// Queues [child] to be created for every model this factory persists,
  /// with [relation]'s foreign key pointing at the parent row. Laravel
  /// infers the relation from the child's class. Maat could infer it
  /// too — `ModelDefinition.relations` names every relation and each one
  /// carries the definition it points at — but two relations can target
  /// the same model (`author` and `editor`, both to `User`), so inference
  /// is ambiguous exactly where it matters. The relation is named
  /// explicitly and checked here — a typo throws now rather than writing
  /// parentless rows later.
  ///
  /// ```dart
  /// await UserFactory().has(PostFactory().count(3), 'posts').createOne();
  /// ```
  ///
  /// Returns a `Factory<T>`, not your subclass, so apply named states
  /// before [has]: `UserFactory().inactive().has(...)`.
  Factory<T> has<C extends Model<C>>(Factory<C> child, String relation) {
    final r = _relationNamed<HasOneOrMany<C>>(
      relation,
      'hasOne/hasMany',
      child.definitionOf.modelName,
    );
    return _WithChildren<T>(this, [
      ..._pending,
      _PendingChildren(child, r.foreignKey, r.localKey),
    ]);
  }

  /// Sets [relation]'s foreign key to [parent]'s key, so what this factory
  /// creates belongs to a parent that already exists. Laravel spells this
  /// `->for()`; `for` is a Dart keyword, so the relation kind names it.
  ///
  /// ```dart
  /// await PostFactory().belongsTo(user, 'user').createOne();
  /// ```
  Factory<T> belongsTo<P extends Model<P>>(P parent, String relation) {
    final r = _relationNamed<BelongsTo<P>>(
      relation,
      'belongsTo',
      parent.definition.modelName,
    );
    final key = parent.toMap()[r.ownerKey];
    if (key == null) {
      throw ArgumentError.value(
        parent.definition.modelName,
        'parent',
        "has no ${r.ownerKey} yet, so '${r.foreignKey}' would be written "
            'null; save the parent before attaching to it',
      );
    }
    return state({r.foreignKey: key});
  }

  /// The relation called [name] pointing at [related], or an
  /// [ArgumentError] listing the relations that do exist. Because the
  /// stored relation is reified (`HasMany<Post>`), the type test catches a
  /// factory or parent for the wrong model as well as an unknown name.
  R _relationNamed<R extends Relation<Object?>>(
    String name,
    String kind,
    String related,
  ) {
    final relation = definitionOf.relations[name];
    if (relation is R) return relation;
    final declared = definitionOf.relations.keys;
    throw ArgumentError.value(
      name,
      'relation',
      'is not a $kind relation to $related on ${definitionOf.modelName}, '
          'which declares '
          '${declared.isEmpty ? 'no relations' : declared.join(', ')}',
    );
  }

  /// Children queued by [has]. Empty unless [has] wrapped this factory.
  List<_PendingChildren> get _pending => const [];

  /// Builds one model in memory. Nothing is written — only [create] and
  /// [createOne] touch the database.
  T makeOne() => definitionOf.instantiate(attributes());

  List<T> make() => [for (var i = 0; i < _count; i++) makeOne()];

  Future<T> createOne() async => (await _persist([makeOne()])).single;

  Future<List<T>> create() async => _persist(make());

  /// `save()` returns the *persisted* instance (with its generated key), so
  /// the saved models are collected rather than the in-memory originals.
  Future<List<T>> _persist(List<T> models) async {
    final saved = <T>[];
    for (final model in models) {
      final parent = await model.save();
      saved.add(parent);
      // Children come after the insert, never before: their foreign key is
      // the parent's generated key, which does not exist until then.
      for (final children in _pending) {
        await children.createFor(parent);
      }
    }
    return saved;
  }
}

/// A child factory queued by [Factory.has] with the keys that link it to
/// its parent.
class _PendingChildren {
  const _PendingChildren(this.factory, this.foreignKey, this.localKey);

  final Factory factory;
  final String foreignKey;
  final String localKey;

  Future<void> createFor(Model parent) {
    final key = parent.toMap()[localKey];
    if (key == null) {
      throw StateError(
        "${parent.definition.modelName} has no $localKey, so '$foreignKey' "
        'would be written null on every child',
      );
    }
    return factory.state({foreignKey: key}).create();
  }
}

/// What [Factory.has] returns: [_inner] plus the children to write once the
/// parent row exists. It wraps rather than copies because only the user's
/// subclass can build another of itself, and its `state()` / `count()` know
/// nothing about pending children — wrapping carries them through both.
class _WithChildren<T extends Model<T>> extends Factory<T> {
  _WithChildren(this._inner, List<_PendingChildren> children)
    : _children = List.unmodifiable(children),
      super(_inner.definitionOf, faker: _inner.faker, count: _inner.countOf);

  final Factory<T> _inner;
  final List<_PendingChildren> _children;

  @override
  List<_PendingChildren> get _pending => _children;

  @override
  List<Map<String, Object?>> get states => _inner.states;

  @override
  Map<String, Object?> definition(Faker faker) => _inner.definition(faker);

  @override
  Map<String, Object?> attributes() => _inner.attributes();

  @override
  T makeOne() => _inner.makeOne();

  @override
  Factory<T> state(Map<String, Object?> attributes) =>
      _WithChildren<T>(_inner.state(attributes), _children);

  @override
  Factory<T> count(int n) => _WithChildren<T>(_inner.count(n), _children);
}
