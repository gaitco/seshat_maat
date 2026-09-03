import 'package:maat_seshat/maat_seshat.dart';
import 'package:test/test.dart';

void main() {
  test('the same seed produces the same sequence', () {
    // A *sequence*, not one draw: two fresh Fakers agreeing on their first
    // value would still agree if the generator advanced differently
    // afterwards, and replaying a failing test needs every draw to match.
    List<Object> sequence(int seed) {
      final f = Faker(seed);
      return [
        for (var i = 0; i < 5; i++) ...[
          f.name(),
          f.number(),
          f.uuid(),
          f.uniqueEmail(),
          f.sentence(),
        ],
      ];
    }

    expect(sequence(1), sequence(1));
    expect(sequence(7), sequence(7));
  });

  test('the values printed in the Faker dartdoc are the real ones', () {
    // The class doc claims a byte-for-byte replay and then shows two values.
    // If the word lists or the email format change, that doc is a lie — this
    // turns the lie into a red build instead of a comment nobody re-runs.
    final f = Faker(1234);
    expect(f.name(), 'Linus Dijkstra');
    expect(f.uniqueEmail(), 'user0.4138410852@example.test');
  });

  test('different seeds diverge', () {
    expect(Faker(1).uuid(), isNot(Faker(2).uuid()));
  });

  test('uniqueEmail never repeats within one instance', () {
    final f = Faker(1);
    final seen = {for (var i = 0; i < 200; i++) f.uniqueEmail()};
    expect(seen.length, 200);
  });

  test('uniqueEmail is unique BY CONSTRUCTION, not by luck', () {
    // The set-of-200 test above passes even with the counter removed: 200
    // draws from a 2^32 space collide about twice in a million runs. Only
    // an assertion on the counter itself distinguishes "guaranteed unique"
    // from "usually unique", and a factory inserting rows into a unique
    // email column needs the guarantee.
    final f = Faker(1);
    final counters = [
      for (var i = 0; i < 5; i++)
        int.parse(
          RegExp(r'^user(\d+)\.').firstMatch(f.uniqueEmail())!.group(1)!,
        ),
    ];
    expect(counters, [0, 1, 2, 3, 4]);
  });

  test('number respects its bounds', () {
    final f = Faker(3);
    for (var i = 0; i < 100; i++) {
      final n = f.number(min: 5, max: 7);
      expect(n, inInclusiveRange(5, 7));
    }
  });

  test('number rejects an inverted range by naming both bounds', () {
    expect(
      () => Faker(1).number(min: 10, max: 2),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          allOf(contains('10'), contains('2')),
        ),
      ),
    );
  });

  test('number is inclusive of both bounds', () {
    final f = Faker(3);
    final seen = {for (var i = 0; i < 200; i++) f.number(min: 5, max: 7)};
    expect(seen, {5, 6, 7}, reason: 'max must be reachable, min must be hit');
  });

  test('a single seeded instance advances rather than repeating', () {
    final f = Faker(11);
    expect(f.uuid(), isNot(f.uuid()));
  });

  test('an unseeded Faker still produces values', () {
    // Random(null) is a valid seed-free constructor; guards against a
    // `Random(seed!)` style regression that would throw.
    final f = Faker();
    expect(f.name(), matches(RegExp(r'^\S+ \S+$')));
    expect(f.uniqueEmail(), contains('@'));
    expect(f.number(min: 5, max: 5), 5);
  });

  test('sentence honours its word count and terminates', () {
    final s = Faker(5).sentence(words: 3);
    expect(s, endsWith('.'));
    expect(s.substring(0, s.length - 1).split(' '), hasLength(3));
  });

  test('every uuid is version-4 shaped, not just a lucky one', () {
    // One sample from one seed is not a shape test: Faker(2) happens to draw
    // 'a' for the variant nibble, so a mutant that randomised it survived.
    // Sweep enough draws from enough seeds that a wrong version or variant
    // nibble cannot hide behind a lucky value.
    final shape = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-a[0-9a-f]{3}-[0-9a-f]{12}$',
    );
    for (final seed in [1, 2, 3, 99]) {
      final f = Faker(seed);
      for (var i = 0; i < 50; i++) {
        expect(f.uuid(), matches(shape), reason: 'seed $seed, draw $i');
      }
    }
  });

  test('dateTime is UTC and inside the generated window', () {
    final d = Faker(4).dateTime();
    expect(d.isUtc, isTrue);
    expect(d.isAfter(DateTime.utc(2019, 12, 31)), isTrue);
    expect(d.isBefore(DateTime.utc(2024)), isTrue);
  });

  test('boolean yields both values over a run', () {
    final f = Faker(9);
    expect({for (var i = 0; i < 50; i++) f.boolean()}, {true, false});
  });
}
