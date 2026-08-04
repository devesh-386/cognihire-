/// Persistence for locally-authored role definitions.
///
/// Abstract for the same reason [AuditStore] is: the core must stay free of
/// `dart:io` so it can be tested in plain Dart and compiled for web.
library;

import 'role.dart';

/// The result of listing roles: what was readable, and what was not.
///
/// Unreadable records are surfaced rather than skipped, matching the audit
/// store's rule. A role that silently vanishes leaves an author believing the
/// coverage report they are reading covers everything they defined.
class RoleIndex {
  const RoleIndex({required this.roles, required this.problem});

  final List<Role> roles;

  /// Non-null when the stored file existed but could not be read in full.
  final String? problem;

  bool get isHealthy => problem == null;
}

abstract class RoleStore {
  Future<RoleIndex> listRoles();

  /// Creates or replaces a role, keyed on [Role.id].
  Future<void> saveRole(Role role);

  Future<void> deleteRole(String id);
}

class InMemoryRoleStore implements RoleStore {
  final Map<String, Role> _roles = {};

  @override
  Future<RoleIndex> listRoles() async {
    final roles = _roles.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return RoleIndex(roles: roles, problem: null);
  }

  @override
  Future<void> saveRole(Role role) async {
    _roles[role.id] = role;
  }

  @override
  Future<void> deleteRole(String id) async {
    _roles.remove(id);
  }
}
