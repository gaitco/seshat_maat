import 'package:seshat/seshat.dart';
import 'package:maat/maat.dart';

import '../seeder.dart';
import 'migrate_command.dart' show blockedInProduction;

class MigrateFreshCommand extends Command {
  MigrateFreshCommand(this.migrations, {this.seeders = const []});

  final List<Migration> migrations;
  final List<Seeder> seeders;

  @override
  String get name => 'migrate:fresh';

  @override
  String get description => 'Drop every table and re-run every migration';

  @override
  String get signature => '{--force} {--seed}';

  @override
  Future<int> handle() async {
    if (blockedInProduction(this)) {
      return 1;
    }

    await Schema.on(DB.connection).dropAllTables();
    final migrator = Migrator(DB.connection, migrations);
    final ran = await migrator.run();
    for (final name in ran) {
      info('Migrated: $name');
    }

    if (flag('seed')) {
      for (final seeder in seeders) {
        await seeder.run();
      }
    }
    return 0;
  }
}
