import 'dart:io';

import 'package:maat/maat.dart';
import 'package:maat/testing.dart';
import 'package:maat_seshat/maat_seshat.dart';
import 'package:test/test.dart';

void main() {
  late TestClient client;

  Future<Application> boot({List<Object> global = const []}) async {
    final dir = Directory.systemTemp.createTempSync('binding');
    addTearDown(() => dir.deleteSync(recursive: true));
    return Application.configure(basePath: dir.path, environment: {})
        .withConfig({
          'app': {'debug': true},
        })
        .withMiddleware((m) => m.use(global))
        .create();
  }

  setUp(() async {
    Log.sink = StringBuffer();
    ModelBinding.reset();
    DB.use(SqliteConnection.open(':memory:'));
    await DB.statement(
      'create table widgets (id integer primary key autoincrement, name text)',
    );
    client = TestClient(await boot());
  });

  tearDown(() async {
    await DB.connection.close();
    DB.reset();
    Application.reset();
    ModelBinding.reset();
    Log.sink = stdout;
  });

  test(
    'a bound parameter resolves the model before the handler runs',
    () async {
      await DB.table('widgets').insert({'name': 'first'});
      Route.get(
        '/api/widgets/{widget}',
        (Request req) => {'name': req.bound<Widget>('widget').name},
      ).middleware([ModelBinding.middleware()]);

      // Negative first: the registry is global, so without this a leaked
      // binding from another test would make the assertion below pass for
      // the wrong reason.
      final before = await client.get('/api/widgets/1');
      expect(
        before.statusCode,
        500,
        reason: 'nothing may resolve before bind() is called',
      );

      ModelBinding.bind('widget', Widget.def);

      final res = await client.get('/api/widgets/1');
      expect(res.statusCode, 200);
      expect(res.json['name'], 'first');
    },
  );

  test('a missing row is a 404 and the handler never runs', () async {
    ModelBinding.bind('widget', Widget.def);
    var ran = false;
    Route.get('/api/widgets/{widget}', (Request req) {
      ran = true;
      return {'ok': true};
    }).middleware([ModelBinding.middleware()]);

    final res = await client.get('/api/widgets/999');

    expect(res.statusCode, 404);
    expect(
      ran,
      isFalse,
      reason: 'the handler must not run for a missing model',
    );
    expect(res.json['message'], contains('Widget'));
  });

  test(
    'an unparseable id for an incrementing key is a 404, not a 500',
    () async {
      ModelBinding.bind('widget', Widget.def);
      var ran = false;
      Route.get('/api/widgets/{widget}', (Request req) {
        ran = true;
        return {'ok': true};
      }).middleware([ModelBinding.middleware()]);

      final res = await client.get('/api/widgets/not-a-number');

      expect(res.statusCode, 404);
      expect(ran, isFalse);
    },
  );

  test('bound() throws a named error for an unregistered parameter', () async {
    await DB.table('widgets').insert({'name': 'first'});
    Route.get(
      '/api/widgets/{widget}',
      (Request req) => {'name': req.bound<Widget>('widget').name},
    ).middleware([ModelBinding.middleware()]);

    final res = await client.get('/api/widgets/1');

    expect(res.statusCode, 500);
    expect(res.json['exception'], 'StateError');
    expect(
      res.json['message'],
      allOf(contains('widget'), contains('bound')),
      reason: 'the error must name the parameter that was not bound',
    );
  });

  test('bound() reports which parameters WERE bound', () async {
    await DB.table('widgets').insert({'name': 'first'});
    ModelBinding.bind('widget', Widget.def);
    Route.get(
      '/api/widgets/{widget}',
      // A typo in the name the handler asks for: the diagnostic has to make
      // "you asked for the wrong name" distinguishable from "nothing ran".
      (Request req) => {'name': req.bound<Widget>('widgets').name},
    ).middleware([ModelBinding.middleware()]);

    final res = await client.get('/api/widgets/1');

    expect(res.statusCode, 500);
    expect(res.json['message'], contains('Bound on this request: widget'));
  });

  test('a custom key binds by that column', () async {
    ModelBinding.bind('widget', Widget.def, key: 'name');
    await DB.table('widgets').insert({'name': 'slugged'});
    Route.get(
      '/api/widgets/{widget}',
      (Request req) => {'id': req.bound<Widget>('widget').id},
    ).middleware([ModelBinding.middleware()]);

    final res = await client.get('/api/widgets/slugged');

    expect(res.statusCode, 200);
    expect(res.json['id'], 1);
  });

  test('a route parameter with no binding stays a plain string', () async {
    Route.get(
      '/api/widgets/{widget}',
      (Request req, String widget) => {'raw': widget},
    ).middleware([ModelBinding.middleware()]);

    final res = await client.get('/api/widgets/anything');

    expect(res.statusCode, 200);
    expect(res.json['raw'], 'anything');
  });

  test('a later middleware may write the bare parameter name', () async {
    // The reason resolved models live under `binding:<name>` and not under
    // <name>: Phase 4's authentication middleware writes the authenticated
    // user to attributes, and `{user}` is the likeliest binding name in any
    // real application. Unprefixed, the second write wins and bound<Widget>
    // casts a String, giving a 500 in place of the model.
    await DB.table('widgets').insert({'name': 'first'});
    ModelBinding.bind('widget', Widget.def);
    Route.get(
      '/api/widgets/{widget}',
      (Request req) => {'name': req.bound<Widget>('widget').name},
    ).middleware([
      ModelBinding.middleware(),
      (Request request, Next next) {
        request.attributes['widget'] = 'a value from another middleware';
        return next(request);
      },
    ]);

    final res = await client.get('/api/widgets/1');

    expect(res.statusCode, 200, reason: 'body: ${res.body}');
    expect(res.json['name'], 'first');
  });

  test('reset() drops the registry', () async {
    await DB.table('widgets').insert({'name': 'first'});
    ModelBinding.bind('widget', Widget.def);
    Route.get(
      '/api/widgets/{widget}',
      (Request req) => {'name': req.bound<Widget>('widget').name},
    ).middleware([ModelBinding.middleware()]);

    expect((await client.get('/api/widgets/1')).statusCode, 200);
    ModelBinding.reset();
    expect((await client.get('/api/widgets/1')).statusCode, 500);
  });

  test('binding the same name twice replaces the first binding', () async {
    await DB.table('widgets').insert({'name': 'slugged'});
    ModelBinding.bind('widget', Widget.def);
    ModelBinding.bind('widget', Widget.def, key: 'name');
    Route.get(
      '/api/widgets/{widget}',
      (Request req) => {'id': req.bound<Widget>('widget').id},
    ).middleware([ModelBinding.middleware()]);

    expect((await client.get('/api/widgets/slugged')).statusCode, 200);
  });

  test(
    'DatabaseServiceProvider registers the middleware as the "bindings" alias',
    () async {
      DB.reset();
      final dir = Directory.systemTemp.createTempSync('bindalias');
      addTearDown(() => dir.deleteSync(recursive: true));
      final app =
          await Application.configure(basePath: dir.path, environment: {})
              .withConfig({
                'app': {'debug': true},
                'database': {
                  'default': 'sqlite',
                  'connections': {
                    'sqlite': {'driver': 'sqlite', 'database': ':memory:'},
                  },
                },
              })
              .withProviders([DatabaseServiceProvider.new])
              .create();
      await DB.statement(
        'create table widgets (id integer primary key autoincrement, name text)',
      );
      await DB.table('widgets').insert({'name': 'aliased'});
      ModelBinding.bind('widget', Widget.def);
      Route.get(
        '/api/widgets/{widget}',
        (Request req) => {'name': req.bound<Widget>('widget').name},
      ).middleware(['bindings']);

      final res = await TestClient(app).get('/api/widgets/1');

      expect(res.statusCode, 200);
      expect(res.json['name'], 'aliased');
    },
  );

  test('the middleware is inert as global middleware, and says so', () async {
    // Global middleware runs BEFORE the router matches, so request.params is
    // still empty there. Silently resolving nothing is the one failure mode
    // this feature must not have.
    ModelBinding.bind('widget', Widget.def);
    await DB.table('widgets').insert({'name': 'first'});
    client = TestClient(await boot(global: [ModelBinding.middleware()]));
    Route.get(
      '/api/widgets/{widget}',
      (Request req) => {'name': req.bound<Widget>('widget').name},
    );

    final res = await client.get('/api/widgets/1');

    expect(res.statusCode, 500);
    // Not the message: every bound() failure names the route-middleware fix,
    // so that string discriminates nothing. The 500 is what pins the
    // ordering — restructure the kernel to match routes first and this test
    // goes green at 200.
    expect(res.json['exception'], 'StateError');
  });
}

class Widget extends Model<Widget> {
  Widget({this.id, required this.name});

  static final ModelDefinition<Widget> def = ModelDefinition<Widget>(
    table: 'widgets',
    fromMap: Widget.fromMap,
    timestamps: false,
  );

  @override
  ModelDefinition<Widget> get definition => def;

  final int? id;
  final String name;

  static Widget fromMap(Map<String, Object?> map) =>
      Widget(id: map['id'] as int?, name: map['name'] as String);

  @override
  Map<String, Object?> toMap() => {'id': id, 'name': name};
}
