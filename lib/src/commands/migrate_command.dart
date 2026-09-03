import 'package:maat_seshat_core/maat_seshat_core.dart';
import 'package:maat/maat.dart';

/// Refuses to run a destructive migration command in production unless
/// forced. `migrate:fresh` drops every table; making that easy to do by
/// accident is how a framework eats someone's data.
bool blockedInProduction(Command command) {
  if (command.app.environment != 'production' || command.flag('force')) {
    return false;
  }
  command.error(
    'Refusing to run in production. Re-run with --force if you are certain.',
  );
  return true;
}

class MigrateCommand extends Command {
  MigrateCommand(this.migrations);

  final List<Migration> migrations;

  @override
  String get name => 'migrate';

  @override
  String get description => 'Run the pending database migrations';

  @override
  String get signature => '{--force}';

  @override
  Future<int> handle() async {
    if (blockedInProduction(this)) {
      return 1;
    }

    final migrator = Migrator(DB.connection, migrations);
    final ran = await migrator.run();
    if (ran.isEmpty) {
      info('Nothing to migrate.');
      return 0;
    }
    for (final name in ran) {
      info('Migrated: $name');
    }
    return 0;
  }
}
