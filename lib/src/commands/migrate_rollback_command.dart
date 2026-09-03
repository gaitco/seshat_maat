import 'package:seshat/seshat.dart';
import 'package:maat/maat.dart';

import 'migrate_command.dart' show blockedInProduction;

class MigrateRollbackCommand extends Command {
  MigrateRollbackCommand(this.migrations);

  final List<Migration> migrations;

  @override
  String get name => 'migrate:rollback';

  @override
  String get description => 'Roll back the last database migration batch(es)';

  @override
  String get signature => '{--force} {--step=1}';

  @override
  Future<int> handle() async {
    if (blockedInProduction(this)) {
      return 1;
    }

    final steps = int.tryParse(option('step') ?? '1') ?? 1;
    final migrator = Migrator(DB.connection, migrations);
    final rolledBack = await migrator.rollback(steps: steps);
    if (rolledBack.isEmpty) {
      info('Nothing to rollback.');
      return 0;
    }
    for (final name in rolledBack) {
      info('Rolled back: $name');
    }
    return 0;
  }
}
