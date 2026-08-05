import 'package:flutter/material.dart';

import '../../core/auth/principal.dart';
import '../../core/auth/user_role.dart';
import '../../core/design/app_theme.dart';
import '../../core/invitations/invitation.dart';
import '../../core/invitations/invitation_store.dart';

/// The app's front door: choose which experience you are signing into.
///
/// ## Why a chooser, not a password form (yet)
///
/// The product has always described two experiences — [UserRole]'s own
/// documentation calls this "the sign-in chooser". Real credential verification
/// is a later slice (the `AuthStore`/`SupabaseAuthStore` already exist for it);
/// this screen's job is the structural one the app was missing entirely: making
/// "I am HR" and "I am the candidate" two distinct entry points that mount two
/// distinct experiences. Until credentials are wired, choosing HR constructs a
/// [Principal] for a demo account of that role.
///
/// ## Why the candidate side needs a code
///
/// A candidate is not a walk-up account: they interview *because* HR invited
/// them to a specific role. Requiring the invitation code here — rather than a
/// bare "Continue as Candidate" button — is what makes that binding real rather
/// than a UI label. See `invitations_screen.dart` for where the code comes from.
///
/// The [Principal] this produces is the one and only thing downstream code
/// reads to decide what a person may see — see `Principal.can`.
class SignInScreen extends StatelessWidget {
  const SignInScreen({
    super.key,
    required this.invitationStore,
    required this.onSignIn,
  });

  final InvitationStore invitationStore;

  /// Called once someone has signed in. [invitation] is non-null only for a
  /// candidate who entered through a redeemed code — the caller uses it to
  /// bind the session that follows to that invitation's role.
  final void Function(Principal principal, Invitation? invitation) onSignIn;

  static const _hrPrincipal = Principal(
    id: 'demo-hr',
    email: 'hr@acme.example',
    role: UserRole.recruiter,
    displayName: 'Acme Talent',
    organisationId: 'org-acme',
  );

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
                      _RecruiterCard(
                        onTap: () => onSignIn(_hrPrincipal, null),
                      ),
                      _CandidateCodeCard(
                        invitationStore: invitationStore,
                        onRedeemed: (principal, invitation) =>
                            onSignIn(principal, invitation),
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

class _RecruiterCard extends StatelessWidget {
  const _RecruiterCard({required this.onTap});

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
              Icon(Icons.business_center_outlined,
                  size: 32, color: theme.colorScheme.primary),
              const SizedBox(height: Spacing.lg),
              Text('Continue as ${UserRole.recruiter.label}',
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: Spacing.sm),
              Text(
                UserRole.recruiter.description,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: Spacing.lg),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: onTap,
                  child: Text('Enter as ${UserRole.recruiter.label}'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The candidate's entry point: type the code HR gave you.
///
/// A [StatefulWidget] (unlike the recruiter card) because it owns a text
/// field and an in-progress error message that only this card cares about.
class _CandidateCodeCard extends StatefulWidget {
  const _CandidateCodeCard({
    required this.invitationStore,
    required this.onRedeemed,
  });

  final InvitationStore invitationStore;
  final void Function(Principal principal, Invitation invitation) onRedeemed;

  @override
  State<_CandidateCodeCard> createState() => _CandidateCodeCardState();
}

class _CandidateCodeCardState extends State<_CandidateCodeCard> {
  final _code = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the code you were given.');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });

    final invitation = await widget.invitationStore.findRedeemable(code);
    if (!mounted) return;

    if (invitation == null) {
      setState(() {
        _checking = false;
        _error = 'That code is not recognised, or has already been used.';
      });
      return;
    }

    await widget.invitationStore
        .saveInvitation(invitation.copyWith(status: InvitationStatus.accepted));
    if (!mounted) return;

    widget.onRedeemed(
      Principal(
        id: 'candidate-${invitation.id}',
        email: invitation.candidateEmail.isEmpty
            ? '${invitation.id}@invited.example'
            : invitation.candidateEmail,
        role: UserRole.candidate,
        displayName: invitation.candidateName,
      ),
      invitation,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.surface),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.person_outline, size: 32, color: theme.colorScheme.primary),
            const SizedBox(height: Spacing.lg),
            Text('Continue as ${UserRole.candidate.label}',
                style: theme.textTheme.titleLarge),
            const SizedBox(height: Spacing.sm),
            Text(
              'Enter the invitation code your interviewer gave you.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Spacing.lg),
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Invitation code'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: Spacing.sm),
              Text(_error!,
                  style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: Spacing.lg),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _checking ? null : _submit,
                child: _checking
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Enter interview'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
