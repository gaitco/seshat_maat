/// One database seeder. Subclass it and implement [run] to insert fixture
/// or reference data. `migrate:fresh --seed` runs the seeders registered
/// with `databaseCommands(seeders: ...)`.
abstract class Seeder {
  Future<void> run();
}
