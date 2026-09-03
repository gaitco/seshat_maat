import 'package:path/path.dart' as p;

import 'model_generator_command.dart';

/// Creates an API resource under `lib/app/http/resources`.
///
/// ```bash
/// maat make:resource PostResource
/// maat make:resource AuthorResource --model=User
/// ```
///
/// There is no `--collection` flag. Laravel's resource collections are a
/// second class because PHP resolves `UserResource::collection()` through
/// inheritance; Dart does not inherit statics, so a collection is the
/// top-level `resourceCollection(users, UserResource.new, request)` and needs
/// no class of its own.
class MakeResourceCommand extends ModelGeneratorCommand {
  @override
  String get name => 'make:resource';

  @override
  String get description => 'Create a new API resource';

  @override
  String get type => 'Resource';

  @override
  String get suffix => 'Resource';

  @override
  String get directory => 'lib/app/http/resources';

  /// The key and the timestamps only. Every other column is a decision —
  /// which fields this endpoint exposes is the whole point of a resource —
  /// so the stub shows the shape and leaves the choosing to the developer.
  /// The dates are serialised here because `DateTime` is not JSON-encodable
  /// and would throw at the first request rather than at compile time.
  @override
  String stub(String className) {
    final import = p.url.relative(modelPath, from: p.url.dirname(relativePath));
    return '''
import 'package:maat/maat.dart';

import '$import';

class $className extends JsonResource<$modelClass> {
  $className(super.resource);

  @override
  Map<String, Object?> toJson(Request request) => {
    'id': resource.id,
    // 'title': resource.title,
    'created_at': resource.createdAt?.toIso8601String(),
    'updated_at': resource.updatedAt?.toIso8601String(),
  };
}
''';
  }
}
