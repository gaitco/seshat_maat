import 'package:seshat/seshat.dart';
import 'package:maat/maat.dart';

/// Registers `unique` and `exists` on the validator. Call once at boot — the
/// [DatabaseServiceProvider] does it for you.
///
/// ```
/// unique:<table>,<column>[,<ignoreValue>[,<ignoreColumn>]]
/// exists:<table>,<column>
/// ```
///
/// Both rules query [DB]'s default connection at validation time, so they only
/// need one to exist by the time a request is validated, not at registration.
void registerDatabaseRules() {
  Validator.extendAsync('unique', (ctx) async {
    if (!ctx.present || ctx.value == null) return true;
    var query = DB.table(_table(ctx, 'unique')).where(_column(ctx), ctx.value);
    final ignore = ctx.params.length > 2 ? ctx.params[2] : '';
    // Laravel spells "no id to ignore" as the literal NULL, which is why
    // `unique:users,email,NULL,id` is its canonical four-argument form.
    if (ignore.isNotEmpty && ignore != 'NULL') {
      final ignoreColumn = ctx.params.length > 3 ? ctx.params[3] : 'id';
      query = query.where(ignoreColumn, '!=', ignore);
    }
    return query.doesntExist();
  }, message: 'The :attribute has already been taken.');

  Validator.extendAsync('exists', (ctx) async {
    if (!ctx.present || ctx.value == null) return true;
    return DB
        .table(_table(ctx, 'exists'))
        .where(_column(ctx), ctx.value)
        .exists();
  }, message: 'The selected :attribute is invalid.');
}

/// The table to query — the first parameter, which both rules require.
String _table(RuleContext ctx, String rule) {
  if (ctx.params.isEmpty) {
    throw ArgumentError(
      'Validation rule $rule requires at least 1 parameters.',
    );
  }
  return ctx.params[0];
}

/// The column to match on: the second parameter, or the attribute's own name.
String _column(RuleContext ctx) =>
    ctx.params.length > 1 ? ctx.params[1] : ctx.attribute;
