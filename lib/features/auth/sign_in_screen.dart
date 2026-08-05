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

  // "Meridian Health", not "Acme" — a named, specific company reads as a real
  // deployment; "Acme" reads as the placeholder it conventionally is.
  static const _hrPrincipal = Principal(
    id: 'demo-hr',
    email: 'priya.shah@meridianhealth.example',
    role: UserRole.recruiter,
    displayName: 'Priya Shah — Meridian Health',
    organisationId: 'org-meridian-health',
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = context.brand;
    return Scaffold(
      // A soft brand-tinted glow behind the header, fading into the ordinary
      // surface — this is the one screen nobody is "working in", so it can
      // afford to look designed rather than functional the way the workspace
      // screens (correctly) do.
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.9),
            radius: 1.3,
            colors: [brand.accentSoft.withValues(alpha: 0.6), Colors.transparent],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: Spacing.xl),
                  _BrandMark(colour: brand.accent),
                  const SizedBox(height: Spacing.lg),
                  Text('CogniHire',
                      style: theme.textTheme.displaySmall,
                      textAlign: TextAlign.center),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    'Verified-claim interviewing. Choose how you are signing in.',
                    textAlign: TextAlign.center,
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
                          // IntrinsicHeight so the two cards match height
                          // without being handed the scroll view's unbounded
                          // height.
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
      ),
    );
  }
}

/// The wordmark's icon: a tinted circle, not a bare glyph. Same visual math
/// as the initials avatar elsewhere in the app (`patterns.dart`) — a
/// low-alpha fill of [colour] with a slightly stronger border of the same
/// colour — so the brand mark and the rest of the app read as one language
/// rather than the login screen inventing its own.
class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.colour});

  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.16),
        shape: BoxShape.circle,
        border: Border.all(color: colour.withValues(alpha: 0.35)),
      ),
      child: Icon(Icons.verified_user_outlined, size: 26, color: colour),
    );
  }
}

/// A card header's icon, tinted the same way as [_BrandMark] — every icon on
/// this screen reads as "badge", not "glyph floating in whitespace".
class _CardIcon extends StatelessWidget {
  const _CardIcon({required this.icon, required this.colour});

  final IconData icon;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 24, color: colour),
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
              _CardIcon(
                icon: Icons.business_center_outlined,
                colour: theme.colorScheme.tertiary,
              ),
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
              SizedBox(
                width: double.infinity,
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
            _CardIcon(
              icon: Icons.person_outline,
              colour: theme.colorScheme.tertiary,
            ),
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
            SizedBox(
              width: double.infinity,
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
