// The three places on the phone: your agents, what waits for your yes, and
// what happened today. One live connection to the runner feeds all three.

import 'dart:async';

import 'package:flutter/material.dart';

import 'chat.dart';
import 'runner.dart';

class Home extends StatefulWidget {
  const Home({super.key, required this.runner, required this.onSignOut});
  final Runner runner;
  final Future<void> Function() onSignOut;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _tab = 0;
  List<Map<String, dynamic>> _agents = [];
  List<Map<String, dynamic>> _approvals = [];
  List<Map<String, dynamic>> _wakes = [];
  final List<Map<String, dynamic>> _news = [];
  String? _error;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  Runner get r => widget.runner;

  @override
  void initState() {
    super.initState();
    _refresh();
    _sub = r.events().listen(_onEvent, onError: (Object e) {
      if (e is RunnerError && e.signedOut) widget.onSignOut();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _events.close();
    r.close();
    super.dispose();
  }

  void _onEvent(Map<String, dynamic> ev) {
    _events.add(ev);
    switch (ev['kind']) {
      case 'asked':
      case 'answered':
        _loadApprovals();
      case 'job_started':
      case 'job_finished':
      case 'roster_changed':
        _loadAgents();
      case 'notice':
        setState(() {
          _news.insert(0, ev);
          if (_news.length > 50) _news.removeLast();
        });
    }
  }

  Future<void> _guard(Future<void> Function() f) async {
    try {
      await f();
      if (mounted && _error != null) setState(() => _error = null);
    } on RunnerError catch (e) {
      if (e.signedOut) return widget.onSignOut();
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _refresh() async {
    await Future.wait([_loadAgents(), _loadApprovals(), _loadWakes()]);
  }

  Future<void> _loadAgents() => _guard(() async {
        final rows = await r.call('list_agents') as List<dynamic>;
        final list = rows.cast<Map<String, dynamic>>().where((a) => a['hidden'] != true && a['shadow_of'] == null).toList();
        if (mounted) setState(() => _agents = list);
      });

  Future<void> _loadApprovals() => _guard(() async {
        final rows = await r.call('approvals') as List<dynamic>;
        if (mounted) setState(() => _approvals = rows.cast<Map<String, dynamic>>());
      });

  Future<void> _loadWakes() => _guard(() async {
        final w = await r.call('wakes') as Map<String, dynamic>;
        final list = (w['wakes'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
        if (mounted) setState(() => _wakes = list);
      });

  Future<void> _answer(String id, bool yes) => _guard(() async {
        await r.call('answer', {'id': id, 'yes': yes, 'by': 'phone'});
        await _loadApprovals();
      });

  Future<void> _label(String id, String label) => _guard(() async {
        await r.call('label_wake', {'id': id, 'label': label});
        await _loadWakes();
      });

  String _initial(String? name) => (name == null || name.trim().isEmpty) ? '?' : name.trim().characters.first.toUpperCase();

  String _name(String id) => (_agents.firstWhere((a) => a['id'] == id, orElse: () => {'name': 'An agent'})['name'] ?? 'An agent').toString();

  @override
  Widget build(BuildContext context) {
    final pages = [_agentsPage(), _approvalsPage(), _todayPage()];
    return Scaffold(
      appBar: AppBar(
        title: Text(['Agents', 'Waiting for you', 'Today'][_tab]),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'out') widget.onSignOut();
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'out', child: Text('Sign this phone out'))],
          ),
        ],
      ),
      body: Column(children: [
        if (_error != null)
          MaterialBanner(content: Text(_error!), actions: [TextButton(onPressed: _refresh, child: const Text('Try again'))]),
        Expanded(child: RefreshIndicator(onRefresh: _refresh, child: pages[_tab])),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: 'Agents'),
          NavigationDestination(
            icon: Badge(isLabelVisible: _approvals.isNotEmpty, label: Text('${_approvals.length}'), child: const Icon(Icons.check_circle_outline)),
            label: 'Waiting',
          ),
          const NavigationDestination(icon: Icon(Icons.wb_sunny_outlined), selectedIcon: Icon(Icons.wb_sunny), label: 'Today'),
        ],
      ),
    );
  }

  Widget _empty(String text) => ListView(children: [Padding(padding: const EdgeInsets.all(32), child: Text(text, textAlign: TextAlign.center))]);

  Widget _agentsPage() {
    if (_agents.isEmpty) return _empty('No agents yet. Hire one in Cookie on your computer.');
    return ListView.separated(
      itemCount: _agents.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (c, i) {
        final a = _agents[i];
        final unread = (a['unread'] as num?)?.toInt() ?? 0;
        final waiting = (a['waiting'] as num?)?.toInt() ?? 0;
        return ListTile(
          leading: CircleAvatar(child: Text(_initial(a['name'] as String?))),
          title: Text(a['name'] as String? ?? ''),
          subtitle: Text(
            a['busy'] == true ? 'Working…' : (a['last'] as String? ?? a['job'] as String? ?? ''),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: waiting > 0
              ? Badge(label: Text('$waiting'), child: const Icon(Icons.pan_tool_outlined))
              : unread > 0
                  ? Badge(label: Text('$unread'))
                  : null,
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => Chat(runner: r, agent: a, events: _events.stream))).then((_) => _loadAgents()),
        );
      },
    );
  }

  Widget _approvalsPage() {
    if (_approvals.isEmpty) return _empty('Nothing is waiting for you.');
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final a in _approvals)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${a['agent_name']} wants to ${a['tool']}', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SelectableText(a['preview'] as String? ?? ''),
                if ((a['from_data'] as List<dynamic>? ?? []).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Check these: they came from something it read, not from you: ${(a['from_data'] as List<dynamic>).join(', ')}',
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                if ((a['reason'] as String? ?? '').isNotEmpty) ...[const SizedBox(height: 8), Text(a['reason'] as String, style: Theme.of(context).textTheme.bodySmall)],
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton(onPressed: () => _answer(a['id'] as String, false), child: const Text('No')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: () => _answer(a['id'] as String, true), child: const Text('Yes')),
                ]),
              ]),
            ),
          ),
      ],
    );
  }

  Widget _todayPage() {
    final open = _wakes.where((w) => w['label'] == null).take(10).toList();
    if (open.isEmpty && _news.isEmpty) return _empty('A quiet day so far.');
    return ListView(padding: const EdgeInsets.all(12), children: [
      for (final w in open)
        Card(
          child: ListTile(
            title: Text('${_name(w['agent'] as String)} woke: ${w['title']}'),
            subtitle: Text(w['why'] as String? ?? ''),
            isThreeLine: true,
            trailing: PopupMenuButton<String>(
              onSelected: (v) => _label(w['id'] as String, v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'useful', child: Text('Useful')),
                PopupMenuItem(value: 'not_useful', child: Text('Not useful')),
                PopupMenuItem(value: 'wrong', child: Text('Wrong')),
              ],
            ),
          ),
        ),
      for (final n in _news)
        ListTile(
          leading: const Icon(Icons.notifications_none),
          title: Text(n['title'] as String? ?? ''),
          subtitle: Text(n['body'] as String? ?? '', maxLines: 3, overflow: TextOverflow.ellipsis),
        ),
    ]);
  }
}
