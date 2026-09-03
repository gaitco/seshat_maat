import 'package:seshat/seshat.dart';
import 'package:maat/maat.dart';

import '../seeder.dart';
import 'db_seed_command.dart';
import 'make_factory_command.dart';
import 'make_migration_command.dart';
import 'make_model_command.dart';
import 'make_resource_command.dart';
import 'make_seeder_command.dart';
import 'migrate_command.dart';
import 'migrate_fresh_command.dart';
import 'migrate_rollback_command.dart';
import 'migrate_status_command.dart';

/// The `migrate*`, `make:migration`, `make:model`, `make:factory`,
/// `make:resource`, `make:seeder` and `db:seed` maat commands, wired to
/// [migrations] and [seeders]. Register the result in
/// `lib/app/console/kernel.dart`.
List<Command> databaseCommands({
  List<Migration> migrations = const [],
  List<Seeder> seeders = const [],
}) => [
  MigrateCommand(migrations),
  MigrateRollbackCommand(migrations),
  MigrateStatusCommand(migrations),
  MigrateFreshCommand(migrations, seeders: seeders),
  MakeMigrationCommand(),
  MakeModelCommand(),
  MakeFactoryCommand(),
  MakeResourceCommand(),
  MakeSeederCommand(),
  DbSeedCommand(seeders),
];
