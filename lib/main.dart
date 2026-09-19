import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── GLOBAL NAV KEY (needed for notification deep-links) ─────────────────────

final _navKey = GlobalKey<NavigatorState>();

// ─── NOTIFICATIONS ───────────────────────────────────────────────────────────

final _notif = FlutterLocalNotificationsPlugin();
int _notifId  = 0;

// Global threshold — AccountTab writes this; background checker reads it
double globalAlertThreshold = 5.0;

// Session counters for Account tab stats
int sessionEdgesFound     = 0;
int sessionAlertsTriggered = 0;

// Last successful odds fetch time
DateTime? lastUpdated;

Future<void> initNotifications() async {
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _notif.initialize(
    const InitializationSettings(android: android),
    onDidReceiveNotificationResponse: (details) {
      final payload = details.payload;
      if (payload == null) return;
      final parts = payload.split('|');
      if (parts.length < 2) return;
      final home = parts[0]; final away = parts[1];
      final match = allMatches.firstWhere(
        (m) => m['home'] == home && m['away'] == away,
        orElse: () => <String, dynamic>{},
      );
      if (match.isEmpty) return;
      _navKey.currentState?.push(MaterialPageRoute(
        builder: (_) => MatchDetailScreen(match: match),
      ));
    },
  );
  // Permission is requested after the user has seen the home screen,
  // not immediately on launch.
}

Future<void> requestNotificationPermission() async {
  await _notif
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

Future<void> sendEdgeNotification({
  required String match,
  required String market,
  required int edge,
  String payload = '',
}) async {
  const channel = AndroidNotificationDetails(
    'edge_alerts', 'Edge Alerts',
    channelDescription: 'Notifications when model edge exceeds your threshold',
    importance: Importance.high,
    priority: Priority.high,
    color: Color(0xFF00C853),
  );
  await _notif.show(
    _notifId++,
    '⚡ +$edge% Edge Found',
    '$market — $match',
    const NotificationDetails(android: channel),
    payload: payload,
  );
  sessionAlertsTriggered++;
}

// Tracks which edges we've already notified about this session to avoid spam
final Set<String> _notifiedEdges = {};

// Called periodically and after each live refresh
Future<void> checkEdgeAlerts(double threshold) async {
  final edges = computeAllEdges();
  sessionEdgesFound = edges.where((e) => (e['edge'] as int) >= threshold.round()).length;
  for (final e in edges) {
    final edgePct = e['edge'] as int;
    if (edgePct < threshold) continue;
    final key = '${e['match']}_${e['market']}_$edgePct';
    if (_notifiedEdges.contains(key)) continue;
    _notifiedEdges.add(key);
    // Build payload "home|away" for notification deep-link
    final matchMap   = e['match'] as Map<String, dynamic>;
    final matchTitle = '${matchMap['home']} vs ${matchMap['away']}';
    final parts = matchTitle.split(' vs ');
    final payload = parts.length == 2 ? '${parts[0]}|${parts[1]}' : '';
    await sendEdgeNotification(
      match:   matchTitle,
      market:  e['market'] as String,
      edge:    edgePct,
      payload: payload,
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();
  runApp(const OddsVisionApp());
}

// Whether the user has seen the edge onboarding
bool _hasSeenOnboarding = false;

class OddsVisionApp extends StatelessWidget {
  const OddsVisionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OddsVision',
      navigatorKey: _navKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
        primaryColor: const Color(0xFF00C853),
      ),
      home: _hasSeenOnboarding ? const MainScreen() : const OnboardingScreen(),
    );
  }
}

// ─── ONBOARDING ──────────────────────────────────────────────────────────────

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _page = PageController();
  int _current = 0;

  static const _pages = [
    _OnboardPage(
      emoji: '⚡',
      title: 'What is an edge?',
      body:
          'An edge is where our statistical model estimates a different probability to the bookmaker.\n\n'
          'Bookmakers bake in a profit margin — so their odds never reflect the true probability. When there\'s a gap, that\'s your edge.',
      highlight: 'Edges signal a potential disagreement — they don\'t guarantee outcomes.',
    ),
    _OnboardPage(
      emoji: '🧠',
      title: 'How we find them',
      body:
          'We pull live odds from multiple bookmakers and strip out their margin to calculate the true probability of each outcome.\n\n'
          'Our model compares that against its own probability estimate. If the model rates Arsenal\'s win chance at 58% but the bookmakers are only pricing it at 51%, you have a +7% edge.',
      highlight: 'No gut feel. Just the numbers.',
    ),
    _OnboardPage(
      emoji: '🔔',
      title: 'Set your alerts',
      body:
          'Head to the Account tab and use the slider to choose your minimum edge threshold.\n\n'
          'We\'ll send you a notification the moment any bet crosses it — so you can review high-edge matches as they appear.',
      highlight: 'Start at +5% and adjust from there.',
    ),
  ];

  void _next(BuildContext ctx) {
    if (_current < _pages.length - 1) {
      _page.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
    } else {
      _hasSeenOnboarding = true;
      Navigator.of(ctx).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(children: [
          // Skip button
          Align(
            alignment: Alignment.topRight,
            child: TextButton(
              onPressed: () {
                _hasSeenOnboarding = true;
                Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const MainScreen()));
              },
              child: Text('Skip', style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
            ),
          ),
          // Pages
          Expanded(
            child: PageView.builder(
              controller: _page,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _current = i),
              itemBuilder: (_, i) => _pages[i],
            ),
          ),
          // Dots + button
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: List.generate(
                _pages.length,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _current == i ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _current == i ? kGreen : Colors.grey.shade800,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              )),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => _next(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kGreen,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    _current == _pages.length - 1 ? 'Get started' : 'Next',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _OnboardPage extends StatelessWidget {
  final String emoji, title, body, highlight;
  const _OnboardPage({required this.emoji, required this.title, required this.body, required this.highlight});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 28),
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 96, height: 96,
        decoration: BoxDecoration(
          color: kGreen.withOpacity(0.1),
          shape: BoxShape.circle,
          border: Border.all(color: kGreen.withOpacity(0.3), width: 2),
        ),
        child: Center(child: Text(emoji, style: const TextStyle(fontSize: 44))),
      ),
      const SizedBox(height: 32),
      Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800),
          textAlign: TextAlign.center),
      const SizedBox(height: 20),
      Text(body,
          style: TextStyle(color: Colors.grey.shade400, fontSize: 15, height: 1.6),
          textAlign: TextAlign.center),
      const SizedBox(height: 24),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: kGreen.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kGreen.withOpacity(0.25)),
        ),
        child: Text(highlight,
            style: const TextStyle(color: kGreen, fontSize: 14, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center),
      ),
    ]),
  );
}

// Quick edge explainer bottom sheet — callable from anywhere
void showEdgeExplainer(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: kCard,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4,
            decoration: BoxDecoration(color: Colors.grey.shade700, borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 20),
        const Row(children: [
          Text('⚡', style: TextStyle(fontSize: 22)),
          SizedBox(width: 10),
          Text('What does edge mean?',
              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 14),
        Text(
          'Edge is the gap between our model\'s estimated probability and the bookmaker\'s implied probability.',
          style: TextStyle(color: Colors.grey.shade300, fontSize: 14, height: 1.6),
        ),
        const SizedBox(height: 12),
        _explainerRow('+5% edge', 'Model: 55% · Bookmaker: 50%', kGreen),
        _explainerRow('+8% edge', 'Model: 60% · Bookmaker: 52% — stronger disagreement', const Color(0xFFFFD700)),
        _explainerRow('0% edge', 'Fairly priced — no advantage', Colors.grey),
        const SizedBox(height: 16),
        Text(
          'The bigger the edge, the larger the model\'s disagreement with the market — but edges can still lose.',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 13, height: 1.5),
        ),
      ]),
    ),
  );
}

Widget _explainerRow(String label, String sub, Color color) => Padding(
  padding: const EdgeInsets.only(bottom: 10),
  child: Row(children: [
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
    ),
    const SizedBox(width: 12),
    Expanded(child: Text(sub, style: TextStyle(color: Colors.grey.shade400, fontSize: 13))),
  ]),
);

// ─── COLOURS ─────────────────────────────────────────────────────────────────
const kBg      = Color(0xFF0D0D0D);
const kCard    = Color(0xFF1A1A1A);
const kGreen   = Color(0xFF00C853);
const kBlue    = Color(0xFF2196F3);
const kOrange  = Colors.orange;

// ─── BOOKMAKER URLS ──────────────────────────────────────────────────────────

const _bookmakerUrls = <String, String>{
  'Bet365':       'https://www.bet365.com',
  'Betfair':      'https://www.betfair.com',
  'William Hill': 'https://www.williamhill.com',
  'Paddy Power':  'https://www.paddypower.com',
  'Betway':       'https://www.betway.com',
  'Sky Bet':      'https://m.skybet.com',
  'Unibet':       'https://www.unibet.co.uk',
  'Coral':        'https://www.coral.co.uk',
  'Ladbrokes':    'https://www.ladbrokes.com',
};

Future<void> launchBookmaker(BuildContext context, String name) async {
  final url = _bookmakerUrls[name] ?? 'https://www.google.com/search?q=$name+betting';
  final uri = Uri.parse(url);
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } else if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open $name'), backgroundColor: Colors.red.shade800),
    );
  }
}

// ─── ODDS MOVEMENT ───────────────────────────────────────────────────────────

// Snapshot of previous bookie percentages keyed by "home_away"
final Map<String, Map<String, int>> _oddsSnapshot = {};

void snapshotOdds() {
  for (final m in allMatches) {
    final key = '${m['home']}_${m['away']}';
    _oddsSnapshot[key] = {
      'home': (m['bookieHomePct'] as int?) ?? 0,
      'draw': (m['bookieDrawPct'] as int?) ?? 0,
      'away': (m['bookieAwayPct'] as int?) ?? 0,
    };
  }
}

// Returns 1 (up), -1 (down), or 0 (unchanged) for home win odds movement
int oddsMovement(Map<String, dynamic> match, String outcome) {
  final key   = '${match['home']}_${match['away']}';
  final prev  = _oddsSnapshot[key];
  if (prev == null) return 0;
  final nowPct  = (match['bookieHomePct'] as int?) ?? 0;
  final prevPct = prev['home'] ?? 0;
  if (outcome == 'home') {
    final now = (match['bookieHomePct'] as int?) ?? 0;
    final old = prev['home'] ?? 0;
    if (now > old + 1) return 1;
    if (now < old - 1) return -1;
  } else if (outcome == 'away') {
    final now = (match['bookieAwayPct'] as int?) ?? 0;
    final old = prev['away'] ?? 0;
    if (now > old + 1) return 1;
    if (now < old - 1) return -1;
  }
  return 0;
}

Widget movementArrow(int direction) {
  if (direction == 0) return const SizedBox.shrink();
  final up = direction > 0;
  return Icon(
    up ? Icons.trending_up : Icons.trending_down,
    color: up ? kGreen : Colors.red,
    size: 14,
  );
}

// ─── AI CONFIDENCE ───────────────────────────────────────────────────────────

Map<String, dynamic> aiConfidence(Map<String, dynamic> match) {
  final bkms   = (match['bookmakers'] as List?)?.length ?? 0;
  final home   = (match['homePct']       as int);
  final bkHome = (match['bookieHomePct'] as int?) ?? home;
  final edge   = (home - bkHome).abs();

  if (bkms >= 2 && edge >= 4) return {'label': 'High',   'color': kGreen};
  if (bkms >= 1 && edge >= 2) return {'label': 'Medium', 'color': kOrange};
  return                              {'label': 'Low',    'color': Colors.grey};
}

Widget confidenceBadge(Map<String, dynamic> match) {
  final c     = aiConfidence(match);
  final label = c['label'] as String;
  final color = c['color'] as Color;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: (color as Color).withOpacity(0.12),
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: color.withOpacity(0.35)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.psychology_outlined, color: color, size: 11),
      const SizedBox(width: 4),
      Text('$label confidence',
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    ]),
  );
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────

String updatedAgo() {
  if (lastUpdated == null) return 'Updating...';
  final diff = DateTime.now().difference(lastUpdated!);
  if (diff.inSeconds < 60) return 'Updated just now';
  if (diff.inMinutes < 60) return 'Updated ${diff.inMinutes}m ago';
  return 'Updated ${diff.inHours}h ago';
}

String kickoffCountdown(String timeStr) {
  final now = DateTime.now();
  DateTime? target;
  try {
    final parts = timeStr.split(' ');
    // formats: "Today 17:30", "Tomorrow 15:00", "Sat 22:00", "Sun 21:00"
    // also "Today 14:15 — Ascot" (racing — strip suffix)
    final dayPart  = parts[0];
    final timePart = parts.length > 1 ? parts[1].split('—')[0].trim() : '';
    if (timePart.isEmpty || !timePart.contains(':')) return timeStr;
    final hm     = timePart.split(':');
    final hour   = int.parse(hm[0]);
    final minute = int.parse(hm[1]);
    if (dayPart == 'Today') {
      target = DateTime(now.year, now.month, now.day, hour, minute);
    } else if (dayPart == 'Tomorrow') {
      target = DateTime(now.year, now.month, now.day + 1, hour, minute);
    } else {
      // named weekday — just show the original
      return timeStr;
    }
    final diff = target.difference(now);
    if (diff.isNegative) return 'Starting soon';
    if (diff.inMinutes < 60) return 'Kicks off in ${diff.inMinutes}m';
    final h = diff.inHours;
    final m = diff.inMinutes % 60;
    return m == 0 ? 'Kicks off in ${h}h' : 'Kicks off in ${h}h ${m}m';
  } catch (_) {
    return timeStr;
  }
}

int valueEdge(int aiPct, int bookiePct) => aiPct - bookiePct;

// Deterministic simulated bookie pct for markets without real bookie data.
// Uses label hash so same button always shows same edge — range roughly -5 to +10.
int _simBookiePct(String label, int aiPct) {
  final h = label.codeUnits.fold(0, (a, b) => a + b);
  final offset = (h % 16) - 5;
  return (aiPct - offset).clamp(1, 99);
}

// Convert implied probability % to decimal odds string.
String pctToDecimalOdds(int pct) {
  if (pct <= 0) return '—';
  return (100 / pct).toStringAsFixed(2);
}

// ─── POISSON SUB-MARKET CALCULATOR ──────────────────────────────────────────

// Returns football sub-market probabilities derived from Poisson xG values.
Map<String, int> _subMarkets(double homeXg, double awayXg) {
  final lambda = homeXg + awayXg;
  final btts   = (1 - exp(-homeXg)) * (1 - exp(-awayXg));
  final over25 = 1 - exp(-lambda) * (1 + lambda + lambda * lambda / 2);
  final over15 = 1 - exp(-lambda) * (1 + lambda);
  final csHome = exp(-awayXg);  // away scores 0
  final csAway = exp(-homeXg);  // home scores 0
  return {
    'btts':   (btts   * 100).round(),
    'over25': (over25 * 100).round(),
    'over15': (over15 * 100).round(),
    'csHome': (csHome * 100).round(),
    'csAway': (csAway * 100).round(),
  };
}

// All edges across all matches — uses pre-computed Poisson edges when available.
List<Map<String, dynamic>> computeAllEdges() {
  final results = <Map<String, dynamic>>[];
  for (final m in allMatches) {
    // Use backend pre-computed edges if present (Poisson model), else recalculate
    final hEdge = m.containsKey('homeEdge')
        ? (m['homeEdge'] as double)
        : valueEdge(m['homePct'] as int, (m['bookieHomePct'] as int?) ?? (m['homePct'] as int)).toDouble();
    final dEdge = m.containsKey('drawEdge')
        ? (m['drawEdge'] as double)
        : valueEdge(m['drawPct'] as int, (m['bookieDrawPct'] as int?) ?? (m['drawPct'] as int)).toDouble();
    final aEdge = m.containsKey('awayEdge')
        ? (m['awayEdge'] as double)
        : valueEdge(m['awayPct'] as int, (m['bookieAwayPct'] as int?) ?? (m['awayPct'] as int)).toDouble();

    final bH = (m['bookieHomePct'] as int?) ?? (m['homePct'] as int);
    final bD = (m['bookieDrawPct'] as int?) ?? (m['drawPct'] as int);
    final bA = (m['bookieAwayPct'] as int?) ?? (m['awayPct'] as int);

    if (hEdge > 0) results.add({'match': m, 'market': '${m['home']} Win', 'aiPct': m['homePct'], 'bookiePct': bH, 'edge': hEdge.round()});
    if ((m['drawPct'] as int) > 0 && dEdge > 0) results.add({'match': m, 'market': 'Draw', 'aiPct': m['drawPct'], 'bookiePct': bD, 'edge': dEdge.round()});
    if (aEdge > 0) results.add({'match': m, 'market': '${m['away']} Win', 'aiPct': m['awayPct'], 'bookiePct': bA, 'edge': aEdge.round()});
  }
  results.sort((a, b) => (b['edge'] as int).compareTo(a['edge'] as int));
  return results;
}

// ─── ESPN LIVE DATA ──────────────────────────────────────────────────────────

// Cached logo URLs + live scores keyed by team name (populated at startup)
final Map<String, String>  _espnLogos    = {};
final Map<String, String>  _sportsDbLogos = {};
final Map<String, Map<String, dynamic>> _espnScores = {};

class EspnService {
  static const _boards = {
    'soccer_epl':                  'https://site.api.espn.com/apis/site/v2/sports/soccer/eng.1/scoreboard',
    'soccer_england_championship': 'https://site.api.espn.com/apis/site/v2/sports/soccer/eng.2/scoreboard',
    'soccer_spain_la_liga':        'https://site.api.espn.com/apis/site/v2/sports/soccer/esp.1/scoreboard',
    'soccer_germany_bundesliga':   'https://site.api.espn.com/apis/site/v2/sports/soccer/ger.1/scoreboard',
    'soccer_italy_serie_a':        'https://site.api.espn.com/apis/site/v2/sports/soccer/ita.1/scoreboard',
    'soccer_uefa_champs_league':   'https://site.api.espn.com/apis/site/v2/sports/soccer/uefa.champions/scoreboard',
    'americanfootball_nfl':        'https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard',
    'basketball_nba':              'https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard',
  };

  // Teams endpoints return ALL team logos regardless of today's schedule
  static const _teamEndpoints = [
    'https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams',
    'https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/eng.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/eng.2/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/esp.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/ger.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/ita.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/fra.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/por.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/ned.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/sco.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/uefa.champions/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/uefa.europa/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/tur.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/mex.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/arg.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/bra.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/usa.1/teams',
    'https://site.api.espn.com/apis/site/v2/sports/soccer/sch.1/teams',  // Scottish Championship
    'https://site.api.espn.com/apis/site/v2/sports/cricket/icc.t20/teams',
  ];

  static Future<void> fetchAllTeams() async {
    await Future.wait(_teamEndpoints.map(_fetchTeamList));
  }

  static Future<void> _fetchTeamList(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final sports = (body['sports'] as List?) ?? [];
      for (final sport in sports) {
        final leagues = ((sport as Map)['leagues'] as List?) ?? [];
        for (final league in leagues) {
          final teams = ((league as Map)['teams'] as List?) ?? [];
          for (final teamWrap in teams) {
            final team = (teamWrap as Map)['team'] as Map<String, dynamic>? ?? {};
            final logos = (team['logos'] as List?) ?? [];
            final logoUrl = logos.isNotEmpty ? (logos.first as Map)['href'] as String? : null;
            if (logoUrl == null || logoUrl.isEmpty) continue;
            for (final key in ['displayName', 'shortDisplayName', 'name', 'abbreviation', 'nickname']) {
              final n = team[key] as String?;
              if (n != null && n.isNotEmpty) _espnLogos[n] = logoUrl;
            }
          }
        }
      }
    } catch (_) {}
  }

  static Future<void> fetchAll(List<String> sportKeys) async {
    for (final key in sportKeys) {
      final url = _boards[key];
      if (url == null) continue;
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
        if (res.statusCode == 200) {
          _process(jsonDecode(res.body) as Map<String, dynamic>);
        }
      } catch (_) {}
    }
  }

  static void _process(Map<String, dynamic> data) {
    for (final ev in (data['events'] as List?) ?? []) {
      for (final comp in ((ev as Map)['competitions'] as List?) ?? []) {
        final compMap    = comp as Map<String, dynamic>;
        final statusType = ((compMap['status'] as Map?)?['type'] as Map?);
        final isLive     = statusType?['name'] == 'STATUS_IN_PROGRESS';
        final isFinal    = statusType?['name'] == 'STATUS_FINAL';
        final detail     = statusType?['shortDetail'] as String? ?? '';

        for (final c in (compMap['competitors'] as List?) ?? []) {
          final cMap  = c as Map<String, dynamic>;
          final team  = cMap['team'] as Map<String, dynamic>;
          final score = cMap['score'] as String? ?? '0';
          final logos = (team['logos'] as List?) ?? [];
          final logoUrl = logos.isNotEmpty ? (logos.first as Map)['href'] as String? : null;

          // Register under multiple name variants
          for (final key in ['displayName', 'shortDisplayName', 'name', 'abbreviation']) {
            final n = team[key] as String?;
            if (n == null || n.isEmpty) continue;
            if (logoUrl != null) _espnLogos[n] = logoUrl;
            _espnScores[n] = {'score': score, 'isLive': isLive, 'isFinal': isFinal, 'detail': detail};
          }
        }
      }
    }
  }
}

// ─── THESPORTSDB LOGO SERVICE ────────────────────────────────────────────────

class TheSportsDBService {
  static const _base = 'https://www.thesportsdb.com/api/v1/json/3';

  static const _leagues = [
    // Football (soccer)
    'English Premier League',
    'English League Championship',
    'Spanish La Liga',
    'German Bundesliga',
    'Italian Serie A',
    'UEFA Champions League',
    'UEFA Europa League',
    'UEFA Europa Conference League',
    'French Ligue 1',
    'Scottish Premiership',
    'Portuguese Primeira Liga',
    'Dutch Eredivisie',
    'Belgian First Division A',
    'Turkish Super Lig',
    'Argentine Primera División',
    'Brazilian Serie A',
    'MLS Soccer',
    // American football
    'NFL',
    // Basketball
    'NBA',
    // Cricket
    'Indian Premier League',
    'Big Bash League',
    'Pakistan Super League',
    'Caribbean Premier League',
    'The Hundred',
    'T20 Blast',
  ];

  static void _storeSdb(String name, String badge) {
    _sportsDbLogos[name] = badge;
    // Also store under common shortened variants
    final norm = name
        .replaceAll(RegExp(r'\b(FC|AFC|SC|CF|FK|SK|AC|AS|RB|CD|UD|SD|RC|Sporting|Athletic)\b'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (norm.isNotEmpty && norm != name) _sportsDbLogos[norm] = badge;
  }

  static Future<void> fetchAll() async {
    await Future.wait(_leagues.map(_fetchLeague));
  }

  static Future<void> _fetchLeague(String league) async {
    try {
      final uri = Uri.parse('$_base/search_all_teams.php?l=${Uri.encodeComponent(league)}');
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      for (final t in (data['teams'] as List?) ?? []) {
        final m     = t as Map<String, dynamic>;
        final badge = (m['strBadge'] as String?) ?? '';
        if (badge.isEmpty) continue;
        for (final key in ['strTeam', 'strTeamShort', 'strTeamAlternate']) {
          final n = m[key] as String?;
          if (n == null || n.isEmpty) continue;
          _storeSdb(n, badge);
        }
      }
    } catch (_) {}
  }
}

// ─── TEAM LOGO WIDGET ────────────────────────────────────────────────────────

Widget teamLogoWidget(String name, double size, {String sportKey = 'football'}) {
  final espnUrl = _espnLogos[name];
  final sdbUrl  = _sportsDbLogos[name];

  if (espnUrl != null) {
    return ClipOval(
      child: Image.network(espnUrl, width: size, height: size, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) {
            if (sdbUrl != null) {
              return ClipOval(child: Image.network(sdbUrl, width: size, height: size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _logoFallback(name, size, sportKey: sportKey)));
            }
            return _logoFallback(name, size, sportKey: sportKey);
          }),
    );
  }
  if (sdbUrl != null) {
    return ClipOval(
      child: Image.network(sdbUrl, width: size, height: size, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _logoFallback(name, size, sportKey: sportKey)),
    );
  }
  return _logoFallback(name, size, sportKey: sportKey);
}

Widget _logoFallback(String name, double size, {String sportKey = 'football'}) {
  final emoji = _teamLogos[name];
  if (emoji != null) {
    return SizedBox(width: size, height: size,
        child: Center(child: Text(emoji, style: TextStyle(fontSize: size * 0.72))));
  }
  // Sport-specific fallback icon instead of generic initials
  final sportEmoji = switch (sportKey) {
    'mma'      => '🥊',
    'tennis'   => '🎾',
    'cricket'  => '🏏',
    'nfl'      => '🏈',
    'nba'      => '🏀',
    'boxing'   => '🥊',
    'darts'    => '🎯',
    'racing'   => '🐎',
    'football' => '⚽',
    _          => '🏆',
  };
  return Container(
    width: size, height: size,
    decoration: BoxDecoration(
      color: kCard, shape: BoxShape.circle,
      border: Border.all(color: Colors.grey.shade800),
    ),
    child: Center(child: Text(sportEmoji, style: TextStyle(fontSize: size * 0.52))),
  );
}

// ─── TEAM LOGO MAP ───────────────────────────────────────────────────────────

const _teamLogos = <String, String>{
  // Premier League
  'Arsenal':              '🔴',
  'Aston Villa':          '🟣',
  'Bournemouth':          '🔴',
  'Brentford':            '🔴',
  'Brighton':             '🔵',
  'Brighton & Hove Albion': '🔵',
  'Chelsea':              '🔵',
  'Crystal Palace':       '🔴',
  'Everton':              '🔵',
  'Fulham':               '⚪',
  'Ipswich':              '🔵',
  'Ipswich Town':         '🔵',
  'Leicester':            '🔵',
  'Leicester City':       '🔵',
  'Liverpool':            '🔴',
  'Manchester City':      '🔵',
  'Man City':             '🔵',
  'Manchester United':    '🔴',
  'Man United':           '🔴',
  'Newcastle':            '⚫',
  'Newcastle United':     '⚫',
  'Nottingham Forest':    '🔴',
  'Southampton':          '🔴',
  'Tottenham':            '⚪',
  'Tottenham Hotspur':    '⚪',
  'West Ham':             '🟣',
  'West Ham United':      '🟣',
  'Wolves':               '🟡',
  'Wolverhampton Wanderers': '🟡',
  // Championship
  'Birmingham City':      '🔵',
  'Blackburn':            '🔵',
  'Blackburn Rovers':     '🔵',
  'Bristol City':         '🔴',
  'Burnley':              '🟣',
  'Cardiff City':         '🔵',
  'Coventry':             '🔵',
  'Coventry City':        '🔵',
  'Derby County':         '⚪',
  'Hull City':            '🟠',
  'Leeds United':         '⚪',
  'Luton Town':           '🟠',
  'Middlesbrough':        '🔴',
  'Millwall':             '🔵',
  'Norwich City':         '🟡',
  'Oxford United':        '🟡',
  'Portsmouth':           '🔵',
  'Preston':              '⚪',
  'Preston North End':    '⚪',
  'Queens Park Rangers':  '🔵',
  'QPR':                  '🔵',
  'Sheffield United':     '🔴',
  'Sheffield Wednesday':  '🔵',
  'Stoke City':           '🔴',
  'Sunderland':           '🔴',
  'Swansea':              '⚪',
  'Swansea City':         '⚪',
  'Watford':              '🟡',
  'West Brom':            '🔵',
  'West Bromwich Albion': '🔵',
  // Boxing
  'Anthony Joshua':       '🥊',
  'Daniel Dubois':        '🥊',
  'Chris Eubank Jr':      '🥊',
  'Conor Benn':           '🥊',
  'Tyson Fury':           '🥊',
  'Oleksandr Usyk':       '🥊',
  // Darts
  'Luke Littler':         '🎯',
  'Michael van Gerwen':   '🎯',
  'Gerwyn Price':         '🎯',
  'Peter Wright':         '🎯',
  // Racing
  'Desert Crown':         '🐎',
  'Coral Eclipse':        '🐎',
  'Golden Horn':          '🐎',
  'Sea The Stars':        '🐎',
  // NFL
  'Kansas City Chiefs':   '🏈', 'San Francisco 49ers': '🏈',
  'Philadelphia Eagles':  '🏈', 'Dallas Cowboys':      '🏈',
  'Buffalo Bills':        '🏈', 'Miami Dolphins':      '🏈',
  'Baltimore Ravens':     '🏈', 'Cincinnati Bengals':  '🏈',
  'Green Bay Packers':    '🏈', 'Chicago Bears':       '🏈',
  'New England Patriots': '🏈', 'New York Giants':     '🏈',
  'Los Angeles Rams':     '🏈', 'Seattle Seahawks':    '🏈',
  // NBA
  'Los Angeles Lakers':   '🏀', 'Golden State Warriors': '🏀',
  'Boston Celtics':       '🏀', 'Miami Heat':            '🏀',
  'Milwaukee Bucks':      '🏀', 'Phoenix Suns':          '🏀',
  'Brooklyn Nets':        '🏀', 'Chicago Bulls':         '🏀',
  'Denver Nuggets':       '🏀', 'Dallas Mavericks':      '🏀',
  'Philadelphia 76ers':   '🏀', 'Toronto Raptors':       '🏀',
  // European football
  'Real Madrid':          '⚪', 'Barcelona':             '🔴',
  'Atletico Madrid':      '🔴', 'Sevilla':               '🔴',
  'Valencia':             '🟠', 'Villarreal':            '🟡',
  'Bayern Munich':        '🔴', 'Borussia Dortmund':     '🟡',
  'RB Leipzig':           '🔴', 'Bayer Leverkusen':      '🔴',
  'Juventus':             '⚪', 'AC Milan':              '🔴',
  'Inter Milan':          '🔵', 'Napoli':                '🔵',
  'AS Roma':              '🔴', 'Lazio':                 '🔵',
  'PSG':                  '🔵', 'Paris Saint-Germain':   '🔵',
};

String teamLogo(String name) => _teamLogos[name] ?? '⚽';

// ─── BACKEND SERVICE (Poisson model) ─────────────────────────────────────────

class BackendService {
  // Production: set ODDSVISION_BACKEND env var, or update this URL before release.
  // 10.0.2.2 reaches the host machine from the Android emulator (dev only).
  static const _base = String.fromEnvironment(
    'ODDSVISION_BACKEND',
    defaultValue: 'http://10.0.2.2:8000',
  );

  static const _sportKeyMap = {
    // Football
    'soccer_epl':                  'football',
    'soccer_england_championship': 'football',
    'soccer_spain_la_liga':        'football',
    'soccer_germany_bundesliga':   'football',
    'soccer_italy_serie_a':        'football',
    'soccer_uefa_champs_league':   'football',
    // Tennis
    'tennis_atp':                  'tennis',
    'tennis_wta':                  'tennis',
    // Cricket
    'cricket_ipl':                 'cricket',
    'cricket_international_t20':   'cricket',
    'cricket_odi':                 'cricket',
    'cricket_big_bash':            'cricket',
    // MMA
    'mma_mixed_martial_arts':      'mma',
    // NFL
    'americanfootball_nfl':        'nfl',
    // NBA
    'basketball_nba':              'nba',
    // Boxing
    'boxing_boxing':               'boxing',
    // Tennis (tournament-specific keys discovered dynamically by backend)
    'tennis_atp_us_open':          'tennis',
    'tennis_wta_us_open':          'tennis',
    'tennis_atp_aus_open':         'tennis',
    'tennis_wta_aus_open':         'tennis',
    'tennis_atp_french_open':      'tennis',
    'tennis_wta_french_open':      'tennis',
    'tennis_atp_wimbledon':        'tennis',
    'tennis_wta_wimbledon':        'tennis',
    'tennis_atp_miami_open':       'tennis',
    'tennis_wta_miami_open':       'tennis',
    'tennis_atp_indian_wells':     'tennis',
    'tennis_wta_indian_wells':     'tennis',
    'tennis_atp_china_open':       'tennis',
    'tennis_wta_china_open':       'tennis',
    'tennis_atp_madrid_open':      'tennis',
    'tennis_wta_madrid_open':      'tennis',
  };

  static String _inferSportKey(String rawKey) {
    if (rawKey.startsWith('americanfootball') || rawKey == 'nfl') return 'nfl';
    if (rawKey.startsWith('soccer') || rawKey == 'football')      return 'football';
    if (rawKey.startsWith('basketball') || rawKey == 'nba')       return 'nba';
    if (rawKey.startsWith('tennis'))                              return 'tennis';
    if (rawKey.startsWith('cricket'))                             return 'cricket';
    if (rawKey.startsWith('mma') || rawKey.startsWith('ufc') || rawKey == 'mma') return 'mma';
    if (rawKey.startsWith('boxing'))                              return 'boxing';
    return 'other';
  }

  static String _inferFromCompetition(String competition) {
    final c = competition.toUpperCase();
    if (c.contains('NFL') || c.contains('AMERICAN FOOTBALL')) return 'nfl';
    if (c.contains('NBA') || c.contains('BASKETBALL'))        return 'nba';
    if (c.contains('UFC') || c.contains('MMA'))               return 'mma';
    if (c.contains('ATP') || c.contains('WTA') || c.contains('TENNIS')) return 'tennis';
    if (c.contains('CRICKET') || c.contains('IPL') || c.contains('T20')) return 'cricket';
    if (c.contains('BOXING'))                                  return 'boxing';
    return 'football';
  }

  static Future<List<Map<String, dynamic>>> fetchAllMatches() async {
    final res = await http.get(Uri.parse('$_base/probabilities'))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return [];
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final matches = (body['matches'] as List?) ?? [];
    return matches.map((m) => _toMatch(m as Map<String, dynamic>)).toList();
  }

  static Map<String, dynamic> _toMatch(Map<String, dynamic> m) {
    final home = m['home'] as String;
    final away = m['away'] as String;
    final rawSportKey = m['sport_key'] as String? ?? '';
    final competition = m['competition'] as String? ?? '';
    final sportKeyFromMap = _sportKeyMap[rawSportKey] ?? _inferSportKey(rawSportKey);
    final sportKey = sportKeyFromMap == 'other' ? _inferFromCompetition(competition) : sportKeyFromMap;
    final bkms = (m['bookmakers'] as List? ?? []).map((b) {
      final bk = b as Map<String, dynamic>;
      return {
        'name':     bk['name'],
        'homePct':  (bk['home_pct'] as num).round(),
        'drawPct':  (bk['draw_pct'] as num).round(),
        'awayPct':  (bk['away_pct'] as num).round(),
      };
    }).toList();

    return {
      'sport':          m['competition'],
      'sportKey':       sportKey,
      'time':           _fmtTime(m['commence_time'] as String),
      'kickoffUtc':     m['commence_time'] as String,
      'home':           home,
      'away':           away,
      // Model (Poisson) probabilities — used as the "AI" probability
      'homePct':        (m['model_home_pct'] as num).round(),
      'drawPct':        (m['model_draw_pct'] as num).round(),
      'awayPct':        (m['model_away_pct'] as num).round(),
      // Bookmaker de-vigged probabilities
      'bookieHomePct':  (m['bookie_home_pct'] as num).round(),
      'bookieDrawPct':  (m['bookie_draw_pct'] as num).round(),
      'bookieAwayPct':  (m['bookie_away_pct'] as num).round(),
      // Pre-computed edges from Poisson model vs bookmaker
      'homeEdge':       (m['home_edge'] as num).toDouble(),
      'drawEdge':       (m['draw_edge'] as num).toDouble(),
      'awayEdge':       (m['away_edge'] as num).toDouble(),
      // Expected goals
      'homeXg':         m['home_xg'],
      'awayXg':         m['away_xg'],
      'modelSource':    m['model_source'],
      'homeLogo':       teamLogo(home),
      'awayLogo':       teamLogo(away),
      'featured':       false,
      'homeForm':       <String>[],
      'awayForm':       <String>[],
      'homePlayers':    <String>[],
      'awayPlayers':    <String>[],
      'injuries':       <String>[],
      'suspensions':    <String>[],
      'h2h':            null,
      'aiAccuracy':     null,
      'bookmakers':     bkms,
      'edgeTrend':      null,
      'realTotals':     <Map<String, dynamic>>[],
      'realSpread':     null,
    };
  }

  static String _fmtTime(String iso) {
    final dt  = DateTime.parse(iso).toLocal();
    final now = DateTime.now();
    final today    = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final day      = DateTime(dt.year, dt.month, dt.day);
    final t = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (day == today)    return 'Today $t';
    if (day == tomorrow) return 'Tomorrow $t';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[dt.weekday - 1]} $t';
  }
}

// ─── ODDS API SERVICE ────────────────────────────────────────────────────────

class OddsApiService {
  static const _apiKey = '92b420a208ece9752ab520256df03112';
  static const _base   = 'https://api.the-odds-api.com/v4';

  // Sports covered by the API (darts + racing stay as mock)
  static const _sports = [
    {'key': 'soccer_epl',                 'label': 'PREMIER LEAGUE', 'sportKey': 'football',  'logo': '⚽'},
    {'key': 'soccer_england_championship','label': 'CHAMPIONSHIP',    'sportKey': 'football',  'logo': '⚽'},
    {'key': 'soccer_spain_la_liga',       'label': 'LA LIGA',         'sportKey': 'football',  'logo': '⚽'},
    {'key': 'soccer_germany_bundesliga',  'label': 'BUNDESLIGA',      'sportKey': 'football',  'logo': '⚽'},
    {'key': 'soccer_italy_serie_a',       'label': 'SERIE A',         'sportKey': 'football',  'logo': '⚽'},
    {'key': 'soccer_uefa_champs_league',  'label': 'CHAMPIONS LEAGUE','sportKey': 'football',  'logo': '⚽'},
    {'key': 'americanfootball_nfl',       'label': 'NFL',             'sportKey': 'nfl',       'logo': '🏈'},
    {'key': 'basketball_nba',             'label': 'NBA',             'sportKey': 'nba',       'logo': '🏀'},
    {'key': 'boxing_boxing',              'label': 'BOXING',          'sportKey': 'boxing',    'logo': '🥊'},
  ];

  static List<String> get sportsKeys =>
      _sports.map((s) => s['key']!).toList();

  static Future<List<Map<String, dynamic>>> fetchAll() async {
    final results = <Map<String, dynamic>>[];
    for (final sport in _sports) {
      try {
        results.addAll(await _fetchSport(sport));
      } catch (_) {
        // network / parse error — skip this sport, keep mock
      }
    }
    return results;
  }

  static Future<List<Map<String, dynamic>>> _fetchSport(
      Map<String, String> sport) async {
    final uri = Uri.parse(
      '$_base/sports/${sport['key']}/odds/'
      '?apiKey=$_apiKey&regions=uk&markets=h2h,totals,spreads&oddsFormat=decimal&dateFormat=iso',
    );
    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return [];
    final events = jsonDecode(res.body) as List;
    return events
        .take(4)
        .map((e) => _toMatch(e as Map<String, dynamic>, sport))
        .toList();
  }

  static Map<String, dynamic> _toMatch(
      Map<String, dynamic> ev, Map<String, String> sport) {
    final home    = ev['home_team'] as String;
    final away    = ev['away_team'] as String;
    final time    = _fmtTime(DateTime.parse(ev['commence_time'] as String).toLocal());
    final bkms    = (ev['bookmakers'] as List?) ?? [];

    final bookmakerList = <Map<String, dynamic>>[];
    final homeOdds = <double>[], drawOdds = <double>[], awayOdds = <double>[];

    // totals: collect over/under per line across bookmakers
    final Map<String, List<double>> overOddsByLine  = {};
    final Map<String, List<double>> underOddsByLine = {};
    // spreads: for NFL/NBA
    final spreadOverOdds  = <double>[];
    final spreadUnderOdds = <double>[];
    double? spreadLine;

    for (final bk in bkms.take(4)) {
      final bkMap   = bk as Map<String, dynamic>;
      final markets = (bkMap['markets'] as List?) ?? [];
      Map? h2h;
      Map? totals;
      Map? spreads;
      for (final m in markets) {
        final mk = m as Map;
        if (mk['key'] == 'h2h')     h2h     = mk;
        if (mk['key'] == 'totals')  totals  = mk;
        if (mk['key'] == 'spreads') spreads = mk;
      }
      if (h2h == null) continue;

      double? hO, dO, aO;
      for (final o in (h2h['outcomes'] as List)) {
        final oMap = o as Map<String, dynamic>;
        final name  = oMap['name'] as String;
        final price = (oMap['price'] as num).toDouble();
        if (name == home)        hO = price;
        else if (name == 'Draw') dO = price;
        else                     aO = price;
      }
      if (hO == null || aO == null) continue;

      homeOdds.add(hO); awayOdds.add(aO);
      if (dO != null) drawOdds.add(dO);

      bookmakerList.add({
        'name':     bkMap['title'],
        'homePct':  (100 / hO).round(),
        'drawPct':  dO != null ? (100 / dO).round() : 0,
        'awayPct':  (100 / aO).round(),
      });

      // Parse totals market
      if (totals != null) {
        for (final o in (totals['outcomes'] as List? ?? [])) {
          final oMap  = o as Map<String, dynamic>;
          final side  = oMap['name'] as String;
          final line  = (oMap['description'] as String?) ?? '';
          final price = (oMap['price'] as num).toDouble();
          if (side == 'Over')  (overOddsByLine[line]  ??= []).add(price);
          if (side == 'Under') (underOddsByLine[line] ??= []).add(price);
        }
      }

      // Parse spreads market
      if (spreads != null) {
        for (final o in (spreads['outcomes'] as List? ?? [])) {
          final oMap  = o as Map<String, dynamic>;
          final side  = oMap['name'] as String;
          final price = (oMap['price'] as num).toDouble();
          final pt    = (oMap['point'] as num?)?.toDouble();
          if (side == home && pt != null) {
            spreadLine = pt;
            spreadOverOdds.add(price);
          } else if (side == away) {
            spreadUnderOdds.add(price);
          }
        }
      }
    }

    // Build realTotals list: de-vig each line
    final realTotals = <Map<String, dynamic>>[];
    for (final line in overOddsByLine.keys) {
      final oList = overOddsByLine[line]!;
      final uList = underOddsByLine[line] ?? [];
      if (oList.isEmpty) continue;
      final avgO = oList.reduce((a, b) => a + b) / oList.length;
      final avgU = uList.isNotEmpty ? uList.reduce((a, b) => a + b) / uList.length : 0.0;
      final iO = 1 / avgO;
      final iU = avgU > 0 ? 1 / avgU : 0.0;
      final tot = iO + (iU > 0 ? iU : iO); // if no under, assume symmetric
      final overPct  = (iO / tot * 100).round();
      final underPct = 100 - overPct;
      realTotals.add({'line': line, 'overPct': overPct, 'underPct': underPct});
    }
    // Sort by line ascending (0.5, 1.5, 2.5, 3.5...)
    realTotals.sort((a, b) {
      final la = double.tryParse(a['line'] as String) ?? 0;
      final lb = double.tryParse(b['line'] as String) ?? 0;
      return la.compareTo(lb);
    });

    // Spreads result
    Map<String, dynamic>? realSpread;
    if (spreadOverOdds.isNotEmpty && spreadUnderOdds.isNotEmpty && spreadLine != null) {
      final avgO = spreadOverOdds.reduce((a, b) => a + b) / spreadOverOdds.length;
      final avgU = spreadUnderOdds.reduce((a, b) => a + b) / spreadUnderOdds.length;
      final iO = 1 / avgO; final iU = 1 / avgU;
      final tot = iO + iU;
      realSpread = {
        'line': spreadLine,
        'homePct': (iO / tot * 100).round(),
        'awayPct': (iU / tot * 100).round(),
      };
    }

    // Average then de-vig for AI probability
    if (homeOdds.isEmpty) {
      return _stub(home, away, time, sport, bookmakerList);
    }

    final avgH = homeOdds.reduce((a, b) => a + b) / homeOdds.length;
    final avgD = drawOdds.isNotEmpty ? drawOdds.reduce((a, b) => a + b) / drawOdds.length : 0.0;
    final avgA = awayOdds.reduce((a, b) => a + b) / awayOdds.length;

    final iH = 1 / avgH;
    final iD = avgD > 0 ? 1 / avgD : 0.0;
    final iA = 1 / avgA;
    final tot = iH + iD + iA;

    final aiH = (iH / tot * 100).round();
    final aiD = iD > 0 ? (iD / tot * 100).round() : 0;
    final aiA = 100 - aiH - aiD;

    final bkH = (iH * 100).round();
    final bkD = (iD * 100).round();
    final bkA = (iA * 100).round();

    return {
      'sport': sport['label'], 'sportKey': sport['sportKey'],
      'time': time,
      'kickoffUtc': ev['commence_time'] as String,
      'home': home, 'away': away,
      'homePct': aiH, 'drawPct': aiD, 'awayPct': max(1, aiA),
      'bookieHomePct': bkH, 'bookieDrawPct': bkD, 'bookieAwayPct': bkA,
      'homeLogo': teamLogo(home), 'awayLogo': teamLogo(away),
      'featured': false,
      'homeForm': <String>[], 'awayForm': <String>[],
      'homePlayers': <String>[], 'awayPlayers': <String>[],
      'injuries': <String>[], 'suspensions': <String>[],
      'h2h': null, 'aiAccuracy': null,
      'bookmakers': bookmakerList,
      'edgeTrend': null,
      'realTotals': realTotals,
      'realSpread': realSpread,
    };
  }

  static Map<String, dynamic> _stub(String home, String away, String time,
      Map<String, String> sport, List bkms) => {
    'sport': sport['label'], 'sportKey': sport['sportKey'],
    'time': time, 'kickoffUtc': '', 'home': home, 'away': away,
    'homePct': 40, 'drawPct': 27, 'awayPct': 33,
    'bookieHomePct': 38, 'bookieDrawPct': 28, 'bookieAwayPct': 34,
    'homeLogo': teamLogo(home), 'awayLogo': teamLogo(away),
    'featured': false,
    'homeForm': <String>[], 'awayForm': <String>[],
    'homePlayers': <String>[], 'awayPlayers': <String>[],
    'injuries': <String>[], 'suspensions': <String>[],
    'h2h': null, 'aiAccuracy': null,
    'bookmakers': bkms, 'edgeTrend': null,
    'realTotals': <Map<String, dynamic>>[], 'realSpread': null,
  };

  static String _fmtTime(DateTime dt) {
    final now      = DateTime.now();
    final today    = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final day      = DateTime(dt.year, dt.month, dt.day);
    final t = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (day == today)    return 'Today $t';
    if (day == tomorrow) return 'Tomorrow $t';
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[dt.weekday - 1]} $t';
  }
}

// ─── SHARED DATA ─────────────────────────────────────────────────────────────

final List<Map<String, dynamic>> allMatches = [];


// ─── MAIN SCREEN ─────────────────────────────────────────────────────────────

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;
  bool _loadingLive = true;
  String? _liveError;

  @override
  void initState() {
    super.initState();
    _fetchLive().then((_) => _startScoreTicker());
  }

  Future<void> _fetchLive() async {
    setState(() { _loadingLive = true; _liveError = null; });
    try {
      final sportKeys = OddsApiService.sportsKeys;
      final espnF        = EspnService.fetchAll(sportKeys);
      final espnTeamsF   = EspnService.fetchAllTeams();
      final sportsDbF    = TheSportsDBService.fetchAll();

      // Try Poisson backend first; fall back to raw Odds API if unreachable
      List<Map<String, dynamic>> live = [];
      String? modelWarning;
      try {
        live = await BackendService.fetchAllMatches();
      } catch (_) {
        live = await OddsApiService.fetchAll();
        modelWarning = 'Model unavailable — showing de-vig odds';
      }

      await Future.wait([espnF, espnTeamsF, sportsDbF]);

      if (live.isNotEmpty) {
        snapshotOdds();
        allMatches.clear();
        allMatches.addAll(live);
        allMatches.sort((a, b) {
          final ta = a['kickoffUtc'] as String? ?? '';
          final tb = b['kickoffUtc'] as String? ?? '';
          if (ta.isEmpty && tb.isEmpty) return 0;
          if (ta.isEmpty) return 1;
          if (tb.isEmpty) return -1;
          return ta.compareTo(tb);
        });
        for (var i = 0; i < min(4, allMatches.length); i++) {
          allMatches[i]['featured'] = true;
        }
      }

      lastUpdated = DateTime.now();
      _liveError  = modelWarning;
      await checkEdgeAlerts(globalAlertThreshold);
      // Ask for notification permission after the user has seen content
      Future.delayed(const Duration(seconds: 4), requestNotificationPermission);
    } catch (e) {
      _liveError = 'Could not load live odds. Pull down to retry.';
    } finally {
      if (mounted) setState(() => _loadingLive = false);
    }
  }

  // Refresh live scores every 60 seconds while app is open
  void _startScoreTicker() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 60));
      if (!mounted) return false;
      await EspnService.fetchAll(OddsApiService.sportsKeys);
      lastUpdated = DateTime.now();
      await checkEdgeAlerts(globalAlertThreshold);
      if (mounted) setState(() {});
      return mounted;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingLive) {
      return Scaffold(
        backgroundColor: kBg,
        body: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: kGreen, borderRadius: BorderRadius.circular(5)),
              child: const Text('ODDS',
                  style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: 1)),
            ),
            const Text('VISION',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: 1)),
          ]),
          const SizedBox(height: 8),
          Text('Statistical model vs market comparison', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          const SizedBox(height: 40),
          const SizedBox(
            width: 24, height: 24,
            child: CircularProgressIndicator(color: kGreen, strokeWidth: 2),
          ),
          const SizedBox(height: 14),
          Text('Loading live odds...', style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
        ])),
      );
    }

    final screens = [
      HomeTab(liveError: _liveError, onRefresh: _fetchLive),
      const SportsTab(),
      const TrackerTab(),
      const AccountTab(),
    ];

    return Scaffold(
      body: screens[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: kCard,
        selectedItemColor: kGreen,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        currentIndex: _selectedIndex,
        onTap: (i) => setState(() => _selectedIndex = i),
        items: [
          const BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          const BottomNavigationBarItem(icon: Icon(Icons.sports_soccer), label: 'Sports'),
          const BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'Tracker'),
          const BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Account'),
        ],
      ),
    );
  }
}

// ─── SHARED APPBAR ───────────────────────────────────────────────────────────

AppBar buildAppBar(String subtitle, BuildContext context) => AppBar(
  backgroundColor: kCard,
  elevation: 0,
  title: Row(children: [
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: kGreen, borderRadius: BorderRadius.circular(4)),
      child: const Text('ODDS',
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1)),
    ),
    const Text('VISION',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 1)),
    const SizedBox(width: 8),
    Text(subtitle, style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
  ]),
  actions: [
    IconButton(
      icon: const Icon(Icons.search, color: Colors.white),
      onPressed: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => const SearchScreen(),
      )),
    ),
    IconButton(
      icon: const Icon(Icons.notifications_outlined, color: Colors.white),
      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsScreen())),
    ),
  ],
);

// ─── HOME TAB ────────────────────────────────────────────────────────────────

class HomeTab extends StatefulWidget {
  final String? liveError;
  final Future<void> Function() onRefresh;
  const HomeTab({super.key, required this.onRefresh, this.liveError});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  static const _sports = [
    {'name': 'All',      'key': 'all',     'icon': '🏆'},
    {'name': 'Football', 'key': 'football','icon': '⚽'},
    {'name': 'Tennis',   'key': 'tennis',  'icon': '🎾'},
    {'name': 'Cricket',  'key': 'cricket', 'icon': '🏏'},
    {'name': 'MMA',      'key': 'mma',     'icon': '🥋'},
    {'name': 'Boxing',   'key': 'boxing',  'icon': '🥊'},
    {'name': 'NBA',      'key': 'nba',     'icon': '🏀'},
    {'name': 'NFL',      'key': 'nfl',     'icon': '🏈'},
  ];

  String _selected = 'all';

  List<Map<String, dynamic>> get _filtered => _selected == 'all'
      ? allMatches
      : allMatches.where((m) => m['sportKey'] == _selected).toList();

  @override
  Widget build(BuildContext context) {
    final matches  = _filtered;
    final featured = allMatches.where((m) => m['featured'] == true).toList();

    return Scaffold(
      backgroundColor: kBg,
      appBar: buildAppBar('Home', context),
      body: Column(
        children: [
          // ── Sport filter bar ───────────────────────────────────────────
          Container(
            color: kCard,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: _sports.map((s) {
                  final key      = s['key']!;
                  final selected = _selected == key;
                  final count    = key == 'all'
                      ? allMatches.length
                      : allMatches.where((m) => m['sportKey'] == key).length;
                  return GestureDetector(
                    onTap: () => setState(() => _selected = key),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected ? kGreen : Colors.grey.shade900,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: selected ? kGreen : Colors.grey.shade800),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(s['icon']!, style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 6),
                        Text(s['name']!,
                            style: TextStyle(
                              color: selected ? Colors.black : Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            )),
                        if (count > 0) ...[
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: selected ? Colors.black.withOpacity(0.2) : Colors.grey.shade800,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text('$count',
                                style: TextStyle(
                                  color: selected ? Colors.black : Colors.grey.shade400,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                )),
                          ),
                        ],
                      ]),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          // ── Feed ────────────────────────────────────────────────────────
          Expanded(
            child: RefreshIndicator(
              color: kGreen,
              backgroundColor: kCard,
              onRefresh: widget.onRefresh,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  // Status row
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(children: [
                      Container(width: 6, height: 6,
                          decoration: BoxDecoration(
                            color: lastUpdated != null ? kGreen : Colors.orange,
                            shape: BoxShape.circle,
                          )),
                      const SizedBox(width: 6),
                      Text(updatedAgo(),
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                    ]),
                  ),
                  // Error banner
                  if (widget.liveError != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.withOpacity(0.3)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.wifi_off, color: Colors.orange, size: 14),
                        const SizedBox(width: 8),
                        Expanded(child: Text(widget.liveError!,
                            style: const TextStyle(color: Colors.orange, fontSize: 12))),
                      ]),
                    ),
                  // Edge leaderboard banner (All view only)
                  if (_selected == 'all') ...[
                    GestureDetector(
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const EdgeLeaderboardScreen())),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                              colors: [kGreen.withOpacity(0.18), Colors.transparent]),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: kGreen.withOpacity(0.45)),
                        ),
                        child: Row(children: [
                          const Text('⚡', style: TextStyle(fontSize: 26)),
                          const SizedBox(width: 12),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('Edge Leaderboard',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                            Text('Top model edges vs bookmaker right now',
                                style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                          ])),
                          GestureDetector(
                            onTap: () => showEdgeExplainer(context),
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.06),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.help_outline, color: Colors.white, size: 16),
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.chevron_right, color: kGreen),
                        ]),
                      ),
                    ),
                    const SectionHeader(title: '🔥 Featured Today'),
                    const SizedBox(height: 10),
                    ...featured.map((m) => MatchCard(match: m)),
                  ],
                  // Sport-filtered list
                  if (_selected != 'all') ...[
                    if (matches.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 60),
                        child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text('No fixtures', style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
                          if (widget.liveError != null) ...[
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              onPressed: widget.onRefresh,
                              icon: const Icon(Icons.refresh, size: 16),
                              label: const Text('Retry'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: kGreen,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ],
                        ])),
                      )
                    else
                      ...matches.map((m) => MatchCard(match: m)),
                  ],
                  // All-sports empty state (network error)
                  if (_selected == 'all' && allMatches.isEmpty && widget.liveError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 60),
                      child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.wifi_off, color: Colors.grey, size: 48),
                        const SizedBox(height: 16),
                        const Text('Could not load live odds',
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text('Check your connection and try again',
                            style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: widget.onRefresh,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Retry'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kGreen,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ])),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── SPORTS TAB ──────────────────────────────────────────────────────────────

class SportsTab extends StatelessWidget {
  const SportsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final liveCount = allMatches.where((m) =>
        _espnScores[m['home']]?['isLive'] == true ||
        _espnScores[m['away']]?['isLive'] == true).length;

    return Scaffold(
      backgroundColor: kBg,
      appBar: buildAppBar('All Fixtures', context),
      body: Column(
        children: [
          if (liveCount > 0)
            Container(
              width: double.infinity,
              color: Colors.red.withOpacity(0.08),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Container(width: 6, height: 6,
                    decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text('$liveCount LIVE now',
                    style: const TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ),
          Expanded(
            child: allMatches.isEmpty
                ? Center(child: Text('No fixtures',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 14)))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: allMatches.length,
                    itemBuilder: (_, i) => MatchCard(match: allMatches[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── SPORT FIXTURES SCREEN ───────────────────────────────────────────────────

class SportFixturesScreen extends StatelessWidget {
  final String sportName, sportKey, icon;
  const SportFixturesScreen({
    super.key, required this.sportName, required this.sportKey, required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final fixtures = allMatches.where((m) => m['sportKey'] == sportKey).toList();
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kCard,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context)),
        title: Text('$icon  $sportName',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
      body: RefreshIndicator(
        color: kGreen,
        backgroundColor: kCard,
        onRefresh: () async {
          // Reuse the main screen fetch if available
          await OddsApiService.fetchAll();
        },
        child: fixtures.isEmpty
            ? ListView(children: [
                SizedBox(
                  height: 400,
                  child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(icon, style: const TextStyle(fontSize: 48)),
                    const SizedBox(height: 16),
                    Text('No fixtures right now',
                        style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      sportKey == 'nfl' ? 'NFL season runs September – February'
                        : sportKey == 'nba' ? 'NBA season runs October – June'
                        : 'Check back soon for upcoming fixtures',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ])),
                ),
              ])
            : ListView(
                padding: const EdgeInsets.all(12),
                children: fixtures.map((m) => MatchCard(match: m)).toList(),
              ),
      ),
    );
  }
}

// ─── LOG BET SHEET (global helper) ───────────────────────────────────────────

void _showLogBetSheet(
  BuildContext context, {
  String? match,
  String? selection,
  double? modelPct,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kCard,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _AddBetSheet(
      match: match,
      selection: selection,
      modelPct: modelPct,
      onSave: (bet) async {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getStringList('tracker_bets') ?? [];
        raw.insert(0, jsonEncode(bet));
        await prefs.setStringList('tracker_bets', raw);
      },
    ),
  );
}

// ─── TRACKER TAB ─────────────────────────────────────────────────────────────

class TrackerTab extends StatefulWidget {
  const TrackerTab({super.key});
  @override
  State<TrackerTab> createState() => _TrackerTabState();
}

class _TrackerTabState extends State<TrackerTab> {
  List<Map<String, dynamic>> _bets = [];
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _loadBets();
  }

  Future<void> _loadBets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('tracker_bets') ?? [];
    if (mounted) {
      setState(() {
        _bets = raw.map((s) => Map<String, dynamic>.from(jsonDecode(s) as Map)).toList();
      });
    }
  }

  Future<void> _saveBets() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('tracker_bets', _bets.map((b) => jsonEncode(b)).toList());
  }

  void _updateBet(int index, Map<String, dynamic> updated) {
    setState(() => _bets[index] = updated);
    _saveBets();
  }

  void _deleteBet(int index) {
    setState(() => _bets.removeAt(index));
    _saveBets();
  }

  List<Map<String, dynamic>> get _filtered {
    if (_filter == 'all') return _bets;
    return _bets.where((b) => b['status'] == _filter).toList();
  }

  double get _totalPnl => _bets
      .where((b) => b['status'] != 'pending' && b['status'] != 'void')
      .fold(0.0, (sum, b) => sum + (b['pnl'] as double? ?? 0.0));

  double get _totalStaked => _bets
      .where((b) => b['status'] != 'pending' && b['status'] != 'void')
      .fold(0.0, (sum, b) => sum + (b['stake'] as double? ?? 0.0));

  double get _roi => _totalStaked > 0 ? _totalPnl / _totalStaked * 100 : 0.0;

  int get _winCount => _bets.where((b) => b['status'] == 'won').length;
  int get _settledCount =>
      _bets.where((b) => b['status'] == 'won' || b['status'] == 'lost').length;
  double get _winRate =>
      _settledCount > 0 ? _winCount / _settledCount * 100 : 0.0;

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      backgroundColor: kBg,
      appBar: buildAppBar('Bet Tracker', context),
      body: Column(children: [
        _statsHeader(),
        _filterRow(),
        Expanded(
          child: filtered.isEmpty
              ? _empty()
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: filtered.length,
                  itemBuilder: (ctx, i) {
                    final globalIndex = _bets.indexOf(filtered[i]);
                    return _betCard(ctx, filtered[i], globalIndex);
                  },
                ),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: kGreen,
        foregroundColor: Colors.black,
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          backgroundColor: kCard,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          builder: (ctx) => _AddBetSheet(
            onSave: (bet) {
              setState(() => _bets.insert(0, bet));
              _saveBets();
            },
          ),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Log Bet', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _statsHeader() {
    final pnlColor = _totalPnl >= 0 ? kGreen : Colors.red;
    final roiColor = _roi >= 0 ? kGreen : Colors.red;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        _stat('P&L',
            '${_totalPnl >= 0 ? '+' : ''}£${_totalPnl.toStringAsFixed(2)}', pnlColor),
        _statDivider(),
        _stat('ROI',
            '${_roi >= 0 ? '+' : ''}${_roi.toStringAsFixed(1)}%', roiColor),
        _statDivider(),
        _stat('Win Rate',
            _settledCount > 0 ? '${_winRate.toStringAsFixed(0)}%' : '—', Colors.white),
        _statDivider(),
        _stat('Bets', '${_bets.length}', Colors.grey.shade400),
      ]),
    );
  }

  Widget _stat(String label, String value, Color color) => Expanded(
    child: Column(children: [
      Text(value, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w800)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 10)),
    ]),
  );

  Widget _statDivider() =>
      Container(width: 1, height: 28, color: Colors.grey.shade800);

  Widget _filterRow() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
    child: Row(children: ['all', 'pending', 'won', 'lost', 'void'].map((f) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => setState(() => _filter = f),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: _filter == f ? kGreen : kCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: _filter == f ? kGreen : Colors.grey.shade800),
          ),
          child: Text(
            f[0].toUpperCase() + f.substring(1),
            style: TextStyle(
              color: _filter == f ? Colors.black : Colors.grey.shade400,
              fontSize: 12, fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    )).toList()),
  );

  Widget _betCard(BuildContext context, Map<String, dynamic> bet, int index) {
    final status = bet['status'] as String? ?? 'pending';
    final pnl    = bet['pnl'] as double? ?? 0.0;
    final stake  = bet['stake'] as double? ?? 0.0;
    final odds   = bet['odds'] as double? ?? 0.0;
    final statusColor = status == 'won'
        ? kGreen
        : status == 'lost'
            ? Colors.red
            : status == 'void'
                ? Colors.grey
                : kOrange;

    return Dismissible(
      key: Key(bet['id'] as String? ?? index.toString()),
      background: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
            color: Colors.red.withOpacity(0.8),
            borderRadius: BorderRadius.circular(10)),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => _deleteBet(index),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade900)),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Expanded(
                  child: Text(bet['selection'] as String? ?? '',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14),
                      overflow: TextOverflow.ellipsis),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: statusColor.withOpacity(0.4)),
                  ),
                  child: Text(status.toUpperCase(),
                      style: TextStyle(
                          color: statusColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w800)),
                ),
              ]),
              const SizedBox(height: 4),
              Text(bet['match'] as String? ?? '',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                  overflow: TextOverflow.ellipsis),
              if ((bet['modelPct'] as double?) != null) ...[
                const SizedBox(height: 4),
                Text(
                    'Model: ${(bet['modelPct'] as double).toStringAsFixed(0)}%',
                    style: TextStyle(
                        color: Colors.grey.shade600, fontSize: 11)),
              ],
              const SizedBox(height: 10),
              Row(children: [
                _betDetail('Stake', '£${stake.toStringAsFixed(2)}', Colors.white),
                const SizedBox(width: 16),
                _betDetail('Odds', odds.toStringAsFixed(2), Colors.white),
                const SizedBox(width: 16),
                if (status != 'pending' && status != 'void')
                  _betDetail(
                      'P&L',
                      '${pnl >= 0 ? '+' : ''}£${pnl.toStringAsFixed(2)}',
                      pnl >= 0 ? kGreen : Colors.red),
              ]),
            ]),
          ),
          if (status == 'pending')
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Row(children: [
                Expanded(
                    child: _statusButton('Won', kGreen,
                        () => _settle(index, 'won', stake, odds))),
                const SizedBox(width: 8),
                Expanded(
                    child: _statusButton('Lost', Colors.red,
                        () => _settle(index, 'lost', stake, odds))),
                const SizedBox(width: 8),
                Expanded(
                    child: _statusButton('Void', Colors.grey,
                        () => _settle(index, 'void', stake, odds))),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _betDetail(String label, String value, Color color) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 10)),
        Text(value,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontSize: 13)),
      ]);

  Widget _statusButton(String label, Color color, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Center(
            child: Text(label,
                style: TextStyle(
                    color: color, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ),
      );

  void _settle(int index, String status, double stake, double odds) {
    final pnl = status == 'won'
        ? (odds - 1) * stake
        : status == 'void'
            ? 0.0
            : -stake;
    final updated = Map<String, dynamic>.from(_bets[index]);
    updated['status'] = status;
    updated['pnl'] = pnl;
    _updateBet(index, updated);
  }

  Widget _empty() =>
      Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Text('📊', style: TextStyle(fontSize: 48)),
        const SizedBox(height: 16),
        const Text('No bets tracked yet',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text('Tap the button below to log your first bet',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
      ]));
}

// ─── ADD BET SHEET ────────────────────────────────────────────────────────────

class _AddBetSheet extends StatefulWidget {
  final String? match;
  final String? selection;
  final double? modelPct;
  final Function(Map<String, dynamic>) onSave;
  const _AddBetSheet({this.match, this.selection, this.modelPct, required this.onSave});

  @override
  State<_AddBetSheet> createState() => _AddBetSheetState();
}

class _AddBetSheetState extends State<_AddBetSheet> {
  // Track match text separately; Autocomplete owns its internal controller.
  String _matchText = '';
  Map<String, dynamic>? _selectedMatch;

  late final TextEditingController _selCtrl;
  final TextEditingController _stakeCtrl = TextEditingController();
  final TextEditingController _oddsCtrl  = TextEditingController();

  // Derived selection chips from the chosen match's bookmaker h2h odds.
  List<Map<String, dynamic>> get _selectionOptions {
    final m = _selectedMatch;
    if (m == null) return [];
    final home     = m['home']  as String? ?? '';
    final away     = m['away']  as String? ?? '';
    final hasDraw  = ((m['model_draw_pct']  as num?)?.toDouble() ?? 0) > 0 ||
                     ((m['bookie_draw_pct'] as num?)?.toDouble() ?? 0) > 0;

    double homeOdds = 0, drawOdds = 0, awayOdds = 0;
    for (final bk in (m['bookmakers'] as List<dynamic>? ?? [])) {
      for (final mkt in ((bk as Map)['markets'] as List<dynamic>? ?? [])) {
        if ((mkt as Map)['key'] != 'h2h') continue;
        for (final o in (mkt['outcomes'] as List<dynamic>? ?? [])) {
          final name  = (o as Map)['name']  as String? ?? '';
          final price = (o['price'] as num?)?.toDouble() ?? 0;
          if (name == home  && price > homeOdds) homeOdds = price;
          if (name == 'Draw' && price > drawOdds) drawOdds = price;
          if (name == away  && price > awayOdds) awayOdds = price;
        }
      }
    }

    return [
      {'label': '$home Win', 'odds': homeOdds},
      if (hasDraw) {'label': 'Draw', 'odds': drawOdds},
      {'label': '$away Win', 'odds': awayOdds},
    ];
  }

  @override
  void initState() {
    super.initState();
    _matchText = widget.match ?? '';
    _selCtrl   = TextEditingController(text: widget.selection ?? '');
    // If pre-filled from a market button, resolve the allMatches entry so chips show.
    if (_matchText.isNotEmpty) {
      try {
        _selectedMatch = allMatches.firstWhere(
          (m) => '${m['home']} v ${m['away']}' == _matchText,
        );
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _selCtrl.dispose();
    _stakeCtrl.dispose();
    _oddsCtrl.dispose();
    super.dispose();
  }

  void _onMatchSelected(Map<String, dynamic> m) {
    setState(() {
      _selectedMatch = m;
      _matchText     = '${m['home']} v ${m['away']}';
      _selCtrl.clear();
      _oddsCtrl.clear();
    });
  }

  void _onSelectionPicked(Map<String, dynamic> opt) {
    setState(() {
      _selCtrl.text = opt['label'] as String;
      final odds = (opt['odds'] as double?) ?? 0;
      if (odds > 0) _oddsCtrl.text = odds.toStringAsFixed(2);
    });
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: Colors.grey.shade700, fontSize: 14),
    filled: true,
    fillColor: kBg,
    border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.grey.shade800)),
    enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.grey.shade800)),
    focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: kGreen)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text,
        style: TextStyle(
            color: Colors.grey.shade400,
            fontSize: 12,
            fontWeight: FontWeight.w600)),
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
        20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 24),
    child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(child: Container(
          width: 40, height: 4,
          decoration: BoxDecoration(
              color: Colors.grey.shade700,
              borderRadius: BorderRadius.circular(2)))),
      const SizedBox(height: 20),
      const Text('Log a Bet',
          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
      const SizedBox(height: 16),

      // ── Match autocomplete ────────────────────────────────────────────
      _label('Match'),
      Autocomplete<Map<String, dynamic>>(
        initialValue: TextEditingValue(text: _matchText),
        optionsBuilder: (tv) {
          final q = tv.text.toLowerCase();
          if (q.isEmpty) return const [];
          return allMatches.where((m) {
            final h = (m['home'] as String? ?? '').toLowerCase();
            final a = (m['away'] as String? ?? '').toLowerCase();
            return h.contains(q) || a.contains(q) || '$h v $a'.contains(q);
          }).take(6);
        },
        displayStringForOption: (m) => '${m['home']} v ${m['away']}',
        onSelected: _onMatchSelected,
        fieldViewBuilder: (ctx, ctrl, focus, onSubmit) {
          // Keep _matchText in sync as the user types freely.
          ctrl.addListener(() {
            if (_matchText != ctrl.text) {
              _matchText = ctrl.text;
              if (_selectedMatch != null &&
                  ctrl.text != '${_selectedMatch!['home']} v ${_selectedMatch!['away']}') {
                setState(() => _selectedMatch = null);
              }
            }
          });
          return TextField(
            controller: ctrl,
            focusNode: focus,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: _inputDeco('e.g. Arsenal v Chelsea'),
          );
        },
        optionsViewBuilder: (ctx, onSelected, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            color: kCard,
            borderRadius: BorderRadius.circular(8),
            elevation: 6,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 380),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: options.map((m) => InkWell(
                  onTap: () => onSelected(m),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${m['home']} v ${m['away']}',
                          style: const TextStyle(color: Colors.white, fontSize: 13,
                              fontWeight: FontWeight.w600)),
                      Text(m['competition'] as String? ?? '',
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
                    ]),
                  ),
                )).toList(),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),

      // ── Selection chips + free-text ───────────────────────────────────
      _label('Selection'),
      if (_selectionOptions.isNotEmpty) ...[
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: _selectionOptions.map((opt) {
            final label    = opt['label'] as String;
            final odds     = (opt['odds'] as double?) ?? 0;
            final selected = _selCtrl.text == label;
            return GestureDetector(
              onTap: () => _onSelectionPicked(opt),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? kGreen.withOpacity(0.15) : kBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: selected ? kGreen : Colors.grey.shade800),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(label,
                      style: TextStyle(
                          color: selected ? kGreen : Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  if (odds > 0) ...[
                    const SizedBox(width: 6),
                    Text(odds.toStringAsFixed(2),
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
                  ],
                ]),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
      ],
      TextField(
        controller: _selCtrl,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: _inputDeco(
            _selectionOptions.isEmpty ? 'e.g. Arsenal Win' : 'Or type a custom selection'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),

      // ── Stake / Odds ──────────────────────────────────────────────────
      Row(children: [
        Expanded(child: _numField('Stake (£)', _stakeCtrl, '10.00')),
        const SizedBox(width: 12),
        Expanded(child: _numField('Odds', _oddsCtrl, '2.10')),
      ]),

      if (widget.modelPct != null) ...[
        const SizedBox(height: 12),
        Text('Model probability: ${widget.modelPct!.toStringAsFixed(0)}%',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
      ],
      const SizedBox(height: 20),
      GestureDetector(
        onTap: _save,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(color: kGreen, borderRadius: BorderRadius.circular(10)),
          child: const Center(child: Text('Save Bet',
              style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 15))),
        ),
      ),
    ]),
  );

  Widget _numField(String label, TextEditingController ctrl, String hint) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _label(label),
        TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: _inputDeco(hint),
        ),
      ]);

  void _save() {
    final match = _matchText.trim();
    final sel   = _selCtrl.text.trim();
    final stake = double.tryParse(_stakeCtrl.text.replaceAll(',', '.')) ?? 0;
    final odds  = double.tryParse(_oddsCtrl.text.replaceAll(',', '.')) ?? 0;
    if (sel.isEmpty || stake <= 0 || odds <= 0) return;
    widget.onSave({
      'id':        DateTime.now().millisecondsSinceEpoch.toString(),
      'date':      DateTime.now().toIso8601String(),
      'match':     match.isEmpty ? sel : match,
      'selection': sel,
      'stake':     stake,
      'odds':      odds,
      'status':    'pending',
      'pnl':       0.0,
      if (widget.modelPct != null) 'modelPct': widget.modelPct,
    });
    Navigator.of(context).pop();
  }
}


// ─── ACCOUNT TAB ─────────────────────────────────────────────────────────────

class AccountTab extends StatefulWidget {
  const AccountTab({super.key});

  @override
  State<AccountTab> createState() => _AccountTabState();
}

class _AccountTabState extends State<AccountTab> {
  double _alertThreshold = globalAlertThreshold;

  List<Map<String, dynamic>> get _edgesAboveThreshold {
    final t = _alertThreshold.round();
    return computeAllEdges().where((e) => (e['edge'] as int) >= t).toList();
  }

  @override
  Widget build(BuildContext context) {
    final edges = _edgesAboveThreshold;
    final threshold = _alertThreshold.round();

    return Scaffold(
      backgroundColor: kBg,
      appBar: buildAppBar('Account', context),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Profile card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Container(
                width: 54, height: 54,
                decoration: BoxDecoration(
                  color: kGreen.withOpacity(0.12), shape: BoxShape.circle,
                  border: Border.all(color: kGreen.withOpacity(0.35)),
                ),
                child: const Center(child: Icon(Icons.person, color: kGreen, size: 28)),
              ),
              const SizedBox(width: 14),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Guest User', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                const SizedBox(height: 5),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: kGreen.withOpacity(0.1), borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: kGreen.withOpacity(0.3)),
                  ),
                  child: const Text('Free Plan', style: TextStyle(color: kGreen, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ]),
            ]),
          ),

          const SizedBox(height: 18),

          // Edge alerts settings
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('⚡', style: TextStyle(fontSize: 15)),
                const SizedBox(width: 8),
                const Text('EDGE ALERTS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14, letterSpacing: 0.5)),
                const Spacer(),
                GestureDetector(
                  onTap: () => showEdgeExplainer(context),
                  child: const Icon(Icons.help_outline, color: Colors.grey, size: 18),
                ),
              ]),
              const SizedBox(height: 5),
              Text('Notify me when model finds an edge above my threshold',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
              const SizedBox(height: 18),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Alert when edge ≥', style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: kGreen.withOpacity(0.15), borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: kGreen.withOpacity(0.4)),
                  ),
                  child: Text('+$threshold%', style: const TextStyle(color: kGreen, fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              ]),
              const SizedBox(height: 8),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: kGreen,
                  inactiveTrackColor: Colors.grey.shade800,
                  thumbColor: kGreen,
                  overlayColor: kGreen.withOpacity(0.2),
                  valueIndicatorColor: kGreen,
                  valueIndicatorTextStyle: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700),
                ),
                child: Slider(
                  value: _alertThreshold, min: 1, max: 15, divisions: 14,
                  label: '+$threshold%',
                  onChanged: (v) {
                    setState(() => _alertThreshold = v);
                    globalAlertThreshold = v;
                    // Clear notified cache so user gets fresh alerts at new threshold
                    _notifiedEdges.clear();
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('+1%', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                  Text('+15%', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                ]),
              ),
              const SizedBox(height: 16),

              // Live preview of matches above threshold
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(8)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('Matches above +$threshold% now', style: TextStyle(color: Colors.grey.shade400, fontSize: 12, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: edges.isEmpty ? Colors.grey.shade900 : kGreen.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('${edges.length}',
                          style: TextStyle(color: edges.isEmpty ? Colors.grey : kGreen, fontWeight: FontWeight.w700, fontSize: 12)),
                    ),
                  ]),
                  if (edges.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ...edges.take(5).map((e) {
                      final m = e['match'] as Map<String, dynamic>;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${m['home']} v ${m['away']}',
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                            Text(e['market'] as String,
                                style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
                          ])),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: kGreen.withOpacity(0.12), borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: kGreen.withOpacity(0.3)),
                            ),
                            child: Text('+${e['edge']}%',
                                style: const TextStyle(color: kGreen, fontWeight: FontWeight.w700, fontSize: 12)),
                          ),
                        ]),
                      );
                    }),
                    if (edges.length > 5)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('+ ${edges.length - 5} more', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                      ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Center(child: Text('No edges above +$threshold% right now',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12))),
                    ),
                ]),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: kGreen.withOpacity(0.1), borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kGreen.withOpacity(0.4)),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.notifications_active_outlined, color: kGreen, size: 16),
                  const SizedBox(width: 8),
                  Text('Alerts on for +$threshold% edges', style: const TextStyle(color: kGreen, fontWeight: FontWeight.w700, fontSize: 13)),
                ]),
              ),
            ]),
          ),

          const SizedBox(height: 18),

          // Live session stats
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.bar_chart, color: Colors.grey, size: 16),
                const SizedBox(width: 8),
                Text('THIS SESSION', style: TextStyle(color: Colors.grey.shade400, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                _sessionStat('$sessionEdgesFound', 'Edges found', kGreen),
                const SizedBox(width: 12),
                _sessionStat('$sessionAlertsTriggered', 'Alerts sent', kOrange),
                const SizedBox(width: 12),
                _sessionStat('${allMatches.length}', 'Fixtures live', kBlue),
              ]),
              const SizedBox(height: 14),
              Text(updatedAgo(),
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ]),
          ),

          const SizedBox(height: 18),

          // Responsible gambling
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.withOpacity(0.25)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Text('⚠️', style: TextStyle(fontSize: 15)),
                SizedBox(width: 8),
                Text('RESPONSIBLE GAMBLING',
                    style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: 0.5)),
              ]),
              const SizedBox(height: 10),
              Text(
                'Gambling should be entertainment, not a source of income. '
                'Only bet what you can afford to lose. If gambling is affecting '
                'your life, help is available at BeGambleAware.org or by calling '
                'the National Gambling Helpline: 0808 8020 133 (free, 24/7).',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 12),
              Text(
                'OddsVision is for informational purposes only and does not '
                'constitute financial or betting advice. Probabilities shown are '
                'statistical estimates — past performance does not guarantee '
                'future results.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11, height: 1.5),
              ),
            ]),
          ),

          const SizedBox(height: 18),

          // Legal
          Container(
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              _legalTile(
                context,
                icon: Icons.description_outlined,
                label: 'Terms of Service',
                onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => const TermsOfServiceScreen(),
                )),
              ),
              Divider(height: 1, color: Colors.grey.shade900, indent: 52),
              _legalTile(
                context,
                icon: Icons.shield_outlined,
                label: 'Privacy Policy',
                onTap: () => launchUrl(
                  Uri.parse('https://mfranckeiss.github.io/OddsVision-backend/privacy/'),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ]),
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _legalTile(BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) =>
    InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(children: [
          Icon(icon, color: Colors.grey.shade500, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
          ),
          Icon(Icons.chevron_right, color: Colors.grey.shade700, size: 20),
        ]),
      ),
    );

  Widget _sessionStat(String value, String label, Color color) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(children: [
        Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey.shade500, fontSize: 10),
            textAlign: TextAlign.center),
      ]),
    ),
  );
}

// ─── SECTION HEADER ──────────────────────────────────────────────────────────

class SectionHeader extends StatelessWidget {
  final String title;
  const SectionHeader({super.key, required this.title});

  @override
  Widget build(BuildContext context) =>
      Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700));
}

// ─── MATCH CARD ──────────────────────────────────────────────────────────────

class MatchCard extends StatelessWidget {
  final Map<String, dynamic> match;
  const MatchCard({super.key, required this.match});

  @override
  Widget build(BuildContext context) {
    final home      = match['home'] as String;
    final away      = match['away'] as String;
    final homeEdge  = valueEdge(match['homePct'] as int, (match['bookieHomePct'] as int?) ?? (match['homePct'] as int));
    final countdown = kickoffCountdown(match['time'] as String);

    // Live score data from ESPN cache
    final homeScore  = _espnScores[home];
    final awayScore  = _espnScores[away];
    final isLive     = homeScore?['isLive'] == true || awayScore?['isLive'] == true;
    final isFinal    = homeScore?['isFinal'] == true || awayScore?['isFinal'] == true;
    final liveDetail = homeScore?['detail'] as String? ?? awayScore?['detail'] as String? ?? '';
    final homeGoals  = homeScore?['score'] as String? ?? '–';
    final awayGoals  = awayScore?['score'] as String? ?? '–';

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => MatchDetailScreen(match: match),
      )),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: kCard, borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isLive ? Colors.red.shade900 : Colors.grey.shade900),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Sport label + live badge or countdown
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(match['sport'],
                  style: const TextStyle(color: kGreen, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              if (isLive)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 6, height: 6,
                      decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text('LIVE $liveDetail', style: const TextStyle(color: Colors.red, fontSize: 11, fontWeight: FontWeight.w700)),
                ])
              else if (isFinal)
                Text('FT', style: TextStyle(color: Colors.grey.shade500, fontSize: 11, fontWeight: FontWeight.w700))
              else
                Text(countdown, style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
            ]),
            const SizedBox(height: 12),
            // Teams row
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                teamLogoWidget(home, 36, sportKey: match['sportKey'] as String? ?? 'football'),
                const SizedBox(height: 6),
                Text(home,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                _formRow(List<String>.from(match['homeForm'] ?? [])),
                const SizedBox(height: 6),
                _pctBadge(match['homePct'], kGreen),
              ])),
              // Centre column: score or draw/vs
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (isLive || isFinal) ...[
                    Text(homeGoals, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                    Text('–', style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
                    Text(awayGoals, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
                  ] else if (match['drawPct'] > 0) ...[
                    Text('Draw', style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
                    const SizedBox(height: 4),
                    _pctBadge(match['drawPct'], kOrange),
                  ] else
                    const Text('VS', style: TextStyle(color: Colors.grey, fontSize: 16)),
                ]),
              ),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                teamLogoWidget(away, 36, sportKey: match['sportKey'] as String? ?? 'football'),
                const SizedBox(height: 6),
                Text(away,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                    textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                _formRowRight(List<String>.from(match['awayForm'] ?? [])),
                const SizedBox(height: 6),
                _pctBadge(match['awayPct'], kBlue),
              ])),
            ]),
            const SizedBox(height: 12),
            _oddsRow(match),
            const SizedBox(height: 10),
            _probBar(match['homePct'], match['drawPct'], match['awayPct']),
            const SizedBox(height: 10),
            // Confidence badge + movement arrow
            Row(children: [
              confidenceBadge(match),
              const SizedBox(width: 8),
              movementArrow(oddsMovement(match, 'home')),
              const Spacer(),
              if (homeEdge >= 4) _valueBadge(homeEdge),
            ]),
            // Edge trend
            if (match['edgeTrend'] != null) ...[
              const SizedBox(height: 6),
              edgeTrendBadge(match['edgeTrend'] as Map<String, dynamic>?),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _formRow(List<String> form) => Row(
    children: form.map((r) => Container(
      margin: const EdgeInsets.only(right: 4),
      width: 18, height: 18,
      decoration: BoxDecoration(
        color: r == 'W' ? kGreen : r == 'D' ? kOrange : Colors.red,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Center(
        child: Text(r, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
      ),
    )).toList(),
  );

  Widget _formRowRight(List<String> form) => Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: form.map((r) => Container(
      margin: const EdgeInsets.only(left: 4),
      width: 18, height: 18,
      decoration: BoxDecoration(
        color: r == 'W' ? kGreen : r == 'D' ? kOrange : Colors.red,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Center(
        child: Text(r, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
      ),
    )).toList(),
  );

  Widget _valueBadge(int edge) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xFFFFD700).withOpacity(0.12),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.5)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      const Text('📊', style: TextStyle(fontSize: 11)),
      const SizedBox(width: 5),
      Text(
        'Model +$edge%',
        style: const TextStyle(color: Color(0xFFFFD700), fontSize: 11, fontWeight: FontWeight.w700),
      ),
    ]),
  );

  Widget _oddsRow(Map<String, dynamic> match) {
    final hasDraw = (match['drawPct'] as int) > 0;
    final bkms = match['bookmakers'] as List<dynamic>? ?? [];
    String bestHomeBk = '', bestDrawBk = '', bestAwayBk = '';
    int bestHomePct = 999, bestDrawPct = 999, bestAwayPct = 999;
    for (final b in bkms) {
      final bmap = b as Map;
      final name = bmap['name'] as String? ?? '';
      final hp = (bmap['homePct'] as int?) ?? 0;
      final dp = (bmap['drawPct'] as int?) ?? 0;
      final ap = (bmap['awayPct'] as int?) ?? 0;
      if (hp > 0 && hp < bestHomePct) { bestHomePct = hp; bestHomeBk = name; }
      if (dp > 0 && dp < bestDrawPct) { bestDrawPct = dp; bestDrawBk = name; }
      if (ap > 0 && ap < bestAwayPct) { bestAwayPct = ap; bestAwayBk = name; }
    }
    if (bestHomePct == 999) bestHomePct = (match['bookieHomePct'] as int?) ?? 0;
    if (bestDrawPct == 999) bestDrawPct = (match['bookieDrawPct'] as int?) ?? 0;
    if (bestAwayPct == 999) bestAwayPct = (match['bookieAwayPct'] as int?) ?? 0;
    return Row(children: [
      _oddsPill(match['home'] as String, pctToDecimalOdds(bestHomePct), kGreen, bestHomeBk),
      if (hasDraw) ...[
        const SizedBox(width: 6),
        _oddsPill('Draw', pctToDecimalOdds(bestDrawPct), kOrange, bestDrawBk),
      ],
      const SizedBox(width: 6),
      _oddsPill(match['away'] as String, pctToDecimalOdds(bestAwayPct), kBlue, bestAwayBk),
    ]);
  }

  Widget _oddsPill(String label, String odds, Color color, [String bookmaker = '']) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Column(children: [
        Text(odds, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(color: Colors.grey.shade500, fontSize: 9),
            maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
        if (bookmaker.isNotEmpty) ...[
          const SizedBox(height: 1),
          Text('@$bookmaker',
              style: TextStyle(color: color.withOpacity(0.55), fontSize: 8),
              maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
        ],
      ]),
    ),
  );

  Widget _pctBadge(int pct, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withOpacity(0.4)),
    ),
    child: Text('$pct%',
        style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 13)),
  );

  Widget _probBar(int home, int draw, int away) => ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: SizedBox(height: 6, child: Row(children: [
      Flexible(flex: home, child: Container(color: kGreen)),
      if (draw > 0) Flexible(flex: draw, child: Container(color: kOrange)),
      Flexible(flex: away, child: Container(color: kBlue)),
    ])),
  );
}

// ─── MATCH DETAIL SCREEN ─────────────────────────────────────────────────────

class MatchDetailScreen extends StatefulWidget {
  final Map<String, dynamic> match;
  const MatchDetailScreen({super.key, required this.match});

  @override
  State<MatchDetailScreen> createState() => _MatchDetailScreenState();
}

class _MatchDetailScreenState extends State<MatchDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tc;

  @override
  void initState() {
    super.initState();
    final key = widget.match['sportKey'] as String;
    _tc = TabController(
      length: (key == 'football' || key == 'darts') ? 2 : 1,
      vsync: this,
    );
  }

  @override
  void dispose() { _tc.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final key = widget.match['sportKey'] as String;
    final hasTabs = key == 'football' || key == 'darts';
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kCard,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context)),
        title: Text(widget.match['sport'],
            style: const TextStyle(color: kGreen, fontSize: 14, fontWeight: FontWeight.w700)),
        bottom: hasTabs
            ? TabBar(
                controller: _tc,
                indicatorColor: kGreen,
                labelColor: kGreen,
                unselectedLabelColor: Colors.grey,
                tabs: const [Tab(text: 'Overview'), Tab(text: 'All Markets')],
              )
            : null,
      ),
      body: hasTabs
          ? TabBarView(controller: _tc, children: [
              _OverviewTab(match: widget.match),
              key == 'darts'
                  ? _DartsMarketsTab(match: widget.match)
                  : _AllMarketsTab(match: widget.match),
            ])
          : _OverviewTab(match: widget.match),
    );
  }
}

// ─── OVERVIEW TAB ────────────────────────────────────────────────────────────

class _OverviewTab extends StatelessWidget {
  final Map<String, dynamic> match;
  const _OverviewTab({required this.match});

  @override
  Widget build(BuildContext context) {
    final injuries    = List<String>.from(match['injuries']    ?? []);
    final suspensions = List<String>.from(match['suspensions'] ?? []);
    final h2h         = match['h2h']         as Map<String, dynamic>?;
    final bookmakers = (match['bookmakers'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final trend      = match['edgeTrend'] as Map<String, dynamic>?;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        _header(),
        const SizedBox(height: 16),
        _aiCard(trend),
        if (h2h != null) ...[
          const SizedBox(height: 16),
          _h2hCard(h2h),
        ],
        if (injuries.isNotEmpty || suspensions.isNotEmpty) ...[
          const SizedBox(height: 16),
          _injuryCard(injuries, suspensions),
        ],
        if (bookmakers.isNotEmpty) ...[
          const SizedBox(height: 16),
          _oddsComparisonCard(bookmakers),
        ],
        const SizedBox(height: 16),
        _quickMarkets(context, bookmakers),
      ]),
    );
  }

  Widget _header() => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(10)),
    child: Column(children: [
      Text(match['time'], style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        _teamCol(match['home'], match['homePct'], kGreen),
        const Text('VS', style: TextStyle(color: Colors.grey, fontSize: 20)),
        _teamCol(match['away'], match['awayPct'], kBlue),
      ]),
      const SizedBox(height: 14),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        confidenceBadge(match),
        const SizedBox(width: 10),
        movementArrow(oddsMovement(match, 'home')),
      ]),
    ]),
  );

  Widget _teamCol(String name, int pct, Color color) => Column(children: [
    teamLogoWidget(name, 52, sportKey: match['sportKey'] as String? ?? 'football'),
    const SizedBox(height: 8),
    Text(name,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
        textAlign: TextAlign.center),
    const SizedBox(height: 8),
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text('$pct%',
          style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 22)),
    ),
  ]);

  Widget _aiCard(Map<String, dynamic>? trend) {
    final bookieHome = (match['bookieHomePct'] as int?) ?? (match['homePct'] as int);
    final bookieDraw = (match['bookieDrawPct'] as int?) ?? (match['drawPct'] as int);
    final bookieAway = (match['bookieAwayPct'] as int?) ?? (match['awayPct'] as int);
    final homeEdge = valueEdge(match['homePct'] as int, bookieHome);
    final awayEdge = valueEdge(match['awayPct'] as int, bookieAway);
    final isDevig = match['modelSource'] == 'devig_fallback';
    final _hXg = match['homeXg'] != null ? (match['homeXg'] as num).toDouble() : null;
    final _aXg = match['awayXg'] != null ? (match['awayXg'] as num).toDouble() : null;
    final markets = (match['sportKey'] == 'football' && _hXg != null && _aXg != null)
        ? _subMarkets(_hXg, _aXg) : null;

    Widget valueRow(String label, int aiPct, int bookiePct, Color col) {
      final edge = aiPct - bookiePct;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Text(label, style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
          const Spacer(),
          Text('$aiPct%', style: TextStyle(color: col, fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: (edge >= 4 ? const Color(0xFFFFD700) : Colors.grey.shade700).withOpacity(0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              edge >= 0 ? '+$edge% vs bookie' : '$edge% vs bookie',
              style: TextStyle(
                color: edge >= 4 ? const Color(0xFFFFD700) : Colors.grey.shade500,
                fontSize: 10, fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ]),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kGreen.withOpacity(0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.auto_awesome, color: kGreen, size: 16),
          const SizedBox(width: 6),
          Text(isDevig ? 'CONSENSUS ODDS' : 'STATISTICAL MODEL',
              style: const TextStyle(color: kGreen, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 0.5)),
          const Spacer(),
          edgeTrendBadge(trend),
        ]),
        const SizedBox(height: 12),
        const Text('Poisson model probabilities — based on historical goals, home advantage and team attack/defence ratings.',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 12),
        valueRow('Home win', match['homePct'] as int, bookieHome, kGreen),
        if (match['drawPct'] > 0)
          valueRow('Draw', match['drawPct'] as int, bookieDraw, kOrange),
        valueRow('Away win', match['awayPct'] as int, bookieAway, kBlue),
        if (homeEdge >= 4 || awayEdge >= 4) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFD700).withOpacity(0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.3)),
            ),
            child: Row(children: [
              const Text('🔥', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 6),
              Expanded(child: Text(
                homeEdge >= awayEdge
                    ? '${isDevig ? "Consensus shows" : "Model estimates"} a +$homeEdge% edge on ${match['home']} Win vs bookmaker implied odds.'
                    : '${isDevig ? "Consensus shows" : "Model estimates"} a +$awayEdge% edge on ${match['away']} Win vs bookmaker implied odds.',
                style: const TextStyle(color: Color(0xFFFFD700), fontSize: 12),
              )),
            ]),
          ),
        ],
        if (markets != null) ...[
          const Divider(color: Colors.grey, height: 24),
          _row('Both teams to score', '${markets['btts']}%', Colors.white),
          _row('Over 2.5 goals',      '${markets['over25']}%', Colors.white),
          _row('Over 1.5 goals',      '${markets['over15']}%', Colors.white),
          _row('Clean sheet (home)',  '${markets['csHome']}%', Colors.white),
          _row('Clean sheet (away)',  '${markets['csAway']}%', Colors.white),
        ],
      ]),
    );
  }

  Widget _row(String label, String value, Color color) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(label, style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
      Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13)),
    ]),
  );

  Widget _h2hCard(Map<String, dynamic> h2h) {
    final homeW  = h2h['homeWins'] as int;
    final draws  = h2h['draws']    as int;
    final awayW  = h2h['awayWins'] as int;
    final total  = homeW + draws + awayW;
    final label  = h2h['label']    as String;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.history, color: Colors.grey, size: 14),
          const SizedBox(width: 6),
          Text('HEAD TO HEAD', style: TextStyle(color: Colors.grey.shade400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
          const Spacer(),
          Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(match['home'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 4),
            Text('$homeW ${homeW == 1 ? 'win' : 'wins'}', style: const TextStyle(color: kGreen, fontWeight: FontWeight.w800, fontSize: 20)),
          ])),
          Column(children: [
            Text('$draws', style: TextStyle(color: Colors.grey.shade400, fontWeight: FontWeight.w800, fontSize: 20)),
            Text('draws', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
          ]),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(match['away'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13), textAlign: TextAlign.right),
            const SizedBox(height: 4),
            Text('$awayW ${awayW == 1 ? 'win' : 'wins'}', style: const TextStyle(color: kBlue, fontWeight: FontWeight.w800, fontSize: 20)),
          ])),
        ]),
        if (total > 0) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(height: 6, child: Row(children: [
              if (homeW > 0) Flexible(flex: homeW, child: Container(color: kGreen)),
              if (draws > 0) Flexible(flex: draws, child: Container(color: Colors.grey.shade600)),
              if (awayW > 0) Flexible(flex: awayW, child: Container(color: kBlue)),
            ])),
          ),
        ],
      ]),
    );
  }

  Widget _injuryCard(List<String> injuries, List<String> suspensions) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: kCard, borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.orange.withOpacity(0.3)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 15),
        const SizedBox(width: 6),
        Text('TEAM NEWS', style: TextStyle(color: Colors.orange.shade300, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
      ]),
      const SizedBox(height: 10),
      if (injuries.isNotEmpty) ...[
        Wrap(spacing: 8, runSpacing: 8, children: injuries.map((p) => _playerChip(p, '🤕', Colors.red)).toList()),
        const SizedBox(height: 6),
        Text('${injuries.join(', ')} — Injury doubt', style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
      ],
      if (injuries.isNotEmpty && suspensions.isNotEmpty) const SizedBox(height: 8),
      if (suspensions.isNotEmpty) ...[
        Wrap(spacing: 8, runSpacing: 8, children: suspensions.map((p) => _playerChip(p, '🟥', Colors.orange)).toList()),
        const SizedBox(height: 6),
        Text('${suspensions.join(', ')} — Suspended', style: TextStyle(color: Colors.grey.shade500, fontSize: 11)),
      ],
    ]),
  );

  Widget _playerChip(String name, String emoji, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.4)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(emoji, style: const TextStyle(fontSize: 11)),
      const SizedBox(width: 5),
      Text(name, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    ]),
  );

  Widget _quickMarkets(BuildContext context, List<Map<String, dynamic>> bookmakers) {
    final mn = '${match['home']} v ${match['away']}';
    final bH = (match['bookieHomePct'] as int?) ?? (match['homePct'] as int);
    final bD = (match['bookieDrawPct'] as int?) ?? (match['drawPct'] as int);
    final bA = (match['bookieAwayPct'] as int?) ?? (match['awayPct'] as int);
    final opts = [
      {'label': '${match['home']} Win', 'pct': match['homePct'], 'bookiePct': bH, 'key': 'homePct'},
      if (match['drawPct'] > 0) {'label': 'Draw', 'pct': match['drawPct'], 'bookiePct': bD, 'key': 'drawPct'},
      {'label': '${match['away']} Win', 'pct': match['awayPct'], 'bookiePct': bA, 'key': 'awayPct'},
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('MATCH RESULT',
          style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
      const SizedBox(height: 8),
      Row(children: opts.map((opt) => Expanded(child: Padding(
        padding: const EdgeInsets.only(right: 6),
        child: _MarketButton(
          label: opt['label'] as String, pct: opt['pct'] as int,
          bookiePct: opt['bookiePct'] as int?,
          onTap: () => _showLogBetSheet(
            context,
            match: mn,
            selection: opt['label'] as String,
            modelPct: (opt['pct'] as num?)?.toDouble(),
          ),
        ),
      ))).toList()),
      if (bookmakers.isNotEmpty) ...[
        const SizedBox(height: 10),
        Row(children: opts.map((opt) => Expanded(child: Padding(
          padding: const EdgeInsets.only(right: 6),
          child: GestureDetector(
            onTap: () => showBetBottomSheet(
              context,
              opt['label'] as String,
              opt['pct'] as int,
              opt['key'] as String,
              bookmakers,
              modelSource: match['modelSource'] as String? ?? '',
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2E1E),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: kGreen.withOpacity(0.35)),
              ),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.open_in_new, color: kGreen, size: 11),
                SizedBox(width: 4),
                Text('BET THIS', style: TextStyle(color: kGreen, fontSize: 10, fontWeight: FontWeight.w800)),
              ]),
            ),
          ),
        ))).toList()),
      ],
    ]);
  }

  Widget _oddsComparisonCard(List<Map<String, dynamic>> bookmakers) {
    final hasDraw = (match['drawPct'] as int) > 0;

    // Find best (lowest implied pct) per outcome
    int bestHome = 999, bestDraw = 999, bestAway = 999;
    for (final b in bookmakers) {
      final h = (b['homePct'] as int?) ?? 0;
      final d = (b['drawPct'] as int?) ?? 0;
      final a = (b['awayPct'] as int?) ?? 0;
      if (h > 0 && h < bestHome) bestHome = h;
      if (d > 0 && d < bestDraw) bestDraw = d;
      if (a > 0 && a < bestAway) bestAway = a;
    }

    Widget oddsCell(int pct, bool isBest) {
      final odds = pctToDecimalOdds(pct);
      return Expanded(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: isBest
                ? BoxDecoration(color: kGreen.withOpacity(0.15), borderRadius: BorderRadius.circular(4))
                : null,
            child: Text(
              pct > 0 ? odds : '—',
              style: TextStyle(
                color: isBest ? kGreen : Colors.white,
                fontWeight: isBest ? FontWeight.w800 : FontWeight.w500,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
    }

    Widget headerCell(String text) => Expanded(
      child: Center(
        child: Text(text, style: TextStyle(color: Colors.grey.shade500, fontSize: 10, fontWeight: FontWeight.w600)),
      ),
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.compare_arrows, color: Colors.grey, size: 14),
          const SizedBox(width: 6),
          Text('ODDS COMPARISON', style: TextStyle(color: Colors.grey.shade400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
          const Spacer(),
          Text('Decimal odds', style: TextStyle(color: Colors.grey.shade700, fontSize: 10)),
        ]),
        const SizedBox(height: 12),
        // Header row
        Row(children: [
          SizedBox(width: 90, child: Text('Bookmaker', style: TextStyle(color: Colors.grey.shade600, fontSize: 10))),
          headerCell(match['home'] as String),
          if (hasDraw) headerCell('Draw'),
          headerCell(match['away'] as String),
        ]),
        const SizedBox(height: 8),
        ...bookmakers.map((b) {
          final h = (b['homePct'] as int?) ?? 0;
          final d = (b['drawPct'] as int?) ?? 0;
          final a = (b['awayPct'] as int?) ?? 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              SizedBox(
                width: 90,
                child: Text(b['name'] as String,
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
              oddsCell(h, h == bestHome),
              if (hasDraw) oddsCell(d, d == bestDraw && d > 0),
              oddsCell(a, a == bestAway),
            ]),
          );
        }),
        const SizedBox(height: 4),
        Text('🟢 Highlighted = best available odds', style: TextStyle(color: Colors.grey.shade700, fontSize: 10)),
      ]),
    );
  }
}

// ─── ALL MARKETS TAB ─────────────────────────────────────────────────────────

class _AllMarketsTab extends StatelessWidget {
  final Map<String, dynamic> match;
  const _AllMarketsTab({required this.match});

  String get mn => '${match['home']} v ${match['away']}';
  List<String> get homePlayers => List<String>.from(match['homePlayers'] ?? []);
  List<String> get awayPlayers => List<String>.from(match['awayPlayers'] ?? []);
  List<String> get allPlayers => [...homePlayers, ...awayPlayers];

  List<String> get injuries    => List<String>.from(match['injuries']    ?? []);
  List<String> get suspensions => List<String>.from(match['suspensions'] ?? []);

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      _Section('⚽  Match Betting',           _matchBetting(),   mn, expanded: true),
      _Section('🕐  Half Time',               _halfTime(),       mn),
      _Section('🎯  Goals',                   _goals(),          mn),
      _Section('🔢  Correct Score',           _correctScore(),   mn),
      _Section('🟡  Cards',                   _cards(),          mn),
      _Section('🚩  Corners',                 _corners(),        mn),
      _Section('🧤  Clean Sheets',            _cleanSheets(),    mn),
      _Section('⏱️  Time of First Goal',      _firstGoalTime(),  mn),
    ],
  );

  // ── MATCH BETTING ──────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _matchBetting() => [
    {'name': 'Match Result', 'options': [
      {'label': '${match['home']} Win', 'pct': match['homePct']},
      if (match['drawPct'] > 0) {'label': 'Draw', 'pct': match['drawPct']},
      {'label': '${match['away']} Win', 'pct': match['awayPct']},
    ]},
    {'name': 'Double Chance', 'options': [
      {'label': '${match['home']} or Draw', 'pct': (match['homePct'] as int) + (match['drawPct'] as int)},
      {'label': 'Home or Away',             'pct': (match['homePct'] as int) + (match['awayPct'] as int)},
      {'label': 'Draw or ${match['away']}', 'pct': (match['drawPct'] as int) + (match['awayPct'] as int)},
    ]},
    {'name': 'Draw No Bet', 'options': [
      {'label': match['home'], 'pct': 67},
      {'label': match['away'], 'pct': 33},
    ]},
    {'name': 'Both Teams to Score', 'options': [
      {'label': 'Yes', 'pct': 71},
      {'label': 'No',  'pct': 29},
    ]},
    {'name': 'Result & BTTS', 'options': [
      {'label': '${match['home']} Win & Yes', 'pct': 38},
      {'label': 'Draw & Yes',                 'pct': 11},
      {'label': '${match['away']} Win & Yes', 'pct': 21},
      {'label': '${match['home']} Win & No',  'pct': 24},
    ]},
    {'name': 'Asian Handicap', 'options': [
      {'label': '${match['home']} -0.5', 'pct': 62},
      {'label': '${match['home']} -1',   'pct': 38},
      {'label': '${match['away']} +0.5', 'pct': 38},
      {'label': '${match['away']} +1',   'pct': 62},
    ]},
    {'name': 'To Win Either Half', 'options': [
      {'label': match['home'], 'pct': 71},
      {'label': match['away'], 'pct': 52},
    ]},
    {'name': 'To Win Both Halves', 'options': [
      {'label': match['home'], 'pct': 28},
      {'label': match['away'], 'pct': 14},
    ]},
    {'name': 'To Score in Both Halves', 'options': [
      {'label': match['home'], 'pct': 42},
      {'label': match['away'], 'pct': 28},
    ]},
  ];

  // ── HALF TIME ──────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _halfTime() => [
    {'name': 'Half Time Result', 'options': [
      {'label': '${match['home']} HT Win', 'pct': 38},
      {'label': 'Draw HT',                 'pct': 42},
      {'label': '${match['away']} HT Win', 'pct': 20},
    ]},
    {'name': 'Half Time / Full Time', 'options': [
      {'label': 'Home / Home',  'pct': 32},
      {'label': 'Draw / Home',  'pct': 22},
      {'label': 'Away / Away',  'pct': 14},
      {'label': 'Draw / Draw',  'pct': 10},
      {'label': 'Home / Draw',  'pct': 8},
      {'label': 'Draw / Away',  'pct': 7},
    ]},
    {'name': 'BTTS 1st Half', 'options': [
      {'label': 'Yes', 'pct': 32},
      {'label': 'No',  'pct': 68},
    ]},
    {'name': 'BTTS 2nd Half', 'options': [
      {'label': 'Yes', 'pct': 48},
      {'label': 'No',  'pct': 52},
    ]},
    {'name': 'Most Goals — Which Half', 'options': [
      {'label': '1st Half', 'pct': 28},
      {'label': '2nd Half', 'pct': 56},
      {'label': 'Equal',    'pct': 16},
    ]},
  ];

  // ── GOALS ──────────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _goals() {
    final rt = (match['realTotals'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final rs = match['realSpread'] as Map<String, dynamic>?;

    // Build over options from real totals if available
    final overOpts = rt.isNotEmpty
        ? rt.map((t) => {'label': 'Over ${t['line']}',  'pct': t['overPct']  as int}).toList()
        : <Map<String, dynamic>>[
            {'label': 'Over 0.5', 'pct': 96},
            {'label': 'Over 1.5', 'pct': 82},
            {'label': 'Over 2.5', 'pct': 58},
            {'label': 'Over 3.5', 'pct': 34},
            {'label': 'Over 4.5', 'pct': 18},
            {'label': 'Over 5.5', 'pct': 8},
          ];

    final underOpts = rt.isNotEmpty
        ? rt.map((t) => {'label': 'Under ${t['line']}', 'pct': t['underPct'] as int}).toList()
        : <Map<String, dynamic>>[
            {'label': 'Under 1.5', 'pct': 18},
            {'label': 'Under 2.5', 'pct': 42},
            {'label': 'Under 3.5', 'pct': 66},
            {'label': 'Under 4.5', 'pct': 82},
            {'label': 'Under 5.5', 'pct': 92},
          ];

    return [
    {'name': rt.isNotEmpty ? 'Match Goals — Over  ✓ Live' : 'Match Goals — Over', 'options': overOpts},
    {'name': rt.isNotEmpty ? 'Match Goals — Under  ✓ Live' : 'Match Goals — Under', 'options': underOpts},
    if (rs != null) {'name': 'Handicap  ✓ Live', 'options': [
      {'label': '${match['home']} ${rs['line'] > 0 ? '+' : ''}${rs['line']}', 'pct': rs['homePct'] as int},
      {'label': '${match['away']} ${(-(rs['line'] as double)) > 0 ? '+' : ''}${-(rs['line'] as double)}', 'pct': rs['awayPct'] as int},
    ]},
    {'name': '1st Half Goals', 'options': [
      {'label': 'Over 0.5',  'pct': 72},
      {'label': 'Over 1.5',  'pct': 38},
      {'label': 'Under 0.5', 'pct': 28},
      {'label': 'Under 1.5', 'pct': 62},
    ]},
    {'name': '2nd Half Goals', 'options': [
      {'label': 'Over 0.5',  'pct': 78},
      {'label': 'Over 1.5',  'pct': 48},
      {'label': 'Under 0.5', 'pct': 22},
      {'label': 'Under 1.5', 'pct': 52},
    ]},
    {'name': '${match['home']} Total Goals', 'options': [
      {'label': 'Over 0.5',  'pct': 72},
      {'label': 'Over 1.5',  'pct': 44},
      {'label': 'Under 0.5', 'pct': 28},
      {'label': 'Under 1.5', 'pct': 56},
    ]},
    {'name': '${match['away']} Total Goals', 'options': [
      {'label': 'Over 0.5',  'pct': 62},
      {'label': 'Over 1.5',  'pct': 32},
      {'label': 'Under 0.5', 'pct': 38},
      {'label': 'Under 1.5', 'pct': 68},
    ]},
    {'name': 'First Goal', 'options': [
      {'label': match['home'], 'pct': 55},
      {'label': match['away'], 'pct': 36},
      {'label': 'No Goal',     'pct': 9},
    ]},
    {'name': 'Last Goal', 'options': [
      {'label': match['home'], 'pct': 52},
      {'label': match['away'], 'pct': 39},
      {'label': 'No Goal',     'pct': 9},
    ]},
    {'name': '${match['home']} 1st Half Goals', 'options': [
      {'label': 'Over 0.5',  'pct': 52},
      {'label': 'Under 0.5', 'pct': 48},
    ]},
    {'name': '${match['away']} 1st Half Goals', 'options': [
      {'label': 'Over 0.5',  'pct': 40},
      {'label': 'Under 0.5', 'pct': 60},
    ]},
    ];
  }

  // ── GOALSCORER ─────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _goalscorer() {
    final ps = allPlayers.isEmpty
        ? ['Player A', 'Player B', 'Player C', 'Player D', 'Player E', 'Player F']
        : allPlayers;
    final pcts = [38, 32, 28, 24, 22, 20, 18, 16, 14, 12, 11, 10, 9, 8];
    List<Map<String, dynamic>> opts(List<String> list, [int div = 1]) =>
        list.asMap().entries.map((e) {
          final p = (pcts[e.key.clamp(0, pcts.length - 1)] / div).round();
          return {'label': e.value, 'pct': p.clamp(1, 99)};
        }).toList();
    return [
      {'name': 'Anytime Goalscorer',  'options': opts(ps)},
      {'name': 'First Goalscorer',    'options': opts(ps)},
      {'name': 'Last Goalscorer',     'options': opts(ps)},
      {'name': 'To Score 2 or More',  'options': opts(ps.take(8).toList(), 2)},
      {'name': 'Hat-trick',           'options': opts(ps.take(6).toList(), 8)},
      {'name': 'To Score a Header',   'options': opts(ps.take(6).toList(), 3)},
      {'name': 'To Score a Penalty',  'options': opts(ps.take(4).toList(), 5)},
      {'name': 'To Score Direct Free Kick', 'options': opts(ps.take(4).toList(), 10)},
    ];
  }

  // ── CORRECT SCORE ──────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _correctScore() {
    final h = match['home'] as String;
    final a = match['away'] as String;
    return [
      {'name': 'Correct Score', 'options': [
        {'label': '1–0 $h', 'pct': 16},
        {'label': '2–0 $h', 'pct': 12},
        {'label': '2–1 $h', 'pct': 14},
        {'label': '3–0 $h', 'pct': 6},
        {'label': '3–1 $h', 'pct': 7},
        {'label': '3–2 $h', 'pct': 4},
        {'label': '0–0',    'pct': 8},
        {'label': '1–1',    'pct': 10},
        {'label': '2–2',    'pct': 5},
        {'label': '0–1 $a', 'pct': 8},
        {'label': '1–2 $a', 'pct': 7},
        {'label': '0–2 $a', 'pct': 5},
        {'label': '0–3 $a', 'pct': 3},
      ]},
      {'name': 'Half Time Correct Score', 'options': [
        {'label': '0–0', 'pct': 28},
        {'label': '1–0', 'pct': 22},
        {'label': '0–1', 'pct': 14},
        {'label': '1–1', 'pct': 12},
        {'label': '2–0', 'pct': 10},
        {'label': '0–2', 'pct': 6},
      ]},
    ];
  }

  // ── CARDS ──────────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _cards() => [
    {'name': 'Total Cards — Over', 'options': [
      {'label': 'Over 1.5', 'pct': 88},
      {'label': 'Over 2.5', 'pct': 66},
      {'label': 'Over 3.5', 'pct': 42},
      {'label': 'Over 4.5', 'pct': 24},
      {'label': 'Over 5.5', 'pct': 12},
    ]},
    {'name': 'Total Cards — Under', 'options': [
      {'label': 'Under 2.5', 'pct': 34},
      {'label': 'Under 3.5', 'pct': 58},
      {'label': 'Under 4.5', 'pct': 76},
    ]},
    {'name': '${match['home']} Cards', 'options': [
      {'label': 'Over 0.5',  'pct': 74},
      {'label': 'Over 1.5',  'pct': 44},
      {'label': 'Over 2.5',  'pct': 22},
      {'label': 'Under 1.5', 'pct': 56},
    ]},
    {'name': '${match['away']} Cards', 'options': [
      {'label': 'Over 0.5',  'pct': 71},
      {'label': 'Over 1.5',  'pct': 38},
      {'label': 'Over 2.5',  'pct': 18},
      {'label': 'Under 1.5', 'pct': 62},
    ]},
    {'name': 'Card in Each Half', 'options': [
      {'label': 'Yes', 'pct': 62},
      {'label': 'No',  'pct': 38},
    ]},
  ];

  // ── CORNERS ────────────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _corners() => [
    {'name': 'Total Corners — Over', 'options': [
      {'label': 'Over 6.5',  'pct': 82},
      {'label': 'Over 7.5',  'pct': 72},
      {'label': 'Over 8.5',  'pct': 58},
      {'label': 'Over 9.5',  'pct': 44},
      {'label': 'Over 10.5', 'pct': 32},
      {'label': 'Over 11.5', 'pct': 21},
    ]},
    {'name': 'Total Corners — Under', 'options': [
      {'label': 'Under 8.5',  'pct': 42},
      {'label': 'Under 9.5',  'pct': 56},
      {'label': 'Under 10.5', 'pct': 68},
      {'label': 'Under 11.5', 'pct': 79},
    ]},
    {'name': '1st Half Corners', 'options': [
      {'label': 'Over 3.5',  'pct': 62},
      {'label': 'Over 4.5',  'pct': 44},
      {'label': 'Under 3.5', 'pct': 38},
      {'label': 'Under 4.5', 'pct': 56},
    ]},
    {'name': '2nd Half Corners', 'options': [
      {'label': 'Over 4.5',  'pct': 58},
      {'label': 'Over 5.5',  'pct': 38},
      {'label': 'Under 4.5', 'pct': 42},
      {'label': 'Under 5.5', 'pct': 62},
    ]},
    {'name': '${match['home']} Corners', 'options': [
      {'label': 'Over 4.5',  'pct': 54},
      {'label': 'Over 5.5',  'pct': 36},
      {'label': 'Under 4.5', 'pct': 46},
      {'label': 'Under 5.5', 'pct': 64},
    ]},
    {'name': '${match['away']} Corners', 'options': [
      {'label': 'Over 3.5',  'pct': 52},
      {'label': 'Over 4.5',  'pct': 34},
      {'label': 'Under 3.5', 'pct': 48},
      {'label': 'Under 4.5', 'pct': 66},
    ]},
    {'name': 'Most Corners', 'options': [
      {'label': match['home'], 'pct': 58},
      {'label': match['away'], 'pct': 32},
      {'label': 'Equal',       'pct': 10},
    ]},
    {'name': 'First Corner', 'options': [
      {'label': match['home'], 'pct': 56},
      {'label': match['away'], 'pct': 44},
    ]},
    {'name': 'Last Corner', 'options': [
      {'label': match['home'], 'pct': 54},
      {'label': match['away'], 'pct': 46},
    ]},
    {'name': 'Asian Corners', 'options': [
      {'label': '${match['home']} -1.5', 'pct': 52},
      {'label': '${match['away']} +1.5', 'pct': 48},
    ]},
  ];

  // ── PLAYER STATS ───────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _playerStats() {
    final ps = allPlayers.isEmpty
        ? ['Player A', 'Player B', 'Player C', 'Player D', 'Player E', 'Player F']
        : allPlayers.take(6).toList();
    List<Map<String, dynamic>> pOpts(int base) => ps.asMap().entries.map((e) =>
        {'label': e.value, 'pct': (base - e.key * 4).clamp(4, base)}).toList();
    return [
      {'name': 'Total Shots — Over', 'options': [
        {'label': 'Over 19.5', 'pct': 62},
        {'label': 'Over 22.5', 'pct': 44},
        {'label': 'Over 24.5', 'pct': 28},
      ]},
      {'name': 'Shots on Target — Over', 'options': [
        {'label': 'Over 7.5',  'pct': 58},
        {'label': 'Over 9.5',  'pct': 36},
        {'label': 'Over 11.5', 'pct': 18},
      ]},
      {'name': 'Player Shots on Target 2+', 'options': pOpts(42)},
      {'name': 'Player Shots on Target 3+', 'options': pOpts(22)},
      {'name': 'Total Fouls — Over', 'options': [
        {'label': 'Over 17.5', 'pct': 66},
        {'label': 'Over 19.5', 'pct': 48},
        {'label': 'Over 21.5', 'pct': 32},
      ]},
      {'name': 'Total Offsides — Over', 'options': [
        {'label': 'Over 1.5', 'pct': 72},
        {'label': 'Over 2.5', 'pct': 52},
        {'label': 'Over 3.5', 'pct': 31},
      ]},
      {'name': 'Total Throw-ins — Over', 'options': [
        {'label': 'Over 29.5', 'pct': 62},
        {'label': 'Over 32.5', 'pct': 44},
        {'label': 'Over 35.5', 'pct': 28},
      ]},
      {'name': 'GK Saves — Over', 'options': [
        {'label': 'Over 4.5', 'pct': 66},
        {'label': 'Over 6.5', 'pct': 42},
        {'label': 'Over 8.5', 'pct': 22},
      ]},
      {'name': 'Player Assists', 'options': pOpts(28)},
    ];
  }

  // ── CLEAN SHEETS ───────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _cleanSheets() => [
    {'name': 'Clean Sheet', 'options': [
      {'label': '${match['home']}', 'pct': 34},
      {'label': '${match['away']}', 'pct': 22},
      {'label': 'Either Team',     'pct': 52},
      {'label': 'Neither Team',    'pct': 48},
    ]},
    {'name': 'Clean Sheet 1st Half', 'options': [
      {'label': '${match['home']}', 'pct': 48},
      {'label': '${match['away']}', 'pct': 36},
    ]},
    {'name': 'Goalkeeper to Keep Clean Sheet', 'options': [
      {'label': '${match['home']} GK', 'pct': 34},
      {'label': '${match['away']} GK', 'pct': 22},
    ]},
  ];

  // ── TIME OF FIRST GOAL ─────────────────────────────────────────────────────
  List<Map<String, dynamic>> _firstGoalTime() => [
    {'name': 'Time of First Goal', 'options': [
      {'label': '1–15 mins',  'pct': 22},
      {'label': '16–30 mins', 'pct': 18},
      {'label': '31–45 mins', 'pct': 16},
      {'label': '46–60 mins', 'pct': 18},
      {'label': '61–75 mins', 'pct': 15},
      {'label': '76–90 mins', 'pct': 11},
    ]},
    {'name': 'Next Goal', 'options': [
      {'label': match['home'], 'pct': 52},
      {'label': match['away'], 'pct': 38},
      {'label': 'No More Goals', 'pct': 10},
    ]},
    {'name': 'Goal in Each Half', 'options': [
      {'label': 'Yes', 'pct': 66},
      {'label': 'No',  'pct': 34},
    ]},
    {'name': 'First Substitution Before 45 mins', 'options': [
      {'label': 'Yes', 'pct': 38},
      {'label': 'No',  'pct': 62},
    ]},
  ];

  // ── SCORECAST / WINCAST ────────────────────────────────────────────────────
  List<Map<String, dynamic>> _scorecast() {
    final ps = allPlayers.isEmpty
        ? ['Player A', 'Player B', 'Player C', 'Player D']
        : allPlayers.take(5).toList();
    return [
      {'name': 'Scorecast — ${match['home']} Win', 'options': ps.asMap().entries.map((e) =>
          {'label': '${e.value} 1st & ${match['home']} Win', 'pct': (18 - e.key * 3).clamp(4, 18)}).toList()},
      {'name': 'Wincast — ${match['home']} Win',   'options': ps.asMap().entries.map((e) =>
          {'label': '${e.value} Scores & ${match['home']} Win', 'pct': (22 - e.key * 3).clamp(5, 22)}).toList()},
    ];
  }
}

// ─── MARKET SECTION (COLLAPSIBLE) ────────────────────────────────────────────

class _Section extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> markets;
  final String matchName;
  final bool expanded;
  final List<String> injuries;
  final List<String> suspensions;

  const _Section(
    this.title, this.markets, this.matchName, {
    this.expanded = false,
    this.injuries = const [],
    this.suspensions = const [],
  });

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  late bool _open;

  @override
  void initState() {
    super.initState();
    _open = widget.expanded;
  }

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(10)),
    child: Column(children: [
      GestureDetector(
        onTap: () => setState(() => _open = !_open),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(widget.title,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
            Icon(_open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: Colors.grey),
          ]),
        ),
      ),
      if (_open) ...[
        Divider(color: Colors.grey.shade900, height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: widget.markets.map((m) => _MarketRow(
            market: m, matchName: widget.matchName,
            injuries: widget.injuries, suspensions: widget.suspensions,
          )).toList()),
        ),
      ],
    ]),
  );
}

// ─── MARKET ROW ──────────────────────────────────────────────────────────────

class _MarketRow extends StatelessWidget {
  final Map<String, dynamic> market;
  final String matchName;
  final List<String> injuries;
  final List<String> suspensions;

  const _MarketRow({
    required this.market,
    required this.matchName,
    this.injuries = const [],
    this.suspensions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final opts = market['options'] as List<Map<String, dynamic>>;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(market['name'] as String,
            style: TextStyle(color: Colors.grey.shade400, fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        opts.length <= 3 ? _row(context, opts) : _grid(context, opts),
      ]),
    );
  }

  Widget _row(BuildContext context, List<Map<String, dynamic>> opts) => Row(
    children: opts.map((opt) => Expanded(child: Padding(
      padding: const EdgeInsets.only(right: 6),
      child: _MarketButton(
        label: opt['label'] as String, pct: opt['pct'] as int,
        bookiePct: opt['bookiePct'] as int?,
        injuries: injuries, suspensions: suspensions,
        onTap: () => _add(context, opt),
      ),
    ))).toList(),
  );

  Widget _grid(BuildContext context, List<Map<String, dynamic>> opts) => Wrap(
    spacing: 6, runSpacing: 6,
    children: opts.map((opt) => SizedBox(
      width: (MediaQuery.of(context).size.width - 72) / 2,
      child: _MarketButton(
        label: opt['label'] as String, pct: opt['pct'] as int,
        bookiePct: opt['bookiePct'] as int?,
        injuries: injuries, suspensions: suspensions,
        onTap: () => _add(context, opt),
      ),
    )).toList(),
  );

  void _add(BuildContext context, Map<String, dynamic> opt) {
    _showLogBetSheet(
      context,
      match: matchName,
      selection: opt['label'] as String,
      modelPct: (opt['pct'] as num?)?.toDouble(),
    );
  }
}

// ─── DARTS MARKETS TAB ───────────────────────────────────────────────────────

class _DartsMarketsTab extends StatelessWidget {
  final Map<String, dynamic> match;
  const _DartsMarketsTab({required this.match});

  String get mn => '${match['home']} v ${match['away']}';
  String get p1 => match['home'] as String;
  String get p2 => match['away'] as String;
  int    get p1Pct => match['homePct'] as int;
  int    get p2Pct => match['awayPct'] as int;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      _Section('🎯  Match Betting',         _matchBetting(),    mn, expanded: true),
      _Section('📐  Handicap Betting',      _handicap(),        mn),
      _Section('🔢  Correct Score',         _correctScore(),    mn),
      _Section('💯  180s',                  _oneEighties(),     mn),
      _Section('🎰  Checkout Markets',      _checkouts(),       mn),
      _Section('📊  Legs & Sets',           _legsAndSets(),     mn),
      _Section('🏁  First Leg / Set',       _firstLeg(),        mn),
      _Section('📈  Averages',              _averages(),        mn),
    ],
  );

  List<Map<String, dynamic>> _matchBetting() => [
    {'name': 'Match Winner', 'options': [
      {'label': p1, 'pct': p1Pct},
      {'label': p2, 'pct': p2Pct},
    ]},
    {'name': 'To Win Without Losing a Leg', 'options': [
      {'label': p1, 'pct': 14},
      {'label': p2, 'pct': 9},
    ]},
    {'name': 'Match Goes to Deciding Leg', 'options': [
      {'label': 'Yes', 'pct': 38},
      {'label': 'No',  'pct': 62},
    ]},
    {'name': 'Match Goes to Deciding Set', 'options': [
      {'label': 'Yes', 'pct': 42},
      {'label': 'No',  'pct': 58},
    ]},
    {'name': 'Highest Individual Score in a Leg', 'options': [
      {'label': p1, 'pct': 54},
      {'label': p2, 'pct': 46},
    ]},
  ];

  List<Map<String, dynamic>> _handicap() => [
    {'name': 'Leg Handicap', 'options': [
      {'label': '$p1 -1.5 legs', 'pct': 44},
      {'label': '$p1 -2.5 legs', 'pct': 32},
      {'label': '$p1 +1.5 legs', 'pct': 66},
      {'label': '$p2 +1.5 legs', 'pct': 34},
      {'label': '$p2 -1.5 legs', 'pct': 38},
    ]},
    {'name': 'Set Handicap', 'options': [
      {'label': '$p1 -1.5 sets', 'pct': 36},
      {'label': '$p1 +1.5 sets', 'pct': 64},
      {'label': '$p2 -1.5 sets', 'pct': 34},
      {'label': '$p2 +1.5 sets', 'pct': 66},
    ]},
  ];

  List<Map<String, dynamic>> _correctScore() {
    // Typical PDC format: best of 7 sets (first to 4)
    return [
      {'name': 'Correct Score in Sets', 'options': [
        {'label': '4–0 $p1', 'pct': 12},
        {'label': '4–1 $p1', 'pct': 18},
        {'label': '4–2 $p1', 'pct': 16},
        {'label': '4–3 $p1', 'pct': 14},
        {'label': '3–4 $p2', 'pct': 12},
        {'label': '2–4 $p2', 'pct': 11},
        {'label': '1–4 $p2', 'pct': 10},
        {'label': '0–4 $p2', 'pct': 7},
      ]},
      {'name': 'Total Sets — Over/Under', 'options': [
        {'label': 'Over 4.5',  'pct': 72},
        {'label': 'Over 5.5',  'pct': 56},
        {'label': 'Over 6.5',  'pct': 38},
        {'label': 'Under 4.5', 'pct': 28},
        {'label': 'Under 5.5', 'pct': 44},
        {'label': 'Under 6.5', 'pct': 62},
      ]},
    ];
  }

  List<Map<String, dynamic>> _oneEighties() => [
    {'name': 'Most 180s', 'options': [
      {'label': p1,     'pct': 52},
      {'label': p2,     'pct': 38},
      {'label': 'Equal','pct': 10},
    ]},
    {'name': 'Total 180s — Over', 'options': [
      {'label': 'Over 2.5',  'pct': 88},
      {'label': 'Over 4.5',  'pct': 72},
      {'label': 'Over 6.5',  'pct': 54},
      {'label': 'Over 8.5',  'pct': 38},
      {'label': 'Over 10.5', 'pct': 22},
      {'label': 'Over 12.5', 'pct': 12},
    ]},
    {'name': 'Total 180s — Under', 'options': [
      {'label': 'Under 5.5',  'pct': 34},
      {'label': 'Under 7.5',  'pct': 52},
      {'label': 'Under 9.5',  'pct': 68},
      {'label': 'Under 11.5', 'pct': 82},
    ]},
    {'name': '$p1 180s — Over/Under', 'options': [
      {'label': 'Over 2.5',  'pct': 66},
      {'label': 'Over 3.5',  'pct': 48},
      {'label': 'Over 4.5',  'pct': 32},
      {'label': 'Under 2.5', 'pct': 34},
      {'label': 'Under 3.5', 'pct': 52},
    ]},
    {'name': '$p2 180s — Over/Under', 'options': [
      {'label': 'Over 2.5',  'pct': 60},
      {'label': 'Over 3.5',  'pct': 42},
      {'label': 'Over 4.5',  'pct': 26},
      {'label': 'Under 2.5', 'pct': 40},
      {'label': 'Under 3.5', 'pct': 58},
    ]},
    {'name': 'First 180', 'options': [
      {'label': p1,           'pct': 54},
      {'label': p2,           'pct': 42},
      {'label': 'No 180',    'pct': 4},
    ]},
    {'name': '180 in First Leg', 'options': [
      {'label': 'Yes', 'pct': 58},
      {'label': 'No',  'pct': 42},
    ]},
  ];

  List<Map<String, dynamic>> _checkouts() => [
    {'name': 'Highest Checkout', 'options': [
      {'label': p1, 'pct': 52},
      {'label': p2, 'pct': 48},
    ]},
    {'name': 'Highest Checkout — Over/Under', 'options': [
      {'label': 'Over 99.5',  'pct': 72},
      {'label': 'Over 119.5', 'pct': 52},
      {'label': 'Over 139.5', 'pct': 34},
      {'label': 'Over 159.5', 'pct': 18},
      {'label': 'Under 99.5', 'pct': 28},
    ]},
    {'name': '$p1 to Hit 100+ Checkout', 'options': [
      {'label': 'Yes', 'pct': 68},
      {'label': 'No',  'pct': 32},
    ]},
    {'name': '$p2 to Hit 100+ Checkout', 'options': [
      {'label': 'Yes', 'pct': 62},
      {'label': 'No',  'pct': 38},
    ]},
    {'name': '170 Checkout in Match', 'options': [
      {'label': 'Yes', 'pct': 8},
      {'label': 'No',  'pct': 92},
    ]},
    {'name': 'Number of 100+ Checkouts', 'options': [
      {'label': 'Over 1.5', 'pct': 66},
      {'label': 'Over 2.5', 'pct': 44},
      {'label': 'Over 3.5', 'pct': 26},
      {'label': 'Under 1.5','pct': 34},
      {'label': 'Under 2.5','pct': 56},
    ]},
  ];

  List<Map<String, dynamic>> _legsAndSets() => [
    {'name': 'Total Legs in Match — Over', 'options': [
      {'label': 'Over 14.5', 'pct': 82},
      {'label': 'Over 17.5', 'pct': 62},
      {'label': 'Over 19.5', 'pct': 44},
      {'label': 'Over 21.5', 'pct': 28},
      {'label': 'Over 23.5', 'pct': 16},
    ]},
    {'name': 'Total Legs in Match — Under', 'options': [
      {'label': 'Under 17.5', 'pct': 38},
      {'label': 'Under 19.5', 'pct': 56},
      {'label': 'Under 21.5', 'pct': 72},
      {'label': 'Under 23.5', 'pct': 84},
    ]},
    {'name': '$p1 Legs Won — Over/Under', 'options': [
      {'label': 'Over 7.5',  'pct': 58},
      {'label': 'Over 9.5',  'pct': 38},
      {'label': 'Under 7.5', 'pct': 42},
      {'label': 'Under 9.5', 'pct': 62},
    ]},
    {'name': '$p2 Legs Won — Over/Under', 'options': [
      {'label': 'Over 6.5',  'pct': 52},
      {'label': 'Over 8.5',  'pct': 34},
      {'label': 'Under 6.5', 'pct': 48},
      {'label': 'Under 8.5', 'pct': 66},
    ]},
    {'name': 'A Set to be Whitewashed (3–0)', 'options': [
      {'label': 'Yes', 'pct': 54},
      {'label': 'No',  'pct': 46},
    ]},
  ];

  List<Map<String, dynamic>> _firstLeg() => [
    {'name': 'First Leg Winner', 'options': [
      {'label': p1, 'pct': p1Pct},
      {'label': p2, 'pct': p2Pct},
    ]},
    {'name': 'First Set Winner', 'options': [
      {'label': p1, 'pct': p1Pct},
      {'label': p2, 'pct': p2Pct},
    ]},
    {'name': 'First Leg — 180 Scored', 'options': [
      {'label': 'Yes', 'pct': 52},
      {'label': 'No',  'pct': 48},
    ]},
    {'name': 'First Leg — Checkout Under 15 Darts', 'options': [
      {'label': 'Yes', 'pct': 36},
      {'label': 'No',  'pct': 64},
    ]},
    {'name': 'Winner Winning First Leg', 'options': [
      {'label': 'Yes', 'pct': 62},
      {'label': 'No',  'pct': 38},
    ]},
  ];

  List<Map<String, dynamic>> _averages() => [
    {'name': 'Winning 3-Dart Average — Over/Under', 'options': [
      {'label': 'Over 92.5',  'pct': 72},
      {'label': 'Over 96.5',  'pct': 54},
      {'label': 'Over 100.5', 'pct': 36},
      {'label': 'Over 104.5', 'pct': 20},
      {'label': 'Under 96.5', 'pct': 46},
      {'label': 'Under 100.5','pct': 64},
    ]},
    {'name': '$p1 Average — Over/Under', 'options': [
      {'label': 'Over 90.5', 'pct': 66},
      {'label': 'Over 95.5', 'pct': 48},
      {'label': 'Over 99.5', 'pct': 30},
      {'label': 'Under 90.5','pct': 34},
      {'label': 'Under 95.5','pct': 52},
    ]},
    {'name': '$p2 Average — Over/Under', 'options': [
      {'label': 'Over 88.5', 'pct': 62},
      {'label': 'Over 93.5', 'pct': 44},
      {'label': 'Over 97.5', 'pct': 26},
      {'label': 'Under 88.5','pct': 38},
      {'label': 'Under 93.5','pct': 56},
    ]},
    {'name': 'Highest Average in Match', 'options': [
      {'label': p1, 'pct': 54},
      {'label': p2, 'pct': 46},
    ]},
  ];
}

// ─── MARKET BUTTON ───────────────────────────────────────────────────────────

class _MarketButton extends StatelessWidget {
  final String label;
  final int pct;
  final int? bookiePct;
  final VoidCallback onTap;
  final List<String> injuries;
  final List<String> suspensions;

  const _MarketButton({
    required this.label,
    required this.pct,
    required this.onTap,
    this.bookiePct,
    this.injuries = const [],
    this.suspensions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final isInjured   = injuries.any((p) => label.contains(p));
    final isSuspended = suspensions.any((p) => label.contains(p));
    final flagged     = isInjured || isSuspended;
    final effectiveBookie = bookiePct ?? _simBookiePct(label, pct);
    final edge        = pct - effectiveBookie;
    final hasEdge     = edge >= 3;
    final borderCol   = flagged
        ? Colors.orange.shade700
        : hasEdge
            ? kGreen.withOpacity(0.45)
            : Colors.grey.shade800;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: flagged
              ? Colors.orange.withOpacity(0.05)
              : hasEdge
                  ? kGreen.withOpacity(0.04)
                  : const Color(0xFF252525),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: borderCol),
        ),
        child: Column(children: [
          if (flagged)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                isInjured ? '🤕 Injury doubt' : '🟥 Suspended',
                style: TextStyle(color: Colors.orange.shade400, fontSize: 9, fontWeight: FontWeight.w700),
              ),
            ),
          Text(label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: flagged ? Colors.orange.shade200 : Colors.white,
                fontWeight: FontWeight.w600, fontSize: 12,
              )),
          const SizedBox(height: 3),
          Text('$pct%',
              style: const TextStyle(color: kGreen, fontWeight: FontWeight.w700, fontSize: 12)),
          if (hasEdge) ...[
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: kGreen.withOpacity(0.15),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text('Model +$edge%',
                  style: const TextStyle(color: kGreen, fontSize: 8, fontWeight: FontWeight.w700)),
            ),
          ],
        ]),
      ),
    );
  }
}

// ─── BET THIS BOTTOM SHEET ───────────────────────────────────────────────────

void showBetBottomSheet(
  BuildContext context,
  String selection,
  int aiPct,
  String outcomeKey, // 'homePct', 'drawPct', 'awayPct'
  List<Map<String, dynamic>> bookmakers, {
  String modelSource = '',
}) {
  // Find best odds (lowest implied pct = best for punter)
  int bestPct = 999;
  for (final b in bookmakers) {
    final p = (b[outcomeKey] as int?) ?? 0;
    if (p > 0 && p < bestPct) bestPct = p;
  }

  showModalBottomSheet(
    context: context,
    backgroundColor: kCard,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 40, height: 4,
          decoration: BoxDecoration(color: Colors.grey.shade700, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('BET THIS', style: TextStyle(color: Colors.grey.shade500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            const SizedBox(height: 3),
            Text(selection, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
          ]),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: kGreen.withOpacity(0.15), borderRadius: BorderRadius.circular(6), border: Border.all(color: kGreen.withOpacity(0.4))),
            child: Text('${modelSource == 'devig_fallback' ? 'Consensus' : 'Model'} $aiPct%', style: const TextStyle(color: kGreen, fontWeight: FontWeight.w800, fontSize: 13)),
          ),
        ]),
        const SizedBox(height: 6),
        Text('Best odds highlighted  ·  Tap to open bookmaker', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
        const SizedBox(height: 16),
        ...bookmakers.map((b) {
          final p = (b[outcomeKey] as int?) ?? 0;
          final odds = pctToDecimalOdds(p);
          final isBest = p == bestPct && p > 0;
          return GestureDetector(
            onTap: () {
              Navigator.pop(context);
              launchBookmaker(context, b['name'] as String);
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isBest ? kGreen.withOpacity(0.07) : kBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: isBest ? kGreen.withOpacity(0.45) : Colors.grey.shade900),
              ),
              child: Row(children: [
                Expanded(child: Row(children: [
                  Text(b['name'] as String,
                      style: TextStyle(color: isBest ? Colors.white : Colors.grey.shade300, fontWeight: FontWeight.w600, fontSize: 13)),
                  if (isBest) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: kGreen.withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                      child: const Text('BEST ODDS', style: TextStyle(color: kGreen, fontSize: 9, fontWeight: FontWeight.w800)),
                    ),
                  ],
                ])),
                Text(odds, style: TextStyle(color: isBest ? kGreen : Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: kGreen.withOpacity(0.15), borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: kGreen.withOpacity(0.4)),
                  ),
                  child: const Text('BET', style: TextStyle(color: kGreen, fontWeight: FontWeight.w800, fontSize: 12)),
                ),
              ]),
            ),
          );
        }),
      ]),
    ),
  );
}

// ─── EDGE TREND BADGE ────────────────────────────────────────────────────────

Widget edgeTrendBadge(Map<String, dynamic>? trend, {bool compact = false}) {
  if (trend == null) return const SizedBox.shrink();
  final dir    = trend['direction'] as String;
  final change = trend['change']    as int;
  final isUp   = dir == 'up';
  final color  = isUp ? kGreen : Colors.red.shade400;
  if (compact) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(isUp ? Icons.trending_up : Icons.trending_down, color: color, size: 12),
      const SizedBox(width: 2),
      Text('${isUp ? '+' : '-'}$change%', style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    ]);
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(5)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(isUp ? Icons.trending_up : Icons.trending_down, color: color, size: 12),
      const SizedBox(width: 4),
      Text('${isUp ? '+' : '-'}$change% 1h', style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
    ]),
  );
}

// ─── EDGE LEADERBOARD SCREEN ─────────────────────────────────────────────────

class EdgeLeaderboardScreen extends StatelessWidget {
  const EdgeLeaderboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final edges = computeAllEdges();
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kCard,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context)),
        title: const Text('⚡ Edge Leaderboard',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, color: Colors.white),
            onPressed: () => showEdgeExplainer(context),
            tooltip: 'What is edge?',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              'Model probability vs bookmaker implied — sorted by biggest edge',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ),
        ),
      ),
      body: edges.isEmpty
          ? Center(child: Text('No positive edges found right now',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 14)))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: edges.length,
              itemBuilder: (context, i) {
                final e     = edges[i];
                final match = e['match'] as Map<String, dynamic>;
                final edge  = e['edge'] as int;
                final aiPct = e['aiPct'] as int;
                final bPct  = e['bookiePct'] as int;

                // Colour by edge strength
                final Color edgeColor = edge >= 8
                    ? const Color(0xFFFFD700)
                    : edge >= 5
                        ? kGreen
                        : Colors.greenAccent.shade400;

                return GestureDetector(
                  onTap: () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => MatchDetailScreen(match: match),
                  )),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: kCard,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: edge >= 5 ? edgeColor.withOpacity(0.3) : Colors.grey.shade900,
                      ),
                    ),
                    child: Row(children: [
                      // Rank badge
                      Container(
                        width: 30, height: 30,
                        decoration: BoxDecoration(
                          color: i < 3 ? edgeColor.withOpacity(0.15) : Colors.grey.shade900,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text('#${i + 1}',
                              style: TextStyle(
                                color: i < 3 ? edgeColor : Colors.grey.shade500,
                                fontWeight: FontWeight.w800, fontSize: 11,
                              )),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Match + market info
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${match['home']} v ${match['away']}',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                        const SizedBox(height: 3),
                        Row(children: [
                          Text(e['market'] as String,
                              style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                          const SizedBox(width: 6),
                          Text('•', style: TextStyle(color: Colors.grey.shade700, fontSize: 10)),
                          const SizedBox(width: 6),
                          Text(match['sport'] as String,
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                        ]),
                        const SizedBox(height: 4),
                        Row(children: [
                          Text('${(match['modelSource'] == 'devig_fallback') ? 'Consensus' : 'Model'} $aiPct%  vs  Bookie $bPct%',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                          const SizedBox(width: 8),
                          edgeTrendBadge(match['edgeTrend'] as Map<String, dynamic>?, compact: true),
                        ]),
                      ])),
                      // Edge badge
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: edgeColor.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: edgeColor.withOpacity(0.5)),
                          ),
                          child: Text('+$edge%',
                              style: TextStyle(color: edgeColor, fontWeight: FontWeight.w900, fontSize: 16)),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          edge >= 8 ? '🔥 Strong' : edge >= 5 ? '✅ Good' : '📈 Slight',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 10),
                        ),
                      ]),
                    ]),
                  ),
                );
              },
            ),
    );
  }
}

// ─── SEARCH SCREEN ───────────────────────────────────────────────────────────

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  String _query = '';
  final _ctrl = TextEditingController();

  List<Map<String, dynamic>> get _results {
    if (_query.isEmpty) return allMatches;
    final q = _query.toLowerCase();
    return allMatches.where((m) =>
      (m['home'] as String).toLowerCase().contains(q) ||
      (m['away'] as String).toLowerCase().contains(q) ||
      (m['sport'] as String).toLowerCase().contains(q)
    ).toList();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    appBar: AppBar(
      backgroundColor: kCard,
      leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context)),
      title: TextField(
        controller: _ctrl,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Search teams, sports...',
          hintStyle: TextStyle(color: Colors.grey.shade500),
          border: InputBorder.none,
        ),
        onChanged: (v) => setState(() => _query = v),
      ),
      actions: [
        if (_query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear, color: Colors.grey),
            onPressed: () { _ctrl.clear(); setState(() => _query = ''); },
          ),
      ],
    ),
    body: _results.isEmpty
        ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Text('🔍', style: TextStyle(fontSize: 40)),
            const SizedBox(height: 12),
            Text('No matches found for "$_query"',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
          ]))
        : ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (_query.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('All fixtures (${_results.length})',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('${_results.length} result${_results.length == 1 ? '' : 's'} for "$_query"',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                ),
              ..._results.map((m) => MatchCard(match: m)),
            ],
          ),
  );
}

// ─── NOTIFICATIONS SCREEN ────────────────────────────────────────────────────

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final edges = computeAllEdges()
        .where((e) => (e['edge'] as int) >= globalAlertThreshold.round())
        .toList()
      ..sort((a, b) => (b['edge'] as int).compareTo(a['edge'] as int));

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kCard,
        leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.pop(context)),
        title: const Text('Edge Alerts',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: Text('Threshold: +${globalAlertThreshold.round()}%',
                  style: const TextStyle(color: kGreen, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
      body: edges.isEmpty
          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('🔕', style: TextStyle(fontSize: 44)),
              const SizedBox(height: 14),
              Text('No edges above +${globalAlertThreshold.round()}% right now',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
              const SizedBox(height: 6),
              Text('Lower your threshold in the Account tab to see more',
                  style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
            ]))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: edges.length,
              separatorBuilder: (_, __) => Divider(color: Colors.grey.shade900, height: 1),
              itemBuilder: (context, i) {
                final e    = edges[i];
                final edge = e['edge'] as int;
                final gold = edge >= 8;
                final color = gold ? const Color(0xFFFFD700) : kGreen;
                return Container(
                  color: color.withOpacity(0.03),
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: color.withOpacity(0.3)),
                      ),
                      child: Center(child: Text(gold ? '⚡' : '📈',
                          style: const TextStyle(fontSize: 20))),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(e['match'] as String,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13))),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('+$edge%',
                              style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 12)),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      Text(e['market'] as String,
                          style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text('${((e['match'] as Map)['modelSource'] == 'devig_fallback') ? 'Consensus' : 'Model'}: ${e['aiPct']}%  ·  Bookie: ${e['bookiePct']}%',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                    ])),
                  ]),
                );
              },
            ),
    );
  }
}

// ─── TERMS OF SERVICE ────────────────────────────────────────────────────────

class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Terms of Service',
            style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          _tosHeader('Effective: 16 September 2026  ·  Version 1.0'),
          const SizedBox(height: 20),
          _tosSection(
            '1. About OddsVision',
            'OddsVision is a sports data application that displays statistical probability estimates alongside bookmaker odds for informational and entertainment purposes only. OddsVision does not facilitate, accept, or process any form of betting or wagering.',
          ),
          _tosSection(
            '2. Acceptance of Terms',
            'By downloading or using OddsVision you agree to these Terms of Service. If you do not agree, do not use the app.',
          ),
          _tosSection(
            '3. Eligibility',
            'You must be at least 18 years old, or the minimum legal gambling age in your jurisdiction (whichever is higher), to use OddsVision. By using the app you confirm you meet this requirement.',
          ),
          _tosSection(
            '4. Informational Use Only',
            'All probabilities, edges, and statistics displayed are statistical estimates generated by mathematical models. They do not constitute betting advice, financial advice, or any guarantee of outcome. Past model performance does not predict future results.',
          ),
          _tosSection(
            '5. No Liability for Losses',
            'OddsVision and its developers accept no responsibility for any financial losses arising from decisions made using information displayed in the app. You use OddsVision entirely at your own risk.',
          ),
          _tosSection(
            '6. Data Accuracy',
            'Odds and match data are sourced from third-party providers and may be delayed, incomplete, or inaccurate. We do not warrant the accuracy, completeness, or timeliness of any data displayed.',
          ),
          _tosSection(
            '7. Prohibited Uses',
            'You may not use OddsVision to:\n• Develop competing products or services\n• Scrape, harvest, or systematically copy data\n• Misrepresent probabilities shown as guaranteed outcomes\n• Use the app in any jurisdiction where sports data services are prohibited',
          ),
          _tosSection(
            '8. Responsible Gambling',
            'Gambling involves financial risk. Only ever bet what you can afford to lose. If you are concerned about your gambling behaviour, free support is available:\n\nUK: BeGambleAware.org · 0808 8020 133 (free, 24/7)\nAustralia: Gambling Help Online · 1800 858 858',
          ),
          _tosSection(
            '9. Changes to These Terms',
            'We may update these Terms at any time. We will notify users of material changes via an in-app notice. Continued use of OddsVision after an update constitutes acceptance of the revised Terms.',
          ),
          _tosSection(
            '10. Contact',
            'For questions about these Terms, contact: markfranckeiss@outlook.com',
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.withOpacity(0.25)),
            ),
            child: Text(
              'OddsVision is for informational purposes only and does not constitute financial or betting advice.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12, height: 1.6),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _tosHeader(String text) => Text(
    text,
    style: TextStyle(
      color: Colors.grey.shade600,
      fontSize: 12,
      fontFamily: 'monospace',
    ),
  );

  Widget _tosSection(String title, String body) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 3, height: 18, margin: const EdgeInsets.only(top: 2, right: 10),
            decoration: BoxDecoration(color: kGreen, borderRadius: BorderRadius.circular(2))),
        Expanded(
          child: Text(title, style: const TextStyle(
            color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700,
          )),
        ),
      ]),
      const SizedBox(height: 8),
      Text(body, style: TextStyle(
        color: Colors.grey.shade400, fontSize: 13.5, height: 1.65,
      )),
    ]),
  );
}
