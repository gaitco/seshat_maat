import 'dart:io';

import 'package:maat/maat.dart';
import 'package:path/path.dart' as p;

String testConsumerPubspec(String seshatPath) {
  final packagesPath = p.dirname(seshatPath);
  return '''
name: genapp
environment:
  sdk: ^3.12.0
dependencies:
  maat: ^0.1.0
  maat_seshat: ^0.1.0
dev_dependencies:
  lints: ^6.1.0
dependency_overrides:
  maat:
    path: ${p.join(packagesPath, 'maat')}
  maat_seshat:
    path: $seshatPath
  maat_seshat_core:
    path: ${p.join(packagesPath, 'maat_seshat_core')}
''';
}

/// A minimal application for command tests: no database provider, because the
/// tests install their own connection with DB.use.
Future<Application> buildTestApplication({
  String environment = 'testing',
  String? basePath,
}) {
  final dir = basePath ?? Directory.systemTemp.createTempSync('dbcmd').path;
  File('$dir/.env').writeAsStringSync('APP_ENV=$environment\n');

  return Application.configure(basePath: dir, environment: {}).withConfig({
    'app': {'name': 'Test', 'debug': true},
  }).create();
}
