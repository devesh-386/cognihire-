import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../core/design/app_theme.dart';
import 'interview_voice_controller.dart';

/// The live, full-screen voice interview — one presence indicator, one
/// caption line, minimal chrome.
///
/// ## Where this came from
///
/// Adapted from a ChatGPT Voice mode screenshot: top bar with a menu affordance
/// and a "Live" status pill, a centered circular presence indicator, bottom
/// mic/end controls, everything else stripped away. That reference is a phone
/// screen at rest (idle, no audio level, no caption) — this is the same shape
/// built for a resizable desktop window and wired to a controller that
/// actually drives it, not a static mock: the circle's motion reflects
/// [VoicePresence], and the caption is [InterviewVoiceController.currentSay]
/// streaming in live.
///
/// ## Why the palette isn't literally black-on-white
///
/// The reference is ChatGPT's own dark UI. Reusing it verbatim would put a
/// second product's visual identity on top of CogniHire's Golden Taupe theme
/// (`core/design/app_theme.dart`) — right layout, wrong brand. Dark mode here
/// uses the app's own near-black surface and gold accent instead, so the
/// screen belongs to this app on either color scheme.
///
/// ## Voice output, and what it stands in for
///
/// [_LiveInterviewScreenState] speaks each completed turn with `flutter_tts`
/// — the platform/browser voice, not Kokoro. It fires once per turn, on the
/// transition out of [VoicePresence.speaking], with the turn's *complete*
/// `say` text: `flutter_tts` has no streaming API, so speaking each partial
/// fragment as it arrived would repeat and re-speak overlapping words instead
/// of reading one clean sentence. The caption still streams in live per
/// [LiveTurnClient]'s design (see `prompts/README.md`) — only the audio waits
/// for the full sentence. Swapping in Kokoro later means replacing the
/// `_tts.speak(...)` call with playback from that server; the trigger point
/// (turn complete) does not change.
///
/// ## Voice input, and what it stands in for
///
/// The mic button uses `speech_to_text` (the OS/browser recognizer — Web
/// Speech API on this target) instead of a raw Whisper/LiveKit audio
/// transport. Recognised words fill the text field live as interim results,
/// same as any dictation UI; on the engine's *final* result the turn submits
/// automatically — you don't additionally have to press enter or tap
/// anything, which is what makes it feel like talking rather than dictating
/// into a form. [InterviewVoiceController.submitCandidateUtterance] does not
/// know or care whether the text it received came from typing or from this —
/// swapping in Whisper later means changing what feeds [_typedController],
/// not the controller.
///
/// ## What isn't here yet
///
/// No LiveKit transport and no continuous/barge-in listening — the mic is
/// push-to-talk (tap to start, engine ends it on silence or tap again to
/// cancel), not an always-open channel the candidate can interrupt the AI
/// through mid-sentence.
class LiveInterviewScreen extends StatefulWidget {
  const LiveInterviewScreen({
    super.key,
    required this.controller,
    this.openMic = true,
    this.identityOverlay,
  });

  final InterviewVoiceController controller;

  /// Continuous listening: the mic starts on its own whenever it's the
  /// candidate's turn and the AI isn't currently speaking, instead of
  /// requiring a tap for every single utterance. A tap is still available —
  /// to interrupt the AI mid-sentence (barge-in), or to kick the mic off
  /// again if auto-start didn't fire. `false` restores the original
  /// push-to-talk behaviour, kept for the case where continuous listening
  /// picks up background noise a candidate would rather control by hand.
  final bool openMic;

  /// Optional camera/identity-verification widget, rendered as a small
  /// floating overlay. This screen has no opinion about what it shows or how
  /// it's produced — it only reserves the corner for it, so a caller running
  /// a verified session can show the reference check without this screen
  /// needing to know about cameras or embeddings.
  final Widget? identityOverlay;

  @override
  State<LiveInterviewScreen> createState() => _LiveInterviewScreenState();
}

class _LiveInterviewScreenState extends State<LiveInterviewScreen>
    with TickerProviderStateMixin {
  // Three independent loops instead of one, because one shared clock made
  // every state look like the same animation at a different speed. Each has
  // its own job: breathe never stops (a static circle reads as frozen, not
  // calm), sheen gives the idle state ambient life without implying anything
  // is happening, ripple is the only one that visibly means "audio is
  // playing right now."
  late final AnimationController _breathe;
  late final AnimationController _sheen;
  late final AnimationController _ripple;
  final _typedController = TextEditingController();
  final _tts = FlutterTts();
  final _speech = stt.SpeechToText();

  /// What [widget.controller]'s presence was on the previous notification —
  /// the only way to detect the "just finished speaking" edge rather than
  /// re-speaking the same completed turn on every unrelated rebuild.
  VoicePresence? _lastPresence;

  /// Null until [stt.SpeechToText.initialize] resolves. Distinguishing
  /// "haven't checked yet" from "checked, and it's unavailable" (`false`)
  /// matters here: the former should render nothing rather than briefly
  /// flashing a disabled mic that then turns on.
  bool? _speechAvailable;
  bool _listening = false;

  /// True while `flutter_tts` is actually producing audio — distinct from
  /// [VoicePresence.speaking], which is over by the time this starts (see
  /// [_onControllerChanged]'s doc). Open-mic auto-listen must not start while
  /// this is true, or the recognizer would transcribe the AI's own voice.
  bool _speaking = false;

  @override
  void initState() {
    super.initState();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat(reverse: true);
    _sheen = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _ripple = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _lastPresence = widget.controller.presence;
    widget.controller.addListener(_onControllerChanged);
    unawaited(_initSpeech());
    unawaited(_configureVoice());
    _tts.setStartHandler(() {
      if (!mounted) return;
      setState(() => _speaking = true);
    });
    _tts.setCompletionHandler(() {
      if (!mounted) return;
      setState(() => _speaking = false);
      _maybeAutoListen();
    });
    _tts.setCancelHandler(() {
      if (!mounted) return;
      setState(() => _speaking = false);
    });
  }

  /// Picks a natural-sounding voice instead of `flutter_tts`'s bare platform
  /// default, and slows the rate slightly — the default rate reads as rushed
  /// for a live interview question a candidate needs to actually parse.
  ///
  /// Best-effort throughout: `getVoices` is unsupported or returns nothing
  /// usable on several platforms (web in particular), and a failed lookup
  /// here must never block the screen — it just means the OS's own default
  /// voice keeps being used, same as before this existed.
  Future<void> _configureVoice() async {
    try {
      await _tts.setSpeechRate(0.48);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);

      final raw = await _tts.getVoices;
      if (raw is! List) return;
      final voices = raw.whereType<Map>().toList();

      // Preference order: named "enhanced"/"premium"/neural voices first —
      // the ones platforms ship as an upgrade over their default robotic
      // voice — then any English voice at all, so a device with only one
      // installed voice still gets an explicit (idempotent) selection rather
      // than silently keeping whatever the platform happened to default to.
      bool isEnglish(Map v) =>
          (v['locale']?.toString() ?? '').toLowerCase().startsWith('en');
      bool looksEnhanced(Map v) {
        final name = (v['name']?.toString() ?? '').toLowerCase();
        return name.contains('enhanced') ||
            name.contains('premium') ||
            name.contains('neural') ||
            name.contains('natural');
      }

      final preferred = voices.where((v) => isEnglish(v) && looksEnhanced(v));
      final fallback = voices.where(isEnglish);
      final chosen = preferred.isNotEmpty
          ? preferred.first
          : (fallback.isNotEmpty ? fallback.first : null);
      if (chosen == null) return;

      await _tts.setVoice({
        'name': '${chosen['name']}',
        'locale': '${chosen['locale']}',
      });
    } catch (_) {
      // Best-effort — see doc above.
    }
  }

  Future<void> _initSpeech() async {
    // Browsers gate SpeechRecognition on a user gesture — `initialize()`
    // itself never prompts, only the first `listen()` call does, which is
    // why this can safely run unprompted at screen open rather than waiting
    // for a mic tap. Wrapped rather than trusted to resolve cleanly: no
    // platform channel exists in a widget test, and a real browser without
    // SpeechRecognition support is a real, non-exceptional case either way —
    // both should land on "mic unavailable", never an unhandled rejection.
    bool available = false;
    try {
      available = await _speech.initialize(
        onError: (error) {
          if (!mounted) return;
          setState(() => _listening = false);
        },
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'notListening' || status == 'done') {
            setState(() => _listening = false);
            // Silence timed out with nothing said (no final result fired) —
            // open mic means this is not the candidate declining to answer,
            // it's the recognizer's own timeout, so pick listening back up.
            // Scheduled rather than called inline: `onStatus` can fire from
            // within `_speech.listen`'s own call stack, and starting a new
            // listen session synchronously from there is exactly the kind of
            // reentrant platform-channel call `speech_to_text` warns against.
            WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoListen());
          }
        },
      );
    } catch (_) {
      available = false;
    }
    if (!mounted) return;
    setState(() => _speechAvailable = available);
    _maybeAutoListen();
  }

  /// Starts listening on its own when open mic is enabled, the recognizer is
  /// available, nobody is already listening, the AI isn't currently speaking,
  /// and it is actually the candidate's turn. Every caller that might make
  /// listening appropriate again — controller state changes, a recognizer
  /// timeout, TTS finishing — funnels through this one gate instead of each
  /// repeating the condition slightly differently.
  void _maybeAutoListen() {
    if (!widget.openMic) return;
    if (_speechAvailable != true) return;
    if (_listening || _speaking) return;
    if (widget.controller.presence != VoicePresence.listening) return;
    _startListening();
  }

  void _startListening() {
    setState(() => _listening = true);
    _speech.listen(
      onResult: (result) {
        _typedController.text = result.recognizedWords;
        if (result.finalResult) {
          setState(() => _listening = false);
          _submitTypedTurn();
        }
      },
    );
  }

  /// The mic control's tap handler. Three different things depending on what
  /// is happening right now:
  /// - AI is speaking: **barge-in** — stop the audio and start listening for
  ///   the interruption immediately, rather than waiting out the sentence.
  /// - Already listening: stop early and submit whatever was heard so far,
  ///   same as ending a push-to-talk turn.
  /// - Otherwise: start listening on demand — the manual override for when
  ///   auto-listen didn't fire (a recognizer error, or open mic disabled).
  void _toggleMic() {
    if (_speechAvailable != true) return;
    if (_speaking) {
      unawaited(_tts.stop()); // fires the cancel handler, clearing _speaking
      if (widget.controller.presence == VoicePresence.listening) {
        _startListening();
      }
      return;
    }
    if (_listening) {
      _speech.stop();
      setState(() => _listening = false);
      return;
    }
    if (widget.controller.presence != VoicePresence.listening) return;
    _startListening();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _breathe.dispose();
    _sheen.dispose();
    _ripple.dispose();
    _typedController.dispose();
    _tts.stop();
    _speech.stop();
    super.dispose();
  }

  void _onControllerChanged() {
    final presence = widget.controller.presence;
    final justFinishedSpeaking = _lastPresence == VoicePresence.speaking &&
        presence != VoicePresence.speaking;
    _lastPresence = presence;
    if (justFinishedSpeaking && widget.controller.currentSay.isNotEmpty) {
      // Fire-and-forget: a stalled TTS engine should never block the turn
      // loop from moving on, same principle as everything else in this
      // screen degrading visibly instead of hanging. `_speaking` flips true
      // via `setStartHandler` once playback actually begins, and open-mic
      // auto-listen waits for that to clear before starting the recognizer.
      unawaited(_tts.speak(widget.controller.currentSay));
    } else if (presence == VoicePresence.listening) {
      // Covers every other way "the candidate's turn" can begin: the very
      // first turn (never `speaking`), and a degraded turn that returns
      // straight to `listening` without ever streaming `say` through TTS.
      _maybeAutoListen();
    }
    setState(() {});
  }

  void _submitTypedTurn() {
    final text = _typedController.text;
    if (text.trim().isEmpty) return;
    _typedController.clear();
    widget.controller.submitCandidateUtterance(text);
  }

  /// What this session is examining, plus the transcript so far.
  ///
  /// Read-only. Nothing in here can edit a claim mid-interview, because a claim
  /// the candidate confirmed before the session began is the fixed thing the
  /// session is testing against — letting the interviewer reword it while
  /// probing it would destroy the provenance the whole product rests on.
  void _showSessionSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final claims = widget.controller.claims;
        final requirements = widget.controller.jobRequirements;
        final transcript = widget.controller.transcript;

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.92,
          builder: (_, scrollController) => ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(
              Spacing.xl,
              0,
              Spacing.xl,
              Spacing.xxl,
            ),
            children: [
              Text('This session', style: theme.textTheme.headlineSmall),
              const SizedBox(height: Spacing.xs),
              Text(
                'The claims under examination, in the candidate\'s own words. '
                'Read-only during a live session.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Spacing.xl),

              Text(
                'CLAIMS (${claims.length})',
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: Spacing.sm),
              if (claims.isEmpty)
                Text(
                  'No claims were attached to this session.',
                  style: theme.textTheme.bodyMedium,
                )
              else
                for (final claim in claims)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('"${claim.text}"',
                            style: theme.textTheme.bodyLarge),
                        const SizedBox(height: 2),
                        Text(
                          claim.skill == null
                              ? claim.source
                              : '${claim.source} · tagged ${claim.skill}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),

              if (requirements.isNotEmpty) ...[
                const SizedBox(height: Spacing.lg),
                Text(
                  'ROLE REQUIREMENTS (${requirements.length})',
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(height: Spacing.sm),
                for (final requirement in requirements)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.xs),
                    child: Text('· $requirement',
                        style: theme.textTheme.bodyMedium),
                  ),
              ],

              const SizedBox(height: Spacing.lg),
              Text(
                'TRANSCRIPT (${transcript.length} turns)',
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: Spacing.sm),
              if (transcript.isEmpty)
                Text(
                  'Nothing has been said yet.',
                  style: theme.textTheme.bodyMedium,
                )
              else
                for (final turn in transcript)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          turn.role.toUpperCase(),
                          style: theme.textTheme.labelSmall,
                        ),
                        Text(
                          turn.text,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontStyle: turn.role == 'candidate'
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }

  /// The session's technical state.
  ///
  /// Every line is a fact the screen already knows and was otherwise hiding. It
  /// matters most when something has degraded: a caption keeps streaming whether
  /// the live model answered or the scripted bank did, and an interviewer who
  /// cannot tell which is reading a transcript they will later misattribute.
  void _showDiagnosticsSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final controller = widget.controller;
        final degraded = controller.degradedReason;

        Widget row(String label, String value, {bool warn = false}) => Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(label, style: theme.textTheme.bodySmall),
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Text(
                      value,
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: warn ? theme.colorScheme.error : null,
                      ),
                    ),
                  ),
                ],
              ),
            );

        return Padding(
          padding: const EdgeInsets.fromLTRB(
            Spacing.xl,
            0,
            Spacing.xl,
            Spacing.xxl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Session state', style: theme.textTheme.headlineSmall),
              const SizedBox(height: Spacing.lg),
              row('Presence', switch (controller.presence) {
                VoicePresence.listening => 'Listening',
                VoicePresence.thinking => 'Thinking',
                VoicePresence.speaking => 'Speaking',
                VoicePresence.ended => 'Ended',
              }),
              row(
                'Microphone',
                switch (_speechAvailable) {
                  null => 'Still checking…',
                  false => 'Unavailable — type instead',
                  true => _listening ? 'Listening' : 'Ready',
                },
                warn: _speechAvailable == false,
              ),
              row(
                'Question source',
                degraded == null
                    ? 'Live model'
                    : 'Scripted question bank',
                warn: degraded != null,
              ),
              if (degraded != null) ...[
                const SizedBox(height: Spacing.xs),
                Text(
                  'Why: $degraded',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              row('Turns kept in context', '${controller.windowTurns}'),
              row('Session budget', '${controller.totalSeconds ~/ 60} min'),
              const SizedBox(height: Spacing.lg),
              Text(
                'These are the session\'s own values, not settings — nothing '
                'here can be changed mid-interview, because changing how the '
                'session is run halfway through would make its record '
                'incomparable with every other session.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brand = context.brand;
    final presence = widget.controller.presence;
    final ended = presence == VoicePresence.ended;

    return Scaffold(
      backgroundColor: _stageColor(scheme),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _TopBar(
                  presence: presence,
                  onClose: () => Navigator.of(context).maybePop(),
                  onMenu: _showSessionSheet,
                  onSettings: _showDiagnosticsSheet,
                ),
                Expanded(
                  child: Center(
                    child: _PresenceIndicator(
                      presence: presence,
                      breathe: _breathe,
                      sheen: _sheen,
                      ripple: _ripple,
                      accent: brand.accent,
                    ),
                  ),
                ),
                _CaptionLine(
                  text: widget.controller.currentSay,
                  degradedReason: widget.controller.degradedReason,
                ),
                const SizedBox(height: Spacing.md),
                if (!ended)
                  _InputRow(
                    controller: _typedController,
                    enabled: presence == VoicePresence.listening,
                    // Barge-in stays live while the AI is speaking, even
                    // though the rest of the row (typing, End) is gated to
                    // the candidate's actual turn.
                    micEnabled: _speechAvailable == true &&
                        (presence == VoicePresence.listening || _speaking),
                    onSubmit: _submitTypedTurn,
                    onEnd: widget.controller.end,
                    listening: _listening,
                    onMicTap: _toggleMic,
                    accent: brand.accent,
                  )
                else
                  const _EndedRow(),
                const SizedBox(height: Spacing.lg),
              ],
            ),
            if (widget.identityOverlay != null)
              Positioned(
                // Clears the top bar's own icon buttons rather than stacking
                // under them.
                top: 64,
                right: Spacing.lg,
                child: SafeArea(child: widget.identityOverlay!),
              ),
          ],
        ),
      ),
    );
  }

  Color _stageColor(ColorScheme scheme) =>
      scheme.brightness == Brightness.dark
          ? scheme.surface
          : const Color(0xFF17140F);
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.presence,
    required this.onClose,
    required this.onMenu,
    required this.onSettings,
  });

  final VoicePresence presence;
  final VoidCallback onClose;

  /// Opens what this session is actually examining. Not decoration: during a
  /// live interview the claims under test scroll off the screen, and an
  /// interviewer who cannot re-read them is guessing.
  final VoidCallback onMenu;

  /// Opens the session's technical state — mic, model, turn budget. The one
  /// thing worth surfacing mid-interview is whether the machine is still doing
  /// what the caption implies it is.
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final label = switch (presence) {
      VoicePresence.listening => 'Live',
      VoicePresence.thinking => 'Thinking',
      VoicePresence.speaking => 'Speaking',
      VoicePresence.ended => 'Ended',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg, vertical: Spacing.sm),
      child: Row(
        children: [
          _ChromeIconButton(icon: Icons.menu_rounded, onTap: onMenu),
          const SizedBox(width: Spacing.sm),
          _StatusPill(label: label, live: presence != VoicePresence.ended, accent: brand.accent),
          const Spacer(),
          _ChromeIconButton(icon: Icons.tune_rounded, onTap: onSettings),
          const SizedBox(width: Spacing.sm),
          _ChromeIconButton(icon: Icons.close_rounded, onTap: onClose),
        ],
      ),
    );
  }
}

class _ChromeIconButton extends StatelessWidget {
  const _ChromeIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 20, color: Colors.white.withValues(alpha: 0.92)),
        ),
      ),
    );
  }
}

/// The mic control. Three visually distinct states, not a single icon with a
/// color swap: off (dim, tappable), listening (filled accent, pulsing —
/// mirrors [_PresenceIndicator]'s ripple so "I am capturing your voice" reads
/// as the same kind of motion as "the AI is speaking"), unavailable (dim,
/// inert — `speech_to_text` has no engine on this browser/platform).
class _MicButton extends StatefulWidget {
  const _MicButton({
    required this.listening,
    required this.enabled,
    required this.accent,
    required this.onTap,
  });

  final bool listening;
  final bool enabled;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: widget.listening
          ? widget.accent
          : Colors.white.withValues(alpha: widget.enabled ? 0.08 : 0.04),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.enabled ? widget.onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, child) => Transform.scale(
              scale: widget.listening ? 1.0 + 0.12 * _pulse.value : 1.0,
              child: child,
            ),
            child: Icon(
              widget.listening ? Icons.mic_rounded : Icons.mic_none_rounded,
              size: 20,
              color: widget.listening
                  ? Colors.black
                  : Colors.white.withValues(alpha: widget.enabled ? 0.92 : 0.35),
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatefulWidget {
  const _StatusPill({required this.label, required this.live, required this.accent});

  final String label;
  final bool live;
  final Color accent;

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dot;

  @override
  void initState() {
    super.initState();
    _dot = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _dot.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.live)
            AnimatedBuilder(
              animation: _dot,
              builder: (context, _) => Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: widget.accent
                      .withValues(alpha: 0.5 + 0.5 * _dot.value),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          if (widget.live) const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              widget.label,
              key: ValueKey(widget.label),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The circle, and everything around it.
///
/// Four layers, back to front:
/// 1. [_ripple] — two staggered rings that expand and fade outward, visible
///    only while [VoicePresence.speaking]. This is the one motion that
///    actually means something ("audio is playing"), not decoration.
/// 2. [_sheen] — a slowly rotating soft-light gradient inside the disc,
///    always running at every presence including [VoicePresence.listening].
///    A perfectly still circle reads as frozen or broken; this keeps the
///    screen visibly alive without claiming anything is happening.
/// 3. The disc itself, breathing (scaling) on [_breathe] — amplitude and
///    speed both widen with [presence], so the *rhythm* communicates state
///    even with the sound off, the way a human's stillness vs. animation
///    does in conversation.
/// 4. Its glow ([BoxShadow]), which only appears once [presence] leaves
///    [VoicePresence.listening] — silence has no glow.
///
/// Colour never jump-cuts between states: [TweenAnimationBuilder] crossfades
/// it over 500ms so "thinking" easing into "speaking" looks like one
/// continuous thought rather than a mode switch.
class _PresenceIndicator extends StatelessWidget {
  const _PresenceIndicator({
    required this.presence,
    required this.breathe,
    required this.sheen,
    required this.ripple,
    required this.accent,
  });

  final VoicePresence presence;
  final AnimationController breathe;
  final AnimationController sheen;
  final AnimationController ripple;
  final Color accent;

  static const double _base = 180;

  @override
  Widget build(BuildContext context) {
    final restColor = switch (presence) {
      VoicePresence.listening => Colors.white.withValues(alpha: 0.26),
      VoicePresence.thinking => accent.withValues(alpha: 0.6),
      VoicePresence.speaking => accent,
      VoicePresence.ended => Colors.white.withValues(alpha: 0.12),
    };
    // Idle breathes barely at all (a held breath, not none); thinking and
    // speaking widen the swing so the same clock reads as calmer or busier
    // purely through amplitude.
    final breatheAmplitude = switch (presence) {
      VoicePresence.listening => 0.015,
      VoicePresence.thinking => 0.05,
      VoicePresence.speaking => 0.09,
      VoicePresence.ended => 0.0,
    };
    final active = presence == VoicePresence.speaking;

    return SizedBox(
      width: _base * 2,
      height: _base * 2,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (active)
            AnimatedBuilder(
              animation: ripple,
              builder: (context, _) => Stack(
                alignment: Alignment.center,
                children: [
                  _ripplePing(ripple.value, accent),
                  _ripplePing((ripple.value + 0.5) % 1.0, accent),
                ],
              ),
            ),
          TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: restColor),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
            builder: (context, color, _) {
              return AnimatedBuilder(
                animation: Listenable.merge([breathe, sheen]),
                builder: (context, _) {
                  final scale =
                      1.0 + breatheAmplitude * math.sin(breathe.value * math.pi);
                  return Transform.scale(
                    scale: scale,
                    child: Container(
                      width: _base,
                      height: _base,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: presence == VoicePresence.listening ||
                                presence == VoicePresence.ended
                            ? null
                            : [
                                BoxShadow(
                                  color: accent.withValues(alpha: 0.35),
                                  blurRadius: 44,
                                  spreadRadius: 6,
                                ),
                              ],
                      ),
                      child: ClipOval(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ColoredBox(color: color ?? restColor),
                            Transform.rotate(
                              angle: sheen.value * 2 * math.pi,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Colors.white.withValues(alpha: 0.16),
                                      Colors.white.withValues(alpha: 0.0),
                                      Colors.white.withValues(alpha: 0.08),
                                    ],
                                    stops: const [0.0, 0.5, 1.0],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  /// One ring of the sonar ping at phase [t] in [0, 1): scales from 1.0 to
  /// ~1.9 and fades to nothing over the same span, so it reads as expanding
  /// outward from the disc rather than a separate shape appearing.
  Widget _ripplePing(double t, Color color) {
    return Opacity(
      opacity: (1.0 - t) * 0.5,
      child: Transform.scale(
        scale: 1.0 + t * 0.9,
        child: Container(
          width: _base,
          height: _base,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
        ),
      ),
    );
  }
}

class _CaptionLine extends StatelessWidget {
  const _CaptionLine({required this.text, required this.degradedReason});

  final String text;
  final String? degradedReason;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (degradedReason != null) {
      child = Padding(
        key: const ValueKey('degraded'),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
        child: Text(
          "Couldn't reach the local model — try answering again. ($degradedReason)",
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.orange.shade200, fontSize: 14),
        ),
      );
    } else if (text.isEmpty) {
      child = const SizedBox(key: ValueKey('empty'), height: 24);
    } else {
      child = Padding(
        // Keyed on "has content", not on the text itself: `text` grows one
        // partial chunk at a time while `say` streams in (that growth *is*
        // the animation — see LiveTurnClient's streaming design), so keying
        // per-character here would restart the fade on every chunk instead
        // of once when a turn's caption first appears.
        key: const ValueKey('content'),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.92),
            fontSize: 17,
            height: 1.4,
          ),
        ),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.12),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class _InputRow extends StatelessWidget {
  const _InputRow({
    required this.controller,
    required this.enabled,
    required this.onSubmit,
    required this.onEnd,
    required this.listening,
    required this.micEnabled,
    required this.onMicTap,
    required this.accent,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSubmit;
  final VoidCallback onEnd;
  final bool listening;

  /// Whether the mic control itself should respond to a tap. Deliberately
  /// separate from [enabled]: barge-in means the mic stays live while the AI
  /// is speaking, a moment where the rest of this row (typing, ending the
  /// call) is still gated to the candidate's actual turn.
  final bool micEnabled;
  final VoidCallback onMicTap;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      child: Row(
        children: [
          Expanded(
            child: AnimatedOpacity(
              opacity: enabled ? 1.0 : 0.5,
              duration: const Duration(milliseconds: 200),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  onSubmitted: (_) => onSubmit(),
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.92)),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: listening
                        ? 'Listening…'
                        : enabled
                            ? 'Tap the mic, or type your answer here'
                            : 'Waiting for the interviewer…',
                    hintStyle:
                        TextStyle(color: Colors.white.withValues(alpha: 0.45)),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          _MicButton(
            listening: listening,
            enabled: micEnabled,
            accent: accent,
            onTap: onMicTap,
          ),
          const SizedBox(width: Spacing.sm),
          Material(
            color: Colors.white,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onEnd,
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.close_rounded, size: 20, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EndedRow extends StatelessWidget {
  const _EndedRow();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Interview ended.',
      style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 14),
    );
  }
}
