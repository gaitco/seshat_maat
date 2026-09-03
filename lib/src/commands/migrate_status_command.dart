import 'package:seshat/seshat.dart';
import 'package:maat/maat.dart';

class MigrateStatusCommand extends Command {
  MigrateStatusCommand(this.migrations);

  final List<Migration> migrations;

  @override
  String get name => 'migrate:status';

  @override
  String get description => 'Show the status of each migration';

  @override
  Future<int> handle() async {
    final migrator = Migrator(DB.connection, migrations);
    final statuses = await migrator.status();
    table(
      ['Ran', 'Migration', 'Batch'],
      [
        for (final s in statuses)
          [s.isPending ? 'No' : 'Yes', s.name, '${s.batch ?? ''}'],
      ],
    );
    return 0;
  }
}
