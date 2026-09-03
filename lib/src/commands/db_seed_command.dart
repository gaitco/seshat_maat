import 'package:maat/maat.dart';

import '../seeder.dart';
import 'migrate_command.dart' show blockedInProduction;

/// Runs one registered [Seeder] by class name (`--class`, default
/// `DatabaseSeeder`) — Laravel's `db:seed --class`. `migrate:fresh --seed`
/// runs every registered seeder instead; this command targets one.
///
/// Guarded the same way `migrate`/`migrate:fresh` are: a seeder commonly
/// truncates before inserting, so it refuses to run in production without
/// `--force`.
class DbSeedCommand extends Command {
  DbSeedCommand(this.seeders);

  final List<Seeder> seeders;

  @override
  String get name => 'db:seed';

  @override
  String get description => 'Seed the database using a registered seeder';

  @override
  String get signature => '{--class=DatabaseSeeder} {--force}';

  @override
  Future<int> handle() async {
    if (blockedInProduction(this)) {
      return 1;
    }

    final className = option('class') ?? 'DatabaseSeeder';
    Seeder? seeder;
    for (final s in seeders) {
      if (s.runtimeType.toString() == className) {
        seeder = s;
        break;
      }
    }
    if (seeder == null) {
      final registered = seeders
          .map((s) => s.runtimeType.toString())
          .join(', ');
      error(
        registered.isEmpty
            ? 'Seeder [$className] is not registered. No seeders are '
                  'registered with databaseCommands(seeders: ...).'
            : 'Seeder [$className] is not registered. Registered seeders: $registered.',
      );
      return 1;
    }
    await seeder.run();
    info('Seeded: $className');
    return 0;
  }
}
