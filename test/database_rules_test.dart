import 'package:maat/maat.dart';
import 'package:maat_seshat/maat_seshat.dart';
import 'package:test/test.dart';

void main() {
  setUp(() async {
    DB.use(SqliteConnection.open(':memory:'));
    await DB.statement(
      'create table users (id integer primary key autoincrement, email text, slug text)',
    );
    await DB.statement(
      'create table invites (id integer primary key, email text)',
    );
    await DB.table('users').insert({'email': 'taken@x.y', 'slug': 'taken'});
    await DB.table('invites').insert({'id': 1, 'email': 'invited@x.y'});
    registerDatabaseRules();
  });

  tearDown(() async {
    await DB.connection.close();
    DB.reset();
  });

  test('unique fails for a value already in the table', () async {
    final v = Validator.make(
      {'email': 'taken@x.y'},
      {'email': 'unique:users,email'},
    );
    expect(await v.passesAsync(), isFalse);
    expect(v.errors['email']!.single, contains('already been taken'));
  });

  test('unique passes for a free value', () async {
    final v = Validator.make(
      {'email': 'free@x.y'},
      {'email': 'unique:users,email'},
    );
    expect(await v.passesAsync(), isTrue);
  });

  test('unique ignores the given id', () async {
    final v = Validator.make(
      {'email': 'taken@x.y'},
      {'email': 'unique:users,email,1'},
    );
    expect(await v.passesAsync(), isTrue);
  });

  test(
    'unique ignores by another column when given a fourth parameter',
    () async {
      final v = Validator.make(
        {'email': 'taken@x.y'},
        {'email': 'unique:users,email,taken,slug'},
      );
      expect(await v.passesAsync(), isTrue);
    },
  );

  test(
    'exists passes when the row is there and fails when it is not',
    () async {
      expect(
        await Validator.make(
          {'id': 1},
          {'id': 'exists:users,id'},
        ).passesAsync(),
        isTrue,
      );
      expect(
        await Validator.make(
          {'id': 99},
          {'id': 'exists:users,id'},
        ).passesAsync(),
        isFalse,
      );
    },
  );

  test('both rules are skipped for an absent value', () async {
    expect(
      await Validator.make({}, {'email': 'unique:users,email'}).passesAsync(),
      isTrue,
    );
  });

  test(
    'request.validate uses the async path with no signature change',
    () async {
      final request = Request.create(
        method: 'POST',
        path: '/',
        json: {'email': 'taken@x.y'},
      );

      await expectLater(
        () => request.validate({'email': 'required|unique:users,email'}),
        throwsA(isA<ValidationException>()),
      );
    },
  );

  test('two unique rules on one attribute keep separate verdicts', () async {
    // taken@x.y is in users and not in invites; invited@x.y is the reverse.
    for (final rules in [
      'unique:users,email|unique:invites,email',
      'unique:invites,email|unique:users,email',
    ]) {
      expect(
        await Validator.make(
          {'email': 'taken@x.y'},
          {'email': rules},
        ).passesAsync(),
        isFalse,
        reason: rules,
      );
      expect(
        await Validator.make(
          {'email': 'invited@x.y'},
          {'email': rules},
        ).passesAsync(),
        isFalse,
        reason: rules,
      );
      expect(
        await Validator.make(
          {'email': 'free@x.y'},
          {'email': rules},
        ).passesAsync(),
        isTrue,
        reason: rules,
      );
    }
  });

  test(
    'bail in front of a failing query keeps a 422, not a database error',
    () async {
      final v = Validator.make(
        {'email': 'not-an-email'},
        {'email': 'bail|email|unique:nope_missing_table,email'},
      );
      DB.connection.enableQueryLog();
      expect(await v.passesAsync(), isFalse);
      expect(v.errors['email']!.single, contains('valid email'));
    },
  );

  test('a query failure the loop actually reaches still surfaces', () async {
    await expectLater(
      Validator.make(
        {'email': 'x@y.z'},
        {'email': 'unique:nope_missing_table,email'},
      ).passesAsync(),
      throwsA(isA<QueryException>()),
    );
  });

  test(
    'NULL is the ignore placeholder, so no ignore clause is emitted',
    () async {
      DB.connection.enableQueryLog();
      final v = Validator.make(
        {'email': 'taken@x.y'},
        {'email': 'unique:users,email,NULL,id'},
      );
      expect(await v.passesAsync(), isFalse);
      expect(DB.connection.queryLog.single.sql, isNot(contains('"id"')));
    },
  );

  test('a rule with no parameters names itself', () async {
    await expectLater(
      Validator.make({'email': 'x@y.z'}, {'email': 'unique'}).passesAsync(),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'Validation rule unique requires at least 1 parameters.',
        ),
      ),
    );
  });

  test('the sync path refuses a real database rule', () {
    expect(
      () => Validator.make(
        {'email': 'x@y.z'},
        {'email': 'unique:users,email'},
      ).passes(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('unique'),
        ),
      ),
    );
  });
}
