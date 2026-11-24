// A conversation with one agent: what was said, its answer as it writes it,
// and what you say next. While it works, what you send joins the job it is
// on (`steer`), as on the computer.

import 'dart:async';

import 'package:flutter/material.dart';

import 'runner.dart';

class Chat extends StatefulWidget {
  const Chat({super.key, required this.runner, required this.agent, required this.events});
  final Runner runner;
  final Map<String, dynamic> agent;
  final Stream<Map<String, dynamic>> events;
  @override
  State<Chat> createState() => _ChatState();
}

class _Msg {
  _Msg(this.from, this.text);
  final String from; // you · agent · file · talk · note
  String text;
}

class _ChatState extends State<Chat> {
  final List<_Msg> _lines = [];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _busy = false;
  String? _job;
  _Msg? _live;
  String? _error;

  String get id => widget.agent['id'] as String;
  Runner get r => widget.runner;

  @override
  void initState() {
    super.initState();
    _busy = widget.agent['busy'] == true;
    _load();
    _sub = widget.events.where((e) => e['agent'] == id).listen(_onEvent);
    r.call('mark_read', {'id': id}).catchError((_) => null);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final lines = await r.call('history', {'id': id}) as List<dynamic>;
      setState(() {
        _lines
          ..clear()
          ..addAll(lines.cast<Map<String, dynamic>>().where((l) => l['from'] != 'talk').map((l) => _Msg(l['from'] as String, l['text'] as String? ?? '')));
      });
      _toEnd();
    } on RunnerError catch (e) {
      setState(() => _error = e.message);
    }
  }

  void _onEvent(Map<String, dynamic> ev) {
    switch (ev['kind']) {
      case 'job_started':
        setState(() {
          _busy = true;
          _job = ev['job'] as String?;
          _live = null;
        });
      case 'text':
        if (ev['job'] != _job && _job != null) return;
        setState(() {
          if (_live == null) {
            _live = _Msg('agent', '');
            _lines.add(_live!);
          }
          _live!.text += ev['text'] as String? ?? '';
        });
        _toEnd();
      case 'tool':
        setState(() => _lines.add(_Msg('note', 'Using ${ev['name']}…')));
        _live = null;
        _toEnd();
      case 'asked':
        setState(() => _lines.add(_Msg('note', 'It is waiting for your yes (Waiting tab).')));
      case 'job_finished':
        setState(() {
          _busy = false;
          _job = null;
          _live = null;
          final err = ev['error'] as String?;
          if (ev['status'] == 'failed' && err != null && err.isNotEmpty) _lines.add(_Msg('note', "It couldn't finish: $err"));
        });
        // The answer as kept, with the tool notes gone.
        _load();
    }
  }

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    setState(() {
      _lines.add(_Msg('you', text));
      _error = null;
    });
    _toEnd();
    try {
      if (_busy) {
        await r.call('steer', {'id': id, 'text': text});
      } else {
        _job = await r.call('send', {'id': id, 'text': text}) as String?;
        setState(() => _busy = true);
      }
    } on RunnerError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _stop() async {
    try {
      await r.call('stop', {'id': id});
    } on RunnerError catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.agent['name'] as String? ?? ''),
          Text(_busy ? 'Working…' : (widget.agent['job'] as String? ?? ''), style: t.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
        actions: [if (_busy) IconButton(tooltip: 'Stop', onPressed: _stop, icon: const Icon(Icons.stop_circle_outlined))],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _lines.length,
              itemBuilder: (_, i) => _bubble(t, _lines[i]),
            ),
          ),
          if (_error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_error!, style: TextStyle(color: t.colorScheme.error))),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(hintText: _busy ? 'Add to what it is doing…' : 'Message ${widget.agent['name']}', border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24)))),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _send, icon: const Icon(Icons.arrow_upward)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _bubble(ThemeData t, _Msg m) {
    if (m.from == 'note') {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(m.text, textAlign: TextAlign.center, style: t.textTheme.bodySmall));
    }
    final mine = m.from == 'you';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine ? t.colorScheme.primaryContainer : (m.from == 'file' ? t.colorScheme.surfaceContainerHighest : t.colorScheme.surfaceContainer),
          borderRadius: BorderRadius.circular(18),
        ),
        child: SelectableText(m.from == 'file' ? '📎 ${m.text.split('\n').first}' : m.text),
      ),
    );
  }
}
