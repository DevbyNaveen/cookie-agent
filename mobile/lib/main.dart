// Cookie on your phone.
//
// Pair once by scanning the code in Cookie on your computer (Settings →
// Sharing → Phone). Then: your agents and what they said, a chat with each,
// the changes waiting for your yes, and what woke on its own. Everything runs
// on your own Cookie; this app only shows it and passes on what you say.

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'home.dart';
import 'runner.dart';

void main() => runApp(const CookieApp());

class CookieApp extends StatelessWidget {
  const CookieApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Cookie's own warm amber on a quiet neutral, light and dark.
    const seed = Color(0xFFD97706);
    return MaterialApp(
      title: 'Cookie',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      home: const Start(),
    );
  }
}

/// Signed in already, or pair.
class Start extends StatefulWidget {
  const Start({super.key});
  @override
  State<Start> createState() => _StartState();
}

class _StartState extends State<Start> {
  Pairing? _pairing;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Runner.saved().then((p) => setState(() {
          _pairing = p;
          _loading = false;
        }));
  }

  Future<void> _paired(Pairing p) async {
    await Runner.save(p);
    setState(() => _pairing = p);
  }

  Future<void> _signOut() async {
    await Runner.forget();
    setState(() => _pairing = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final p = _pairing;
    if (p == null) return PairScreen(onPaired: _paired);
    return Home(runner: Runner(p), onSignOut: _signOut);
  }
}

class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.onPaired});
  final Future<void> Function(Pairing) onPaired;
  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _paste = TextEditingController();
  String? _error;
  bool _scanning = false;
  bool _checking = false;

  Future<void> _try(String raw) async {
    final p = Pairing.parse(raw);
    if (p == null) {
      setState(() => _error = "That isn't a Cookie code. In Cookie on your computer: Settings → Sharing → Phone.");
      return;
    }
    if (!p.encrypted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Not encrypted'),
          content: Text('${p.base} is plain http: anyone on the network between this phone and your computer could read the key. Use an https address in Cookie (Settings → Sharing → Public address) unless this is your own network.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Pair anyway')),
          ],
        ),
      );
      if (go != true) return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    // Proven before it is kept: the runner must answer with this key.
    final r = Runner(p);
    try {
      await r.call('me');
      await widget.onPaired(p);
    } on RunnerError catch (e) {
      setState(() => _error = e.message);
    } finally {
      r.close();
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Text('Cookie', style: t.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text('Your agents, on your phone. Open Cookie on your computer, go to Settings → Sharing → Phone, and scan the code.', style: t.textTheme.bodyLarge),
              const SizedBox(height: 24),
              Expanded(
                child: _scanning
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: MobileScanner(
                          onDetect: (capture) {
                            String? raw;
                            for (final b in capture.barcodes) {
                              if (b.rawValue != null) {
                                raw = b.rawValue;
                                break;
                              }
                            }
                            if (raw == null || _checking) return;
                            setState(() => _scanning = false);
                            _try(raw);
                          },
                        ),
                      )
                    : Center(
                        child: FilledButton.icon(
                          onPressed: _checking ? null : () => setState(() => _scanning = true),
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Scan the code'),
                        ),
                      ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _paste,
                decoration: const InputDecoration(labelText: 'Or paste your link', border: OutlineInputBorder()),
                onSubmitted: _try,
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _checking ? null : () => _try(_paste.text), child: Text(_checking ? 'Checking…' : 'Pair')),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: t.colorScheme.error))),
            ],
          ),
        ),
      ),
    );
  }
}
