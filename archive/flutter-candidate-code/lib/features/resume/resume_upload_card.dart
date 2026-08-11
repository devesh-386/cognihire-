import 'package:flutter/material.dart';

import '../../core/design/app_theme.dart';
import '../common/empty_state.dart';
import 'resume_pick.dart';

/// A resume upload control: click to browse, dashed dropzone at rest, a
/// filename chip once something is attached.
///
/// The visual language borrows the shape of a familiar pattern — dropzone,
/// then an attached-file chip — but every state it shows is genuine. There is
/// no fake processing delay, no keyword-guessed result standing in for a real
/// read, and no claim extraction implied: this control's job ends at "here is
/// the text this file actually contains, if any."
class ResumeUploadCard extends StatefulWidget {
  const ResumeUploadCard({super.key, this.onPicked});

  /// Called with the pick whenever one succeeds (including an unreadable
  /// format) — never called for a cancelled pick.
  final ValueChanged<ResumePick>? onPicked;

  @override
  State<ResumeUploadCard> createState() => _ResumeUploadCardState();
}

class _ResumeUploadCardState extends State<ResumeUploadCard> {
  ResumePick? _pick;
  bool _picking = false;
  String? _pickError;

  Future<void> _browse() async {
    setState(() {
      _picking = true;
      _pickError = null;
    });

    try {
      final result = await pickResume();
      if (!mounted) return;
      // A null result means the user cancelled — a real, distinct outcome,
      // not an error and not treated as "no resume".
      if (result != null) {
        setState(() => _pick = result);
        widget.onPicked?.call(result);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _pickError = '$e');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _clear() => setState(() {
        _pick = null;
        _pickError = null;
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pick = _pick;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              label: 'Resume',
              description: '.txt is read directly. .pdf and .docx attach but '
                  'are not parsed yet in this build.',
            ),
            const SizedBox(height: Spacing.md),
            if (pick == null) _dropzone(theme) else _attached(theme, pick),
            if (_pickError != null) ...[
              const SizedBox(height: Spacing.sm),
              Text(
                _pickError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _dropzone(ThemeData theme) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _picking ? null : _browse,
          borderRadius: BorderRadius.circular(Radii.surface),
          child: DottedBorder(
            colour: theme.colorScheme.outlineVariant,
            radius: Radii.surface,
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xxl),
                child: Column(
                  children: [
                    if (_picking)
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        Icons.upload_file_outlined,
                        size: 28,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    const SizedBox(height: Spacing.sm),
                    Text(
                      _picking ? 'Opening file picker…' : 'Click to browse',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '.txt · .pdf · .docx',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  Widget _attached(ThemeData theme, ResumePick pick) => Container(
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.surface),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  pick.hasText
                      ? Icons.description_outlined
                      : Icons.attach_file,
                  size: 18,
                  color: pick.hasText
                      ? context.evidence.verified
                      : context.evidence.unmeasured,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    pick.fileName,
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Remove',
                  onPressed: _clear,
                ),
              ],
            ),
            const SizedBox(height: Spacing.xs),
            if (pick.hasText)
              StatusChip(
                icon: Icons.check_circle_outline,
                label: '${pick.text!.trim().length} characters read',
                colour: context.evidence.verified,
              )
            else
              Text(
                pick.extractionNote ?? 'No text could be read from this file.',
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _picking ? null : _browse,
                child: const Text('Choose a different file'),
              ),
            ),
          ],
        ),
      );
}

/// A dashed rounded-rectangle border. Flutter has no built-in dashed
/// decoration, and this is a small, self-contained one rather than a new
/// package dependency for a single visual.
class DottedBorder extends StatelessWidget {
  const DottedBorder({
    super.key,
    required this.child,
    required this.colour,
    this.radius = 12,
  });

  final Widget child;
  final Color colour;
  final double radius;

  @override
  Widget build(BuildContext context) => CustomPaint(
        painter: _DashedRRectPainter(colour: colour, radius: radius),
        child: child,
      );
}

class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({required this.colour, required this.radius});

  final Color colour;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + 6).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + 5;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      oldDelegate.colour != colour || oldDelegate.radius != radius;
}
