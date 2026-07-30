import 'package:flutter/material.dart';

import '../../core/design/app_theme.dart';
import '../../core/verification/identity_matcher.dart';
import '../../core/verification/verification_result.dart';
import '../../ui/tokens.dart';

/// Renders the current verification state.
///
/// Three visually distinct states, deliberately. "Not checked" must never look
/// like "verified" — the reference build this project learns from showed a
/// reassuring green status while its detector was entirely dead, because the
/// failure path wrote a success-looking string.
class VerificationStatusCard extends StatelessWidget {
  const VerificationStatusCard({
    super.key,
    required this.result,
    this.strikesAllowed = 3,
  });

  final VerificationResult? result;
  final int strikesAllowed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = _visuals(context, result);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(v.icon, color: v.color, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Identity re-verification',
                    style: theme.textTheme.labelMedium?.copyWith(
                      letterSpacing: 0.6,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Tabular figures matter more here than anywhere else in
                  // the app: this headline carries a confidence percentage
                  // that changes every few seconds, and proportional digits
                  // would make the whole line jitter on each update.
                  Text(
                    v.headline,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(
                          color: v.color,
                          fontWeight: FontWeight.w700,
                        )
                        .tabular,
                  ),
                  if (v.detail != null) ...[
                    const SizedBox(height: 4),
                    Text(v.detail!, style: theme.textTheme.bodySmall),
                  ],
                  if (result != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Last attempt ${_time(result!.at)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          )
                          .tabular,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  _Visuals _visuals(BuildContext context, VerificationResult? r) {
    switch (r) {
      case null:
        return _Visuals(
          icon: Icons.hourglass_empty,
          color: context.evidence.notExamined,
          headline: 'Awaiting first check',
        );

      case Verified(:final similarity):
        // Report the honest confidence, not the compressed legacy scale on
        // which an unrelated face reads as ~50%.
        final raw = similarity / 50 - 1;
        final shown = IdentityMatcher.displayConfidence(raw);
        return _Visuals(
          icon: Icons.verified_user,
          color: context.evidence.verified,
          headline: 'Verified · ${shown.toStringAsFixed(0)}% confidence',
        );

      case Mismatch(:final similarity, :final strike, :final isCritical):
        final raw = similarity / 50 - 1;
        final shown = IdentityMatcher.displayConfidence(raw);
        return _Visuals(
          icon: isCritical ? Icons.gpp_bad : Icons.warning_amber_rounded,
          color: isCritical
              ? context.evidence.disputed
              : context.evidence.unmeasured,
          headline: isCritical
              ? 'Identity mismatch — session halted'
              : 'Identity mismatch',
          detail: 'Live face matched at ${shown.toStringAsFixed(0)}% '
              '· strike $strike of $strikesAllowed',
        );

      case Unchecked(:final reason):
        return _Visuals(
          icon: Icons.help_outline,
          color: Colors.amber.shade800,
          headline: 'Not checked',
          // Say what went unmeasured. This is not a pass and not a failure.
          detail: '${reason.message}. This interval was not verified.',
        );
    }
  }
}

class _Visuals {
  const _Visuals({
    required this.icon,
    required this.color,
    required this.headline,
    this.detail,
  });

  final IconData icon;
  final Color color;
  final String headline;
  final String? detail;
}
