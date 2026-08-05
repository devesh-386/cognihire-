import 'package:flutter/material.dart';

import '../../core/auth/principal.dart';
import '../../core/auth/user_role.dart';
import '../../core/design/app_theme.dart';

/// The app's front door: choose which experience you are signing into.
///
/// ## Why a chooser, not a password form (yet)
///
/// The product has always described two experiences — [UserRole]'s own
/// documentation calls this "the sign-in chooser". Real credential verification
/// is a later slice (the `AuthStore`/`SupabaseAuthStore` already exist for it);
/// this screen's job is the structural one the app was missing entirely: making
/// "I am HR" and "I am the candidate" two distinct entry points that mount two
/// distinct experiences. Until credentials are wired, choosing a role
/// constructs a [Principal] for a demo account of that role.
///
/// The [Principal] this produces is the one and only thing downstream code
/// reads to decide what a person may see — see `Principal.can`.
class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key, required this.onSignIn});

  /// Called with a constructed principal once a role is chosen. The app swaps
  /// this screen for that role's shell.
  final void Function(Principal principal) onSignIn;

  /// Builds the demo principal for a chosen role. Recruiters belong to an
  /// organisation; candidates deliberately do not (see `Principal.organisationId`).
  Principal _principalFor(UserRole role) => switch (role) {
        UserRole.recruiter => const Principal(
            id: 'demo-hr',
            email: 'hr@acme.example',
            role: UserRole.recruiter,
            displayName: 'Acme Talent',
            organisationId: 'org-acme',
          ),
        UserRole.candidate => const Principal(
            id: 'demo-candidate',
            email: 'candidate@example.com',
            role: UserRole.candidate,
            displayName: 'Jordan Rivera',
          ),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CogniHire', style: theme.textTheme.headlineMedium),
                const SizedBox(height: Spacing.sm),
                Text(
                  'Verified-claim interviewing. Choose how you are signing in.',
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: Spacing.section),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth > 560;
                    final cards = [
                      _RoleCard(
                        role: UserRole.recruiter,
                        icon: Icons.business_center_outlined,
                        onTap: () => onSignIn(_principalFor(UserRole.recruiter)),
                      ),
                      _RoleCard(
                        role: UserRole.candidate,
                        icon: Icons.person_outline,
                        onTap: () => onSignIn(_principalFor(UserRole.candidate)),
                      ),
                    ];
                    return wide
                        // IntrinsicHeight so the two cards match height without
                        // being handed the scroll view's unbounded height.
                        ? IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: cards[0]),
                                const SizedBox(width: Spacing.lg),
                                Expanded(child: cards[1]),
                              ],
                            ),
                          )
                        : Column(
                            children: [
                              cards[0],
                              const SizedBox(height: Spacing.lg),
                              cards[1],
                            ],
                          );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.role,
    required this.icon,
    required this.onTap,
  });

  final UserRole role;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.surface),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 32, color: theme.colorScheme.primary),
              const SizedBox(height: Spacing.lg),
              Text('Continue as ${role.label}',
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: Spacing.sm),
              Text(
                role.description,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: Spacing.lg),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: onTap,
                  child: Text('Enter as ${role.label}'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
