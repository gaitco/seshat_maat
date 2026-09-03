import 'dart:math';

/// Minimal, seedable generators for factories. Deliberately NOT the `faker`
/// package: a dependency of `seshat_maat` ships into every production
/// application, and Dart has no dev-only split for a library's consumers.
///
/// Pass a seed for a reproducible sequence — the same seed replays the same
/// values, so a failing test can be re-run byte for byte:
///
/// ```dart
/// final faker = Faker(1234);
/// faker.name();        // 'Linus Dijkstra'
/// faker.uniqueEmail(); // 'user0.4138410852@example.test'
/// ```
class Faker {
  Faker([int? seed]) : _random = Random(seed);

  final Random _random;
  int _emailCounter = 0;

  static const _first = ['Ada', 'Grace', 'Alan', 'Edsger', 'Barbara', 'Linus'];
  static const _last = ['Lovelace', 'Hopper', 'Turing', 'Dijkstra', 'Liskov'];
  static const _words = ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta'];

  String name() =>
      '${_first[_random.nextInt(_first.length)]} '
      '${_last[_random.nextInt(_last.length)]}';

  /// Unique within this instance — factories creating many rows would
  /// otherwise collide on a unique email column. The counter, not the
  /// random suffix, is what guarantees it.
  String uniqueEmail() =>
      'user${_emailCounter++}.${_random.nextInt(1 << 32)}@example.test';

  String sentence({int words = 6}) =>
      '${[for (var i = 0; i < words; i++) _words[_random.nextInt(_words.length)]].join(' ')}.';

  /// A number in `[min, max]` — both bounds inclusive.
  int number({int min = 0, int max = 1000}) {
    if (min > max) {
      throw ArgumentError(
        'Faker.number: min ($min) must not exceed max ($max)',
      );
    }
    return min + _random.nextInt(max - min + 1);
  }

  bool boolean() => _random.nextBool();

  DateTime dateTime() =>
      DateTime.utc(2020).add(Duration(minutes: _random.nextInt(2000000)));

  /// A random (version 4 shaped) UUID. Seeded, so not cryptographically
  /// random — it is test data, not a security token.
  ///
  /// Unlike [uniqueEmail] there is NO counter: uniqueness is probabilistic
  /// and only within one instance's sequence. Two Fakers built from the same
  /// seed return the *same* first uuid, so do not seed two fakers alike and
  /// write their uuids into one unique column.
  String uuid() {
    String h(int n) => [
      for (var i = 0; i < n; i++) _random.nextInt(16).toRadixString(16),
    ].join();
    return '${h(8)}-${h(4)}-4${h(3)}-a${h(3)}-${h(12)}';
  }
}
