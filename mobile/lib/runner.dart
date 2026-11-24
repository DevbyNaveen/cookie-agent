// The phone's connection to your Cookie runner: the same HTTP API the
// desktop app's web page uses (`POST /api/<command>`, `GET /events`), with
// the runner's key from the QR code in Settings → Sharing → Phone.
//
// The key is kept in the phone's secure storage (Keychain on iOS, Keystore
// on Android), never in plain preferences, and sent only over the address
// it came with.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class RunnerError implements Exception {
  RunnerError(this.message, {this.signedOut = false});
  final String message;

  /// The runner refused the key: pair again.
  final bool signedOut;
  @override
  String toString() => message;
}

/// Where the runner is, and its key.
class Pairing {
  const Pairing(this.base, this.token);
  final String base;
  final String token;

  /// `cookie://pair?u=<address>&t=<key>` (the QR), or the runner's own link
  /// `https://host/#token=<key>` (Settings → Sharing → Your link).
  static Pairing? parse(String raw) {
    final text = raw.trim();
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme == 'cookie' && uri.host == 'pair') {
      final u = uri.queryParameters['u'];
      final t = uri.queryParameters['t'];
      if (u == null || t == null || t.isEmpty) return null;
      return _checked(u, t);
    }
    if ((uri.scheme == 'https' || uri.scheme == 'http') && uri.fragment.startsWith('token=')) {
      final t = Uri.decodeComponent(uri.fragment.substring('token='.length));
      return _checked('${uri.scheme}://${uri.authority}', t);
    }
    return null;
  }

  static Pairing? _checked(String base, String token) {
    final b = Uri.tryParse(base.trim());
    if (b == null || !(b.scheme == 'https' || b.scheme == 'http') || b.host.isEmpty) return null;
    final clean = base.trim().replaceAll(RegExp(r'/+$'), '');
    return Pairing(clean, token.trim());
  }

  /// Over https the key is encrypted on the way; over http anyone on the
  /// network path can read it, so the app says so before pairing.
  bool get encrypted => Uri.parse(base).scheme == 'https';
}

class Runner {
  Runner(this.pairing);
  final Pairing pairing;
  final http.Client _http = http.Client();

  static const _store = FlutterSecureStorage();
  static const _kBase = 'cookie.runner.base';
  static const _kToken = 'cookie.runner.token';

  static Future<Pairing?> saved() async {
    final base = await _store.read(key: _kBase);
    final token = await _store.read(key: _kToken);
    if (base == null || token == null) return null;
    return Pairing(base, token);
  }

  static Future<void> save(Pairing p) async {
    await _store.write(key: _kBase, value: p.base);
    await _store.write(key: _kToken, value: p.token);
  }

  static Future<void> forget() async {
    await _store.delete(key: _kBase);
    await _store.delete(key: _kToken);
  }

  /// One command, as the desktop app gives it. Its answer, or a [RunnerError].
  Future<dynamic> call(String cmd, [Map<String, dynamic> args = const {}]) async {
    final http.Response r;
    try {
      r = await _http
          .post(
            Uri.parse('${pairing.base}/api/$cmd'),
            headers: {'Authorization': 'Bearer ${pairing.token}', 'Content-Type': 'application/json'},
            body: jsonEncode(args),
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw RunnerError("Your Cookie didn't answer in 30 seconds.");
    } catch (_) {
      throw RunnerError("Couldn't reach your Cookie. Is the computer on and serving?");
    }
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      throw RunnerError('Your Cookie answered ${r.statusCode}.');
    }
    if (r.statusCode == 401) throw RunnerError('This phone is no longer signed in. Scan the code again.', signedOut: true);
    if (body is Map && body.containsKey('error')) throw RunnerError('${body['error']}');
    if (body is Map && body.containsKey('ok')) return body['ok'];
    throw RunnerError('Your Cookie answered ${r.statusCode}.');
  }

  /// Everything that happens on the runner, as it happens (server-sent events).
  /// Reconnects with a growing pause when the connection drops.
  Stream<Map<String, dynamic>> events() async* {
    var pause = const Duration(seconds: 2);
    while (true) {
      try {
        final req = http.Request('GET', Uri.parse('${pairing.base}/events?token=${Uri.encodeQueryComponent(pairing.token)}'));
        req.headers['Accept'] = 'text/event-stream';
        final resp = await _http.send(req);
        if (resp.statusCode == 401) throw RunnerError('signed out', signedOut: true);
        if (resp.statusCode != 200) throw RunnerError('events ${resp.statusCode}');
        pause = const Duration(seconds: 2);
        var data = StringBuffer();
        await for (final line in resp.stream.transform(utf8.decoder).transform(const LineSplitter())) {
          if (line.startsWith('data:')) {
            data.write(line.substring(5).trimLeft());
          } else if (line.isEmpty && data.isNotEmpty) {
            try {
              final ev = jsonDecode(data.toString());
              if (ev is Map<String, dynamic>) yield ev;
            } catch (_) {}
            data = StringBuffer();
          }
        }
      } on RunnerError catch (e) {
        if (e.signedOut) rethrow;
      } catch (_) {}
      await Future<void>.delayed(pause);
      pause = pause * 2 > const Duration(seconds: 60) ? const Duration(seconds: 60) : pause * 2;
    }
  }

  void close() => _http.close();
}
