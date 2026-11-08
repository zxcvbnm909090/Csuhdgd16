import 'dart:convert';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unity_ads_plugin/unity_ads_plugin.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

// رابط ملف القنوات (نفس channels.json المستخدم في نسخة HTML). غيّره إلى رابط موقعك.
const channelsUrl = 'https://raw.githubusercontent.com/zxcvbnm909090/Csuhdgd16/main/channels.json';

// إعدادات Unity Ads: ضع Game ID الخاص بأندرويد من لوحة Unity، ومعرّف مكان البانر (Placement ID).
// unityTestMode = true يعرض إعلانات اختبار فقط. اجعله false عند النشر النهائي.
const unityGameId = '800428580';
const unityBannerId = 'BP_Banner_Android';
const unityInterstitialId = 'BP_Interstitial_Android';
const unityTestMode = false;

// ---------- إعدادات عامة ----------
const repo = 'zxcvbnm909090/Csuhdgd16';
const apkUrl = 'https://github.com/$repo/releases/latest/download/app-release.apk';
const appBuild = int.fromEnvironment('BUILD', defaultValue: 0); // يضبطه ملف البناء تلقائياً
const sportsKey = '123'; // مفتاح TheSportsDB المجاني
const newsUrl = 'https://feeds.bbci.co.uk/sport/football/rss.xml'; // خلاصة أخبار RSS (قابلة للتغيير)
const leagues = {
  '4328': 'الدوري الإنجليزي',
  '4335': 'الدوري الإسباني',
  '4332': 'الدوري الإيطالي',
  '4331': 'الدوري الألماني',
  '4334': 'الدوري الفرنسي',
  '4480': 'دوري أبطال أوروبا',
};

// ---------- النماذج ----------
class Source {
  final String q, u, t;
  Source(this.q, this.u, this.t);
  factory Source.fromJson(Map<String, dynamic> j) =>
      Source((j['q'] ?? '') as String, (j['u'] ?? '') as String, (j['t'] ?? 'hls') as String);
}

class Channel {
  final String name, logo;
  final List<Source> sources;
  Channel(this.name, this.logo, this.sources);
  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
        (j['name'] ?? '') as String,
        (j['logo'] ?? '') as String,
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

// ---------- تنبيه التحديث: يقارن رقم البناء بآخر Release على GitHub ----------
Future<bool> hasUpdate() async {
  if (appBuild == 0) return false;
  try {
    final r = await http
        .get(Uri.parse('https://api.github.com/repos/$repo/releases/latest'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return false;
    final tag = ((jsonDecode(r.body) as Map<String, dynamic>)['tag_name'] ?? '') as String;
    return (int.tryParse(tag.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0) > appBuild;
  } catch (_) {
    return false;
  }
}

// ---------- المباريات (TheSportsDB) ----------
class Fixture {
  final String league, home, away;
  final DateTime t;
  final String? score;
  Fixture(this.league, this.home, this.away, this.t, this.score);
}

Future<List<Fixture>> loadMatches(bool past) async {
  final kind = past ? 'eventspastleague' : 'eventsnextleague';
  final parts = await Future.wait(leagues.entries.map((e) async {
    try {
      final r = await http
          .get(Uri.parse('https://www.thesportsdb.com/api/v1/json/$sportsKey/$kind.php?id=${e.key}'))
          .timeout(const Duration(seconds: 15));
      final d = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      return ((d['events'] ?? []) as List).map((x) {
        final v = x as Map<String, dynamic>;
        final t = DateTime.tryParse("${v['dateEvent']}T${v['strTime'] ?? '00:00:00'}Z")?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final hs = v['intHomeScore'], aw = v['intAwayScore'];
        return Fixture(e.value, (v['strHomeTeam'] ?? '') as String, (v['strAwayTeam'] ?? '') as String, t,
            past && hs != null && aw != null ? '$hs - $aw' : null);
      }).toList();
    } catch (_) {
      return <Fixture>[];
    }
  }));
  final all = parts.expand((x) => x).toList()
    ..sort((a, b) => past ? b.t.compareTo(a.t) : a.t.compareTo(b.t));
  return all;
}

String fmt(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}/${two(t.month)}  ${two(t.hour)}:${two(t.minute)}';
}

// ---------- الأخبار (RSS: عناوين وروابط فقط) ----------
class NewsItem {
  final String title, link;
  NewsItem(this.title, this.link);
}

Future<List<NewsItem>> loadNews() async {
  try {
    final r = await http.get(Uri.parse(newsUrl)).timeout(const Duration(seconds: 15));
    final body = utf8.decode(r.bodyBytes);
    String clean(String s) => s
        .replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&#39;', "'")
        .replaceAll('&quot;', '"')
        .trim();
    return RegExp(r'<item>(.*?)</item>', dotAll: true)
        .allMatches(body)
        .map((m) {
          final b = m.group(1)!;
          final t = RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(b)?.group(1) ?? '';
          final l = RegExp(r'<link>(.*?)</link>', dotAll: true).firstMatch(b)?.group(1) ?? '';
          return NewsItem(clean(t), clean(l));
        })
        .where((n) => n.title.isNotEmpty && n.link.startsWith('http'))
        .take(30)
        .toList();
  } catch (_) {
    return <NewsItem>[];
  }
}

// ---------- التطبيق ----------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  UnityAds.init(
    gameId: unityGameId,
    testMode: unityTestMode,
    onComplete: InterstitialGate.preload,
    onFailed: (error, message) => debugPrint('Unity init failed: $error $message'),
  );
  runApp(const App());
}

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

// ---------- إعلان بانر (Unity Ads) ----------
class BannerAdBox extends StatelessWidget {
  const BannerAdBox({super.key});

  @override
  Widget build(BuildContext context) => UnityBannerAd(
        placementId: unityBannerId,
        onFailed: (id, error, message) => debugPrint('Banner failed: $error $message'),
      );
}

// ---------- إعلان بيني (قبل فتح القناة) ----------
class InterstitialGate {
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _loaded = false;
  static const gap = Duration(minutes: 4); // أقل فاصل بين إعلانين

  static void preload() {
    UnityAds.load(
      placementId: unityInterstitialId,
      onComplete: (_) => _loaded = true,
      onFailed: (id, error, message) => _loaded = false,
    );
  }

  /// يعرض الإعلان إن كان جاهزاً ومرّ الفاصل الزمني، ثم يفتح القناة دائماً.
  static void showThen(VoidCallback then) {
    final ready = _loaded && DateTime.now().difference(_last) >= gap;
    if (!ready) {
      then();
      return;
    }
    _loaded = false;
    _last = DateTime.now();
    var done = false;
    void go() {
      if (done) return;
      done = true;
      preload();
      then();
    }

    UnityAds.showVideoAd(
      placementId: unityInterstitialId,
      onComplete: (_) => go(),
      onSkipped: (_) => go(),
      onFailed: (id, error, message) => go(),
    );
  }
}

// ---------- عناصر مشتركة ----------
Color _color(String n) =>
    HSLColor.fromAHSL(1, n.codeUnits.fold<int>(0, (h, c) => (h * 31 + c) % 360).toDouble(), .45, .36).toColor();

Widget _msg(String t) => ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
      Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(t, textAlign: TextAlign.center)))
    ]);

void _openChannel(BuildContext c, Channel ch) => InterstitialGate.showThen(() {
      if (c.mounted) {
        Navigator.push(c, MaterialPageRoute(builder: (_) => PlayerScreen(channel: ch)));
      }
    });

class Logo extends StatelessWidget {
  final String name, logo;
  final double size;
  const Logo(this.name, this.logo, {super.key, this.size = 56});

  @override
  Widget build(BuildContext context) {
    final base = name.replaceFirst(RegExp(r'^ال'), '');
    final fb = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: _color(name), borderRadius: BorderRadius.circular(size / 3)),
      child: Text(base.isEmpty ? '?' : base[0].toUpperCase(),
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: size / 2.4)),
    );
    if (logo.isEmpty) return fb;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 3),
      child: Image.network(logo, width: size, height: size, fit: BoxFit.contain, errorBuilder: (_, __, ___) => fb),
    );
  }
}

class ChannelCard extends StatelessWidget {
  final Channel ch;
  final double? w;
  const ChannelCard(this.ch, {super.key, this.w});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: w,
        child: Card(
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _openChannel(context, ch),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Logo(ch.name, ch.logo, size: 64),
                const SizedBox(height: 6),
                Text(ch.name,
                    maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
              ]),
            ),
          ),
        ),
      );
}

Widget channelGrid(List<Channel> list) => GridView.count(
      physics: const AlwaysScrollableScrollPhysics(),
      crossAxisCount: 3,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: .85,
      padding: const EdgeInsets.all(12),
      children: [for (final c in list) ChannelCard(c)],
    );

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
  void initState() {
    super.initState();
    hasUpdate().then((yes) {
      if (yes && mounted) _showUpdate();
    });
  }

  void _showUpdate() => showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('يوجد تحديث جديد'),
          content: const Text('نسخة أحدث من التطبيق متاحة. حدّث الآن للحصول على آخر المزايا.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('لاحقاً')),
            FilledButton(
              onPressed: () {
                launchUrl(Uri.parse(apkUrl), mode: LaunchMode.externalApplication);
                Navigator.pop(c);
              },
              child: const Text('تحديث الآن'),
            ),
          ],
        ),
      );

  void _push(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));

  Widget _banner(Channel ch) => Padding(
        padding: const EdgeInsets.all(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _openChannel(context, ch),
          child: Container(
            height: 140,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                  colors: [Color(0xFF0F7A3D), Color(0xFF0B3D24)], begin: Alignment.topRight, end: Alignment.bottomLeft),
            ),
            child: Row(children: [
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(20)),
                    child: const Text('قناة مميزة', style: TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                  const SizedBox(height: 8),
                  Text(ch.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('اضغط للمشاهدة', style: TextStyle(color: Colors.white70)),
                ]),
              ),
              Logo(ch.name, ch.logo, size: 72),
            ]),
          ),
        ),
      );

  Widget _quick() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          Expanded(
            child: FilledButton.tonalIcon(
                onPressed: () => _push(const MatchesScreen()),
                icon: const Icon(Icons.sports_soccer),
                label: const Text('المباريات')),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.tonalIcon(
                onPressed: () => _push(const NewsScreen()), icon: const Icon(Icons.newspaper), label: const Text('الأخبار')),
          ),
        ]),
      );

  Widget _section(Group g) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
          child: Row(children: [
            Expanded(child: Text(g.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
            TextButton(onPressed: () => _push(GroupScreen(group: g)), child: const Text('عرض الكل')),
          ]),
        ),
        SizedBox(
          height: 128,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: g.channels.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (c, i) => ChannelCard(g.channels[i], w: 96),
          ),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      bottomNavigationBar: const SafeArea(child: BannerAdBox()),
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
            final all = groups.expand((g) => g.channels).toList();
            if (_q.isNotEmpty) {
              final hits = all.where((ch) => ch.name.toLowerCase().contains(_q.toLowerCase())).toList();
              return hits.isEmpty ? _msg('لا توجد نتائج.') : channelGrid(hits);
            }
            if (all.isEmpty) return _msg('لا توجد قنوات بعد.');
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                _banner(all.first),
                _quick(),
                for (final g in groups.where((g) => g.channels.isNotEmpty)) _section(g),
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
        bottomNavigationBar: const SafeArea(child: BannerAdBox()),
        appBar: AppBar(title: Text(group.name)),
        body: group.channels.isEmpty ? _msg('لا توجد قنوات في هذا القسم.') : channelGrid(group.channels),
      );
}

// ---------- المباريات ----------
class MatchesScreen extends StatelessWidget {
  const MatchesScreen({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          bottomNavigationBar: const SafeArea(child: BannerAdBox()),
          appBar: AppBar(
            title: const Text('المباريات'),
            bottom: const TabBar(
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              indicatorColor: Colors.white,
              tabs: [Tab(text: 'القادمة'), Tab(text: 'النتائج')],
            ),
          ),
          body: const TabBarView(children: [MatchList(past: false), MatchList(past: true)]),
        ),
      );
}

class MatchList extends StatefulWidget {
  final bool past;
  const MatchList({super.key, required this.past});
  @override
  State<MatchList> createState() => _MatchListState();
}

class _MatchListState extends State<MatchList> with AutomaticKeepAliveClientMixin {
  late Future<List<Fixture>> _f = loadMatches(widget.past);

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RefreshIndicator(
      onRefresh: () async {
        final f = loadMatches(widget.past);
        setState(() => _f = f);
        await f;
      },
      child: FutureBuilder<List<Fixture>>(
        future: _f,
        builder: (c, s) {
          if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          final list = s.data ?? [];
          if (list.isEmpty) return _msg('تعذّر تحميل المباريات الآن. اسحب للأسفل لإعادة المحاولة.');
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(12),
            children: [
              for (final m in list)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text('${m.home}  ×  ${m.away}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${m.league}  ·  ${fmt(m.t)}'),
                    trailing: m.score == null
                        ? null
                        : Text(m.score!, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ---------- الأخبار ----------
class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key});
  @override
  State<NewsScreen> createState() => _NewsState();
}

class _NewsState extends State<NewsScreen> {
  late Future<List<NewsItem>> _f = loadNews();

  @override
  Widget build(BuildContext context) => Scaffold(
        bottomNavigationBar: const SafeArea(child: BannerAdBox()),
        appBar: AppBar(title: const Text('الأخبار')),
        body: RefreshIndicator(
          onRefresh: () async {
            final f = loadNews();
            setState(() => _f = f);
            await f;
          },
          child: FutureBuilder<List<NewsItem>>(
            future: _f,
            builder: (c, s) {
              if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
              final list = s.data ?? [];
              if (list.isEmpty) return _msg('تعذّر تحميل الأخبار الآن. اسحب للأسفل لإعادة المحاولة.');
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                children: [
                  for (final n in list)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text(n.title, maxLines: 3, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.open_in_new, size: 18),
                        onTap: () => launchUrl(Uri.parse(n.link), mode: LaunchMode.externalApplication),
                      ),
                    ),
                ],
              );
            },
          ),
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
      bottomNavigationBar: const SafeArea(child: BannerAdBox()),
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
