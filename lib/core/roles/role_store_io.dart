import 'dart:convert';
import 'dart:io';

import 'role.dart';
import 'role_store.dart';

/// File-backed [RoleStore]: a single `roles.json` document.
///
/// One file rather than one per role, because roles are a short authored list
/// that is always read whole. The write is still atomic (temp file, then
/// rename), so a crash mid-save leaves the previous list intact instead of a
/// truncated one that would read back as fewer required skills than the author
/// entered.
class JsonFileRoleStore implements RoleStore {
  JsonFileRoleStore(this.directoryPath);

  final String directoryPath;

  static const _fileName = 'roles.json';

  File get _file =>
      File('$directoryPath${Platform.pathSeparator}$_fileName');

  @override
  Future<RoleIndex> listRoles() async {
    final file = _file;
    if (!await file.exists()) {
      return const RoleIndex(roles: [], problem: null);
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return RoleIndex(
          roles: const [],
          problem: '$_fileName is not a JSON object.',
        );
      }
      final list = decoded['roles'];
      if (list is! List) {
        return RoleIndex(
          roles: const [],
          problem: '$_fileName has no "roles" array.',
        );
      }

      final roles = <Role>[];
      final failures = <String>[];
      for (var i = 0; i < list.length; i++) {
        final entry = list[i];
        try {
          if (entry is! Map<String, Object?>) {
            throw FormatException('roles[$i] is not an object');
          }
          roles.add(Role.fromJson(entry, 'roles[$i]'));
        } on FormatException catch (error) {
          // One bad entry does not discard the good ones, but it is reported.
          failures.add(error.message);
        }
      }

      roles.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return RoleIndex(
        roles: roles,
        problem: failures.isEmpty
            ? null
            : '${failures.length} role(s) could not be read: '
                '${failures.join('; ')}',
      );
    } catch (error) {
      return RoleIndex(roles: const [], problem: '$error');
    }
  }

  @override
  Future<void> saveRole(Role role) async {
    final existing = (await listRoles()).roles;
    final next = [
      for (final r in existing)
        if (r.id != role.id) r,
      role,
    ];
    await _writeAll(next);
  }

  @override
  Future<void> deleteRole(String id) async {
    final existing = (await listRoles()).roles;
    await _writeAll([
      for (final r in existing)
        if (r.id != id) r,
    ]);
  }

  Future<void> _writeAll(List<Role> roles) async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final target = _file;
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema': 1,
        'roles': [for (final r in roles) r.toJson()],
      }),
      flush: true,
    );
    await temp.rename(target.path);
  }
}
