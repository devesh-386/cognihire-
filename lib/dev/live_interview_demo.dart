// Live harness for LiveInterviewScreen — wired to the real controller and a
// real local Ollama call, not a mock. Type an answer and it actually thinks,
// speaks (via flutter_tts), and follows up. Requires Ollama running locally
// with AppConfig.ollamaModel pulled. Delete once the screen is wired into the
// real app shell.
import 'package:flutter/material.dart';

import '../core/claims/claim.dart';
import '../core/config.dart';
import '../core/design/app_theme.dart';
import '../features/interview/interview_voice_controller.dart';
import '../features/interview/live_interview_screen.dart';

void main() {
  runApp(const _DemoApp());
}

class _DemoApp extends StatelessWidget {
  const _DemoApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: const _DemoScreen(),
    );
  }
}

const _demoClaim = Claim(
  id: 'c1',
  text: 'Built a food donation platform using Django',
  source: 'resume',
  skill: 'Django',
);

class _DemoScreen extends StatefulWidget {
  const _DemoScreen();
  @override
  State<_DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<_DemoScreen> {
  final _controller = InterviewVoiceController(
    claims: const [_demoClaim],
    jobRequirements: const ['Comfortable with backend web frameworks'],
  );

  bool _warm = false;
  bool _warmUpFailed = false;

  @override
  void initState() {
    super.initState();
    _controller.openWithQuestion('Tell me about your Django project.');
    _warmUp();
  }

  Future<void> _warmUp() async {
    final ok = await _controller.warmUp();
    if (!mounted) return;
    setState(() {
      _warm = ok;
      _warmUpFailed = !ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_warm) {
      return Scaffold(
        backgroundColor: const Color(0xFF17140F),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_warmUpFailed) const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                _warmUpFailed
                    ? "Couldn't reach Ollama at ${AppConfig.ollamaBaseUrl}. "
                        'Start it, then reload this page.'
                    : 'Waking up the local model…',
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return LiveInterviewScreen(controller: _controller);
  }
}
