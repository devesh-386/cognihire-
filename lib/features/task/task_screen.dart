import 'package:flutter/material.dart';

import '../../core/interview/followup.dart';
import '../../core/telemetry/keystroke_capture.dart';
import '../../core/telemetry/keystroke_event.dart';
import '../../core/telemetry/process_telemetry.dart';

/// The coding/answer task, with live process telemetry driving follow-ups.
///
/// This is the demonstrable form of the differentiator: the interview reacts to
/// *how* the answer is being produced while it is being produced, rather than
/// filing a report about it afterwards.
class TaskScreen extends StatefulWidget {
  const TaskScreen({
    super.key,
    this.prompt =
        'Write a function that returns the first non-repeating character '
            'in a string. Explain your reasoning as you go.',
  });

  final String prompt;

  @override
  State<TaskScreen> createState() => _TaskScreenState();
}

class _TaskScreenState extends State<TaskScreen> {
  late final ProcessTelemetry _telemetry;
  // Fine-grained keystroke capture runs alongside the length-based telemetry;
  // neither derives from the other. The log feeds the typing-dynamics feature
  // group; it never holds a character.
  final _capture = KeystrokeCapture();
  final _keystrokes = KeystrokeLog();
  final _generator = const FollowUpGenerator();
  final _controller = TextEditingController();

  List<FollowUp> _followUps = const [];
  final Set<String> _answered = {};

  @override
  void initState() {
    super.initState();
    _telemetry = ProcessTelemetry(taskStartedAt: DateTime.now());
    _controller.addListener(_onEdit);
  }

  void _onEdit() {
    final selection = _controller.selection;
    _telemetry.record(_controller.text.length);
    final keystroke = _capture.captureFrom(
      newText: _controller.text,
      cursor: selection.baseOffset < 0 ? _controller.text.length : selection.baseOffset,
      selectionLength: selection.isValid ? (selection.end - selection.start).abs() : 0,
      at: DateTime.now(),
    );
    if (keystroke != null) _keystrokes.add(keystroke);
    final next = _generator.generate(_telemetry);
    if (next.length != _followUps.length) {
      setState(() => _followUps = next);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onEdit);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final signals = _telemetry.signals();
    final pending =
        _followUps.where((f) => !_answered.contains(f.observation)).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Task')),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        widget.prompt,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Write your answer here…',
                        alignLabelWithHint: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          SizedBox(
            width: 340,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Live follow-ups',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Questions triggered by how the answer is being written.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (pending.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Nothing to ask about yet.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                else
                  for (final f in pending) _followUpCard(f),
                const Divider(height: 32),
                Text('Process signals',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _signal('Time to first keystroke',
                    _fmtDuration(signals.timeToFirstKeystroke)),
                _signal('Characters written', '${signals.totalInserted}'),
                _signal('Characters deleted', '${signals.totalDeleted}'),
                _signal(
                  'Revision ratio',
                  signals.revisionRatio == null
                      ? 'not measurable'
                      : signals.revisionRatio!.toStringAsFixed(2),
                ),
                _signal('Bulk insertions', '${signals.bulkInsertCount}'),
                _signal('Pauses', '${signals.pauseCount}'),
                _signal('Longest pause', _fmtDuration(signals.longestPause)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _followUpCard(FollowUp f) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(f.question,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            // The candidate can always see why they were asked.
            Text(
              f.observation,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () =>
                    setState(() => _answered.add(f.observation)),
                child: const Text('Answered'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _signal(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(label,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            Text(value,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
      );

  static String _fmtDuration(Duration? d) {
    if (d == null) return '—';
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }
}
