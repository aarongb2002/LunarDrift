import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'main.dart'; // Import to access VideoPlayerPage

// --- Data Models ---
class Sport {
  final String id;
  final String name;
  final String logoUrl;
  final String slug;

  Sport({required this.id, required this.name, required this.logoUrl, required this.slug});

  factory Sport.fromJson(Map<String, dynamic> json) {
    return Sport(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Unknown',
      slug: json['slug']?.toString() ?? '',
      logoUrl: LiveSportsApi._buildStreamedPkImageUrl(json['icon']?.toString()),
    );
  }
}

class Match {
  final String id;
  final String title;
  final String streamUrl;
  final DateTime startTime;
  final Sport sport;
  final String teamALogo;
  final String teamBLogo;
  final String posterUrl;
  final String leagueName;
  final String leagueId;
  final List<Map<String, String>> sources;

  Match({
    required this.id,
    required this.title,
    required this.streamUrl,
    required this.startTime,
    required this.sport,
    required this.teamALogo,
    required this.teamBLogo,
    required this.posterUrl,
    required this.leagueName,
    required this.leagueId,
    required this.sources,
  });

  bool get isFinished {
    final now = DateTime.now();
    return now.isAfter(startTime.add(const Duration(hours: 2, minutes: 30)));
  }

  bool get isLive {
    final now = DateTime.now();
    final endEstimate = startTime.add(const Duration(hours: 2, minutes: 30));
    return now.isAfter(startTime.subtract(const Duration(minutes: 5))) && now.isBefore(endEstimate);
  }

  factory Match.fromJson(Map<String, dynamic> json) {
    // Defensive parsing for the sport object
    Sport sport;
    if (json['sport'] is Map) {
      sport = Sport.fromJson(json['sport']);
    } else {
      // Fallback if sport is just a string or missing
      sport = Sport(
        id: '',
        name: json['sport']?.toString() ?? json['category']?.toString() ?? json['sport_name']?.toString() ?? 'Other',
        slug: '',
        logoUrl: '',
      );
    }

    // Robust key guessing for teams and titles
    final teamsObj = json['teams'];
    final homeData = (teamsObj is Map) ? teamsObj['home'] : (json['home_team'] ?? json['home'] ?? json['team1'] ?? json['home_name'] ?? json['t1']);
    final awayData = (teamsObj is Map) ? teamsObj['away'] : (json['away_team'] ?? json['away'] ?? json['team2'] ?? json['away_name'] ?? json['t2']);

    String homeName = 'TBD';
    String homeLogo = '';
    if (homeData is Map) {
      homeName = homeData['name']?.toString() ?? homeData['team_name']?.toString() ?? homeData['team']?.toString() ?? 'TBD';
      homeLogo = homeData['badge']?.toString() ?? homeData['logo']?.toString() ?? homeData['image']?.toString() ?? homeData['icon']?.toString() ?? '';
    } else {
      homeName = homeData?.toString() ?? 'TBD';
    }

    String awayName = 'TBD';
    String awayLogo = '';
    if (awayData is Map) {
      awayName = awayData['name']?.toString() ?? awayData['team_name']?.toString() ?? awayData['team']?.toString() ?? 'TBD';
      awayLogo = awayData['badge']?.toString() ?? awayData['logo']?.toString() ?? awayData['image']?.toString() ?? awayData['icon']?.toString() ?? '';
    } else {
      awayName = awayData?.toString() ?? 'TBD';
    }

    final defaultTitle = '$homeName vs $awayName';

    // Parse sources for streaming
    final List<Map<String, String>> sources = [];
    if (json['sources'] is List) {
      for (var s in json['sources']) {
        sources.add({
          'source': s['source']?.toString() ?? '',
          'id': s['id']?.toString() ?? '',
        });
      }
    }

    final matchId = json['id']?.toString() ?? json['event_id']?.toString() ?? '';
    final serverSuffix = sources.length > 1 ? '/2' : '/1';
    
    final homeLogoFilename = homeLogo.isNotEmpty ? homeLogo : (json['home_team_logo']?.toString() ?? json['home_logo']?.toString() ?? json['t1img']?.toString() ?? json['team1_logo']?.toString() ?? '');
    final awayLogoFilename = awayLogo.isNotEmpty ? awayLogo : (json['away_team_logo']?.toString() ?? json['away_logo']?.toString() ?? json['t2img']?.toString() ?? json['team2_logo']?.toString() ?? '');

    // Robust time parsing: Prioritize Unix timestamps (milliseconds as requested)
    DateTime parsedStartTime;
    final rawTime = json['start_time'];
    final rawDate = json['date'];
    final rawTimestamp = json['timestamp'] ?? json['unix'] ?? json['start_time_unix'];

    // Determine which field holds our numeric timestamp
    num? numericTs;
    if (rawDate is num) {
      numericTs = rawDate;
    } else if (rawTimestamp is num) {
      numericTs = rawTimestamp;
    } else if (rawTime is num) {
      numericTs = rawTime;
    }

    if (numericTs != null) {
      int ts = numericTs.toInt();
      // Detect if timestamp is in seconds (e.g. 1735689600) vs milliseconds (e.g. 1735689600000)
      // If the number is smaller than 10^10, it's likely seconds.
      if (ts < 10000000000) ts *= 1000; 
      parsedStartTime = DateTime.fromMillisecondsSinceEpoch(ts).toLocal();
    } else {
      String timeStr = (rawTime?.toString() ?? rawDate?.toString() ?? '').trim();
      String datePart = rawDate?.toString() ?? DateTime.now().toIso8601String().split('T')[0];

      // If the API only gives "HH:mm", we must prefix it with a date for tryParse to work
      if (timeStr.length <= 8 && timeStr.contains(':')) {
        timeStr = '${datePart.split('T')[0]}T$timeStr';
      }

      // Clean up common non-ISO formats
      if (timeStr.contains(' ') && !timeStr.contains('T')) {
        timeStr = timeStr.replaceAll(' ', 'T');
      }
      
      // Standardize the ISO separator if it's missing the 'T'
      if (timeStr.length > 10 && timeStr[10] == ' ') {
        timeStr = timeStr.replaceRange(10, 11, 'T');
      }

      // Assume UTC if no timezone info is present (common for sports APIs)
      if (timeStr.isNotEmpty && !timeStr.contains('Z') && !timeStr.contains('+')) timeStr += 'Z';
      
      parsedStartTime = DateTime.tryParse(timeStr)?.toLocal() ?? DateTime.now();
    }

    return Match(
      id: matchId,
      title: json['name']?.toString() ?? json['title']?.toString() ?? json['event']?.toString() ?? defaultTitle,
      streamUrl: LiveSportsApi._buildEmbedUrl('https://streamed.pk/embed/$matchId$serverSuffix?autoplay=1'),
      startTime: parsedStartTime,
      sport: sport,
      teamALogo: LiveSportsApi._buildTeamBadgeUrl(homeLogoFilename),
      teamBLogo: LiveSportsApi._buildTeamBadgeUrl(awayLogoFilename),
      posterUrl: LiveSportsApi._buildMatchPosterUrl(json['poster']?.toString() ?? homeLogoFilename),
      leagueName: json['league']?.toString() ?? json['tournament']?.toString() ?? json['league_name']?.toString() ?? 'Tournament',
      leagueId: json['league_id']?.toString() ?? '',
      sources: sources,
    );
  }
}

class Team {
  final String id;
  final String name;
  final String logoUrl;

  Team({required this.id, required this.name, required this.logoUrl});

  factory Team.fromJson(Map<String, dynamic> json) {
    return Team(
      id: json['idTeam']?.toString() ?? '',
      name: json['strTeam']?.toString() ?? '',
      logoUrl: json['strTeamBadge']?.toString() ?? '',
    );
  }
}

// --- API Service ---
class LiveSportsApi {
  static final LiveSportsApi _instance = LiveSportsApi._internal();
  factory LiveSportsApi() => _instance;
  LiveSportsApi._internal();

  final List<String> _baseUrls = [
    'https://streamed.st/api',
    'https://streamed.pk/api',
    'https://streami.ru/api',
  ];
  int _currentUrlIndex = 0;

  // Central Cache
  List<Match> _allMatchesCache = [];
  List<Sport> _sportsCache = [];
  bool _hasPrefetched = false;

  bool get hasPrefetched => _hasPrefetched;
  List<Match> get cachedMatches => _allMatchesCache;
  List<Sport> get cachedSports => _sportsCache;

  /// Loads all sports and matches into the central cache
  Future<void> prefetch() async {
    try {
      final sports = await fetchSports();
      final matchesResults = await Future.wait(
        sports.map((s) => fetchMatches(sportSlug: s.slug))
      );
      
      updateCache(sports, matchesResults.expand((m) => m).toList());
      _hasPrefetched = true;
    } catch (e) {
      debugPrint('LiveSportsApi: Prefetch failed: $e');
    }
  }

  static String get baseUrl => _instance._baseUrls[_instance._currentUrlIndex];
  
  // Headers often required by these APIs to prevent 403 errors
  final Map<String, String> _headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
    'Accept': 'application/json',
  };

  static String _buildEmbedUrl(String? originalUrl) {
    if (originalUrl == null || originalUrl.isEmpty) return '';
    final embedBase = baseUrl.replaceAll('/api', '');
    // Dynamically swap the domain of any hardcoded mirror URLs to use the current working mirror
    return originalUrl.replaceAll(RegExp(r'https?://(v3\.|api\.)?streamed\.(pk|st|ru)'), embedBase);
  }

  static String _buildTeamBadgeUrl(String? path) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('http')) return path;
    // Extract filename (ID) without extension from the path
    final id = path.split('/').last.split('.').first;
    return '$baseUrl/images/badge/$id.webp';
  }

  static String _buildMatchPosterUrl(String? path) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('http')) return path;
    // Extract filename (ID) without extension for the badge placeholder
    final id = path.split('/').last.split('.').first;
    return '$baseUrl/images/poster/$id/$id.webp';
  }

  static String _buildStreamedPkImageUrl(String? path) {
    if (path == null || path.isEmpty) {
      return '';
    }
    // If the path is already a full URL, return it as is.
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    // For sport icons, use the current active domain
    final uri = Uri.parse(baseUrl);
    return '${uri.scheme}://${uri.host}/docs/images/$path';
  }

  Future<http.Response> _get(String path) async {
    for (int i = 0; i < _baseUrls.length; i++) {
      int index = (_currentUrlIndex + i) % _baseUrls.length;
      String url = '${_baseUrls[index]}$path';
      try {
        final response = await http.get(Uri.parse(url), headers: _headers)
            .timeout(const Duration(seconds: 8));
        
        if (response.statusCode == 200) {
          _currentUrlIndex = index; // Persist working URL index
          return response;
        }
      } catch (e) {
        debugPrint('LiveSportsApi: Request failed for $url: $e');
      }
    }
    throw Exception('LiveSportsApi: All endpoints failed.');
  }

  Future<List<Sport>> fetchSports() async {
    if (_sportsCache.isNotEmpty) return _sportsCache;
    try {
      final response = await _get('/sports');
      if (response.statusCode == 200) {
        List<int> bytes = response.bodyBytes;
        
        // Robust handling for potential compressed responses without headers
        if (bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
          bytes = gzip.decode(bytes);
        }
        
        final decodedBody = utf8.decode(bytes);
        final List<dynamic> sportsData = json.decode(decodedBody);
        
        _sportsCache =
            sportsData.map((json) => Sport.fromJson(json)).toList();

        _sportsCache.sort((a, b) => a.name.compareTo(b.name));
        return _sportsCache;
      } else {
        throw Exception('Failed to load sports: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('Error fetching sports: $e');
      return [];
    }
  }

  Future<List<Match>> fetchMatches({String? sportSlug}) async {
    try {
      String path = '/matches/all-today';
      if (sportSlug != null && sportSlug.isNotEmpty && sportSlug != 'all') {
        // Try both common query parameters used by these types of APIs
        path += '?sport=${Uri.encodeComponent(sportSlug)}&category=${Uri.encodeComponent(sportSlug)}';
      }

      final response = await _get(path);
      
      if (response.statusCode != 200) {
        debugPrint('LiveSportsApi: Error fetching matches for $path');
        return []; // Return empty instead of crashing the app
      }

      List<int> bytes = response.bodyBytes;
      if (bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
        bytes = gzip.decode(bytes);
      }
      
      final decodedBody = utf8.decode(bytes);
      final List<dynamic> data = json.decode(decodedBody);
      
      final matches = data.map((item) => Match.fromJson(item as Map<String, dynamic>)).toList();
      matches.sort((a, b) => a.startTime.compareTo(b.startTime));
      return matches;
    } catch (e) {
      debugPrint('LiveSportsApi Error: $e');
      return [];
    }
  }

  Future<String?> fetchStreamUrl(String source, String id) async {
    try {
      // Fetching the specific stream sources for the match
      final response = await _get('/stream/$source/$id');

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        if (data.isNotEmpty) {
          // Prefer the second server (/2) if available in the result list
          final streamData = data.length > 1 ? data[1] : data[0];
          return _buildEmbedUrl(streamData['embedUrl']?.toString());
        }
      } else {
        debugPrint('LiveSportsApi: Failed to fetch stream info for $source/$id: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('LiveSportsApi Error fetching stream: $e');
    }
    return null;
  }

  void updateCache(List<Sport> sports, List<Match> allMatches) {
    _sportsCache = sports;
    
    final Map<String, Match> uniqueMatchesMap = {};
    for (var match in allMatches) {
      if (match.id.isNotEmpty) {
        uniqueMatchesMap[match.id] = match;
      }
    }
    _allMatchesCache = uniqueMatchesMap.values.toList();
    _allMatchesCache.sort((a, b) => a.startTime.compareTo(b.startTime));
  }
}

// --- Main Page Widget ---
class LiveTVPage extends StatefulWidget {
  const LiveTVPage({super.key});

  @override
  State<LiveTVPage> createState() => _LiveTVPageState();
}

class _LiveTVPageState extends State<LiveTVPage> {
  final _api = LiveSportsApi();
  bool _isLoading = true;
  // ignore: unused_field
  List<Sport> _sports = [];
  List<Match> _allMatches = [];

  @override
  void initState() {
    super.initState();
    
    // Immediately load from cache if available to prevent layout jump
    if (_api.hasPrefetched) {
      _sports = _api.cachedSports;
      _allMatches = _api.cachedMatches.where((m) => m.isLive).toList();
      _isLoading = false;
    }
    
    _fetchData();
  }

  Future<void> _fetchData() async {
    try {
      final sports = await _api.fetchSports();
      
      // Load matches based on the available sports slivers
      // We fetch them in parallel for speed, but filter out empty results
      final matchesResults = await Future.wait(
        sports.map((s) => _api.fetchMatches(sportSlug: s.slug))
      );

      if (mounted) {
        final flatMatches = matchesResults.expand((m) => m).toList();
        _api.updateCache(sports, flatMatches);

        setState(() {
          _sports = sports;
          _allMatches = _api.cachedMatches.where((m) => m.isLive).toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        AppNotification.show(context, 'Failed to load live sports: $e', color: Colors.red);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Color.fromARGB(255, 251, 251, 251)));
    }

    final Map<String, List<Match>> matchesBySport = {};
    for (var match in _allMatches) {
      matchesBySport.putIfAbsent(match.sport.name, () => []).add(match);
    }
    final sortedSports = matchesBySport.keys.toList()..sort();

    return RefreshIndicator(
      onRefresh: _fetchData,
      color: const Color.fromARGB(255, 253, 254, 254),
      backgroundColor: const Color(0xFF1E1F24),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(height: kToolbarHeight + MediaQuery.of(context).padding.top + 4),
          ),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Live Sports',
                  style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)),
            ),
          ),
          if (_allMatches.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.sentiment_dissatisfied_outlined, color: Colors.white54, size: 32),
                    const SizedBox(height: 8),
                    const Text(
                      'No live games at the moment.',
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                    // Counter-balance the height of the header slivers to achieve true screen centering
                    SizedBox(height: MediaQuery.of(context).padding.top + kToolbarHeight + 48),
                  ],
                ),
              ),
            ),
          if (_allMatches.isNotEmpty) ...[
            ...sortedSports.map((sportName) {
            return SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 16.0),
                child: HorizontalMatchList(
                  categoryTitle: sportName,
                  items: matchesBySport[sportName]!,
                ),
              ),
            );
            }),
            const SliverToBoxAdapter(child: SizedBox(height: 120)), // Padding for bottom nav bar
          ],
        ],
      ),
    );
  }
}

// --- Match Display Widgets ---

class HorizontalMatchList extends StatelessWidget {
  final String categoryTitle;
  final List<Match> items;

  const HorizontalMatchList({super.key, required this.categoryTitle, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Text(
            categoryTitle.toUpperCase(),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ),
        SizedBox(
          height: 175,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            itemCount: items.length,
            itemBuilder: (context, index) => MatchCard(match: items[index]),
          ),
        ),
      ],
    );
  }
}

// --- Navigation Helper ---
Future<void> handleMatchTap(BuildContext context, Match match) async {
  if (match.isLive) {
    // Show a loading dialog while we fetch the specific live stream info
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator(color: Color.fromARGB(255, 250, 250, 250))),
    );

    String? streamUrl;
    if (match.sources.isNotEmpty) {
      // Default to the second source if available
      final source = match.sources.length > 1 ? match.sources[1] : match.sources.first;
      streamUrl = await LiveSportsApi().fetchStreamUrl(
        source['source']!,
        source['id']!,
      );
    }

    if (context.mounted) {
      Navigator.of(context).pop(); // Dismiss the loading dialog

      if (streamUrl != null && streamUrl.isNotEmpty) {
        // Append autoplay parameter if not already present
        if (!streamUrl.contains('autoplay=')) {
          final separator = streamUrl.contains('?') ? '&' : '?';
          // ignore: unnecessary_brace_in_string_interps
          streamUrl = '${streamUrl}${separator}autoplay=1';
        }

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VideoPlayerPage(
              videoUrl: streamUrl,
              sources: match.sources,
              matchTitle: match.title,
            ),
          ),
        );
      } else {
        AppNotification.show(context, 'No active streams available for this match.', color: Colors.red);
      }
    }
  } else {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => MatchDetailsPage(match: match)),
    );
  }
}

class MatchCard extends StatelessWidget {
  final Match match;
  const MatchCard({super.key, required this.match});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => handleMatchTap(context, match),
      child: Container(
        width: 250,
        margin: const EdgeInsets.symmetric(horizontal: 4.0),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1F24),
          borderRadius: BorderRadius.circular(8.0),
          border: Border.all(color: match.isLive ? const Color.fromARGB(255, 255, 255, 255).withValues(alpha: 0.5) : Colors.white24, width: 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8.0),
          child: Stack(
            children: [
              if (match.posterUrl.isNotEmpty)
                Positioned.fill(
                  child: CachedNetworkImage(
                    imageUrl: match.posterUrl,
                    fit: BoxFit.cover,
                    // ignore: deprecated_member_use
                    color: Colors.black.withOpacity(0.7),
                    colorBlendMode: BlendMode.darken,
                    errorWidget: (context, url, error) => const SizedBox.shrink(),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        if (match.isLive)
                          const Opacity(
                            opacity: 0,
                            child: Text('● LIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                          ),
                        Expanded(
                          child: Text(match.leagueName.toUpperCase(), style: const TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                        if (match.isLive)
                          const Text(
                            '● LIVE',
                            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 10),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(match.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15), textAlign: TextAlign.center, maxLines: 2),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _TeamLogo(url: match.teamALogo),
                        const Text('vs', style: TextStyle(color: Colors.white54, fontSize: 18)),
                        _TeamLogo(url: match.teamBLogo),
                      ],
                    ),
                    const Spacer(),
                    Text(_formatMatchTime(context, match.startTime), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
              ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatMatchTime(BuildContext context, DateTime time) {
  final now = DateTime.now();
  final isToday = time.year == now.year && time.month == now.month && time.day == now.day;
  final timeStr = TimeOfDay.fromDateTime(time).format(context);
  
  if (isToday) return 'Today at $timeStr';
  return '${time.month}/${time.day} at $timeStr';
}

class MatchListItem extends StatelessWidget {
  final Match match;
  const MatchListItem({super.key, required this.match});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => handleMatchTap(context, match),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12.0),
        padding: const EdgeInsets.all(16.0),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1F24),
          borderRadius: BorderRadius.circular(8.0),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            _TeamLogo(url: match.teamALogo, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(match.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(match.leagueName.toUpperCase(), style: const TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_formatMatchTime(context, match.startTime), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            _TeamLogo(url: match.teamBLogo, size: 40),
            const SizedBox(width: 16),
            Icon(match.isLive ? Icons.play_circle_fill : Icons.calendar_today, color: const Color(0xFF1CE783), size: 32),
          ],
        ),
      ),
    );
  }
}

// --- Match Details Page ---
class MatchDetailsPage extends StatelessWidget {
  final Match match;
  const MatchDetailsPage({super.key, required this.match});

  @override
  Widget build(BuildContext context) {
    final isUpcoming = match.startTime.isAfter(DateTime.now());

    return Scaffold(
      backgroundColor: const Color(0xFF0F1014),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text(match.sport.name),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            Text(
              match.leagueName,
              style: const TextStyle(color: Color(0xFF1CE783), fontWeight: FontWeight.bold, fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      _TeamLogo(url: match.teamALogo, size: 100),
                      const SizedBox(height: 12),
                      const Text('Home', style: TextStyle(color: Colors.white54, fontSize: 14)),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16.0),
                  child: Text('VS', style: TextStyle(color: Colors.white24, fontSize: 32, fontWeight: FontWeight.w900)),
                ),
                Expanded(
                  child: Column(
                    children: [
                      _TeamLogo(url: match.teamBLogo, size: 100),
                      const SizedBox(height: 12),
                      const Text('Away', style: TextStyle(color: Colors.white54, fontSize: 14)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 48),
            Text(
              match.title,
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1F24),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Status', style: TextStyle(color: Colors.white54)),
                      Text(
                        match.isLive ? 'LIVE NOW' : (isUpcoming ? 'UPCOMING' : 'FINISHED'),
                        style: TextStyle(
                          color: match.isLive ? Colors.red : (isUpcoming ? const Color(0xFF1CE783) : Colors.white54),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white10, height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Date', style: TextStyle(color: Colors.white54)),
                      Text(
                        '${match.startTime.day}/${match.startTime.month}/${match.startTime.year}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white10, height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Start Time', style: TextStyle(color: Colors.white54)),
                      Text(
                        TimeOfDay.fromDateTime(match.startTime).format(context),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
            if (match.isLive)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1CE783),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () => handleMatchTap(context, match),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('WATCH LIVE NOW', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              )
            else if (isUpcoming)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1CE783),
                  side: const BorderSide(color: Color(0xFF1CE783)),
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 32),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Notification set for this match!')),
                  );
                },
                icon: const Icon(Icons.notifications_none),
                label: const Text('REMIND ME'),
              ),
          ],
        ),
      ),
    );
  }
}

class _TeamLogo extends StatelessWidget {
  final String url;
  final double size;
  const _TeamLogo({required this.url, this.size = 50});

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return Container(width: size, height: size, decoration: const BoxDecoration(color: Colors.white10, shape: BoxShape.circle), child: const Icon(Icons.shield, color: Colors.white24));
    }
    return CachedNetworkImage(
      imageUrl: url,
      width: size,
      height: size,
      fit: BoxFit.contain,
      placeholder: (context, url) => Container(width: size, height: size, decoration: const BoxDecoration(color: Colors.white10, shape: BoxShape.circle)),
      errorWidget: (context, url, error) => Container(width: size, height: size, decoration: const BoxDecoration(color: Colors.white10, shape: BoxShape.circle), child: const Icon(Icons.shield, color: Colors.white24)),
    );
  }
}