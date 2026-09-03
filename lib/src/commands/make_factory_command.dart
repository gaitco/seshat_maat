import 'model_generator_command.dart';

/// Creates a model factory under `database/factories`.
///
/// ```bash
/// maat make:factory PostFactory
/// maat make:factory AuthorFactory --model=User
/// ```
///
/// `make:model -f` generates the same shape with a faker value per declared
/// field; this command is for a model that already exists.
class MakeFactoryCommand extends ModelGeneratorCommand {
  String _package = '';

  @override
  String get name => 'make:factory';

  @override
  String get description => 'Create a new model factory';

  @override
  String get type => 'Factory';

  @override
  String get suffix => 'Factory';

  @override
  String get directory => 'database/factories';

  @override
  Future<int> handle() async {
    // A factory lives outside `lib/`, so it can only reach the model through
    // a `package:` import — which needs the application's own name. Resolve
    // it before anything is written: guessing writes a file that does not
    // compile, and a half-written scaffold is worse than none.
    final package = packageNameAt(app.path('pubspec.yaml'));
    if (package == null) {
      error(
        'Cannot read the package name from pubspec.yaml, which the generated '
        'factory needs to import the model. Run this from the application '
        'root.',
      );
      return 1;
    }
    _package = package;
    return super.handle();
  }

  /// `state` and `count` construct a NEW factory instead of mutating this
  /// one: a factory held in a variable and reused across tests otherwise
  /// leaks the first test's states into the second. `Factory` leaves both
  /// abstract, so this stub is where most users will meet the pattern — it
  /// has to be the correct one rather than the convenient one.
  @override
  String stub(String className) =>
      '''
import 'package:maat_seshat/maat_seshat.dart';
import 'package:$_package/${modelPath.substring('lib/'.length)}';

class $className extends Factory<$modelClass> {
  $className({super.faker, super.count, super.states}) : super($modelClass.def);

  @override
  Map<String, Object?> definition(Faker faker) => {
    // 'title': faker.sentence(),
  };

  /// Returns a NEW factory rather than mutating this one, so a factory held
  /// in a variable and reused across tests cannot leak its states forward.
  @override
  $className state(Map<String, Object?> attributes) => $className(faker: faker, count: countOf, states: [...states, attributes]);

  @override
  $className count(int n) => $className(faker: faker, count: n, states: states);
}
''';
}
