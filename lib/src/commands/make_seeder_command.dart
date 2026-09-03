import 'package:maat/maat.dart';

/// Creates a new database seeder under `database/seeders`.
class MakeSeederCommand extends GeneratorCommand {
  @override
  String get name => 'make:seeder';

  @override
  String get description => 'Create a new database seeder';

  @override
  String get type => 'Seeder';

  @override
  String get directory => 'database/seeders';

  @override
  String stub(String className) =>
      '''
import 'package:maat_seshat/maat_seshat.dart';

class $className extends Seeder {
  @override
  Future<void> run() async {}
}
''';
}
