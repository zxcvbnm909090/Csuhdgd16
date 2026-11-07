import 'dart:convert';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

// رابط ملف القنوات (نفس channels.json المستخدم في نسخة HTML). غيّره إلى رابط موقعك.
const channelsUrl = 'https://mahmoudip.netlify.app/channels.json';

// ---------- النماذج ----------
class Source {
  final String q, u, t;
  Source(this.q, this.u, this.t);
  factory Source.fromJson(Map<String, dynamic> j) =>
      Source((j['q'] ?? '') as String, (j['u'] ?? '') as String, (j['t'] ?? 'hls') as String);
}

class Channel {
  final String name;
  final List<Source> sources;
  Channel(this.name, this.sources);
  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
        (j['name'] ?? '') as String,
        ((j['sources'] ?? []) as List).map((s) => Source.fromJson(s as Map<String, dynamic>)).toList(),
      );
}

class Group {
  final String name;
  final List<Channel> channels;
  Group(this.name, this.channels);
  factory Group.fromJson(Map<String, dynamic> j) => Group(
        (j['name'] ?? '') as String,
        ((j['channels'] ?? []) as List).map((c) => Channel.fromJson(c as Map<String, dynamic>)).toList(),
      );
}

Future<List<Group>> loadGroups() async {
  final url = '$channelsUrl?t=${DateTime.now().millisecondsSinceEpoch}';
  final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  return ((d['groups'] ?? []) as List).map((g) => Group.fromJson(g as Map<String, dynamic>)).toList();
}

// ---------- التطبيق ----------
void main() => runApp(const App());

class App extends StatefulWidget {
  const App({super.key});
  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  ThemeMode mode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString('theme');
    if (s != null && mounted) setState(() => mode = s == 'dark' ? ThemeMode.dark : ThemeMode.light);
  }

  Future<void> _toggle(bool isDark) async {
    final next = isDark ? 'light' : 'dark';
    setState(() => mode = isDark ? ThemeMode.light : ThemeMode.dark);
    final p = await SharedPreferences.getInstance();
    await p.setString('theme', next);
  }

  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F7A3D), brightness: b),
        appBarTheme: AppBarTheme(
          backgroundColor: b == Brightness.dark ? const Color(0xFF0E2A1D) : const Color(0xFF0B5A2E),
          foregroundColor: Colors.white,
        ),
      );

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'بث محمود',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: mode,
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: HomeScreen(onToggleTheme: _toggle),
      );
}

// ---------- عناصر مشتركة ----------
Color _color(String n) =>
    HSLColor.fromAHSL(1, n.codeUnits.fold<int>(0, (h, c) => (h * 31 + c) % 360).toDouble(), .45, .36).toColor();

class Tile extends StatelessWidget {
  final String name;
  final String? trailing;
  final VoidCallback onTap;
  const Tile({super.key, required this.name, this.trailing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final base = name.replaceFirst(RegExp(r'^ال'), '');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: _color(name),
          child: Text(base.isEmpty ? '?' : base[0],
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w500)),
        trailing: trailing == null ? null : Text(trailing!),
        onTap: onTap,
      ),
    );
  }
}

Widget _msg(String t) => ListView(children: [
      Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(t, textAlign: TextAlign.center)))
    ]);

void _openChannel(BuildContext c, Channel ch) =>
    Navigator.push(c, MaterialPageRoute(builder: (_) => PlayerScreen(channel: ch)));

// ---------- الشاشة الرئيسية ----------
class HomeScreen extends StatefulWidget {
  final void Function(bool isDark) onToggleTheme;
  const HomeScreen({super.key, required this.onToggleTheme});
  @override
  State<HomeScreen> createState() => _HomeState();
}

class _HomeState extends State<HomeScreen> {
  late Future<List<Group>> _f = loadGroups();
  bool _searching = false;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.white,
                decoration: const InputDecoration(
                    hintText: 'ابحث عن قناة', hintStyle: TextStyle(color: Colors.white70), border: InputBorder.none),
                onChanged: (v) => setState(() => _q = v.trim()),
              )
            : const Text('بث محمود'),
        actions: [
          IconButton(
            tooltip: 'بحث',
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              _q = '';
            }),
          ),
          IconButton(
            tooltip: 'الوضع الليلي',
            icon: Icon(dark ? Icons.light_mode : Icons.dark_mode),
            onPressed: () => widget.onToggleTheme(dark),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          final f = loadGroups();
          setState(() => _f = f);
          await f.catchError((_) => <Group>[]);
        },
        child: FutureBuilder<List<Group>>(
          future: _f,
          builder: (c, s) {
            if (s.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (s.hasError) return _msg('تعذّر تحميل القنوات. اسحب للأسفل لإعادة المحاولة.');
            final groups = s.data!;
            if (_q.isNotEmpty) {
              final hits = <Widget>[];
              for (final g in groups) {
                for (final ch in g.channels) {
                  if (ch.name.contains(_q)) {
                    hits.add(Tile(name: ch.name, trailing: g.name, onTap: () => _openChannel(context, ch)));
                  }
                }
              }
              return hits.isEmpty ? _msg('لا توجد نتائج.') : ListView(padding: const EdgeInsets.all(12), children: hits);
            }
            if (groups.isEmpty) return _msg('لا توجد قنوات بعد.');
            return ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final g in groups)
                  Tile(
                    name: g.name,
                    trailing: '${g.channels.length}',
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => GroupScreen(group: g))),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------- شاشة القسم ----------
class GroupScreen extends StatelessWidget {
  final Group group;
  const GroupScreen({super.key, required this.group});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(group.name)),
        body: group.channels.isEmpty
            ? _msg('لا توجد قنوات في هذا القسم.')
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final ch in group.channels)
                    Tile(name: ch.name, onTap: () => _openChannel(context, ch)),
                ],
              ),
      );
}

// ---------- شاشة المشغّل ----------
class PlayerScreen extends StatefulWidget {
  final Channel channel;
  const PlayerScreen({super.key, required this.channel});
  @override
  State<PlayerScreen> createState() => _PlayerState();
}

class _PlayerState extends State<PlayerScreen> {
  int _i = 0, _tok = 0;
  VideoPlayerController? _vc;
  ChewieController? _cc;
  WebViewController? _wv;
  bool _err = false, _busy = true;

  @override
  void initState() {
    super.initState();
    if (widget.channel.sources.isEmpty) {
      _err = true;
      _busy = false;
    } else {
      Future.microtask(() {
        if (mounted) _open(0);
      });
    }
  }

  @override
  void dispose() {
    _tok++;
    _free();
    super.dispose();
  }

  void _free() {
    _cc?.dispose();
    _vc?.dispose();
    _cc = null;
    _vc = null;
  }

  Future<void> _open(int i) async {
    final tok = ++_tok;
    _free();
    setState(() {
      _i = i;
      _err = false;
      _busy = true;
      _wv = null;
    });
    final s = widget.channel.sources[i];
    if (s.t == 'iframe') {
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..loadRequest(Uri.parse(s.u));
      setState(() {
        _wv = c;
        _busy = false;
      });
      return;
    }
    try {
      final vc = VideoPlayerController.networkUrl(Uri.parse(s.u));
      await vc.initialize();
      if (!mounted || tok != _tok) {
        await vc.dispose();
        return;
      }
      final cc = ChewieController(
        videoPlayerController: vc,
        autoPlay: true,
        isLive: true,
        allowedScreenSleep: false,
        aspectRatio: vc.value.aspectRatio == 0 ? 16 / 9 : vc.value.aspectRatio,
      );
      setState(() {
        _vc = vc;
        _cc = cc;
        _busy = false;
      });
    } catch (_) {
      if (mounted && tok == _tok) {
        setState(() {
          _err = true;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ch = widget.channel;
    Widget body;
    if (_busy) {
      body = const Center(child: CircularProgressIndicator(color: Colors.white));
    } else if (_err) {
      body = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('تعذّر تشغيل هذا البث', style: TextStyle(color: Colors.white)),
          const SizedBox(height: 10),
          if (ch.sources.isNotEmpty) FilledButton(onPressed: () => _open(_i), child: const Text('إعادة المحاولة')),
        ]),
      );
    } else if (_wv != null) {
      body = WebViewWidget(controller: _wv!);
    } else {
      body = Chewie(controller: _cc!);
    }
    return Scaffold(
      appBar: AppBar(title: Text(ch.name)),
      body: Column(children: [
        AspectRatio(aspectRatio: 16 / 9, child: Container(color: Colors.black, child: body)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Wrap(spacing: 8, children: [
              for (var k = 0; k < ch.sources.length; k++)
                ChoiceChip(
                  label: Text(ch.sources[k].q.isEmpty ? 'بث ${k + 1}' : ch.sources[k].q),
                  selected: k == _i,
                  onSelected: (_) => _open(k),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}
