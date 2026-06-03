// ignore_for_file: duplicate_ignore, deprecated_member_use

import 'dart:io';
import 'dart:math';
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'main.dart'; // Import to access VideoPlayerPage
import 'epg_service.dart';

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
  final bool isPremium;
  final String? epgId;

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
    this.isPremium = false,
    this.epgId,
  });

  bool get isFinished {
    if (isPremium) return false;
    final now = DateTime.now();
    return now.isAfter(startTime.add(const Duration(hours: 2, minutes: 30)));
  }

  bool get isLive {
    if (isPremium) return true;
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
      isPremium: false,
      epgId: null,
    );
  }

  factory Match.premium({required String id, required String title, required String logoUrl, String? epgId}) {
    return Match(
      id: id,
      title: title,
      streamUrl: '',
      startTime: DateTime.now(),
      sport: Sport(id: 'premium', name: 'Network', logoUrl: '', slug: 'premium'),
      teamALogo: logoUrl,
      teamBLogo: '',
      posterUrl: '',
      leagueName: 'PREMIUM CHANNEL',
      leagueId: 'premium',
      sources: [],
      isPremium: true,
      epgId: epgId,
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
    'https://v3.streamed.st/api',
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
      
      // Collect EPG IDs from our premium lineup to filter the massive 1M+ entry EPG file
      final interestedEpgIds = premiumChannelsList
          .map((m) => m.epgId)
          .whereType<String>()
          .toSet();
          
      await EpgService().fetchAndParseEPG(interestedChannelIds: interestedEpgIds);
      
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
    final assetBase = baseUrl.replaceAll('/api', '');
    return '$assetBase/images/badge/$id.webp';
  }

  static String _buildMatchPosterUrl(String? path) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('http')) return path;
    // Extract filename (ID) without extension for the badge placeholder
    final id = path.split('/').last.split('.').first;
    final assetBase = baseUrl.replaceAll('/api', '');
    return '$assetBase/images/poster/$id/$id.webp';
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
            .timeout(const Duration(seconds: 15));
        
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

  static Future<String?> extractM3u8Stream(String channelId) async {
    debugPrint('[SCRAPER] --- Initiating extraction for Channel: $channelId ---');

    if (channelId.startsWith('http')) {
      debugPrint('[SCRAPER] Direct URL detected ($channelId). Analyzing directly...');
      return await _scrapeAndAnalyzeUrl(channelId);
    }

    final List<String> endpoints = switch (channelId) {
      '52' || '343' || '982' || '764' => ['daddy.php'], // CBS, USA, SportsNet USA, SportsNet LA
      '45' || '325' || '407' || '408' || '753' || '754' || '755' || '60' => ['daddy2.php'], // ESPN2, ion, SN West/East, NBCS Bay Area/Boston/California, F1
      '663' || '341' => ['daddy4.php'], // NHL Network, truTV
      '40' => ['daddy5.php'], // TNT Sports
      // Majority use daddy3 (ABC, CBS Sports, CW, ESPN, ESPNU, Fox, FS1, FS2, GOLF, NBA TV, NBC, NFL Network, tbs, TNT, SN NY, NBCS Philly)
      _ => ['daddy3.php'],
    };

    for (final endpoint in endpoints) {
      final gatewayUrl = 'https://donis.jimpenopisonline.online/premiumtv/$endpoint?id=$channelId';
      final result = await _scrapeAndAnalyzeUrl(gatewayUrl, referer: 'https://dlhd.pk/');
      if (result != null) return result;
    }

    debugPrint('[SCRAPER] --- Extraction Failed for $channelId ---');
    return null;
  }

  static Future<String?> _scrapeAndAnalyzeUrl(String url, {String? referer}) async {
    if (url.isEmpty) return null;
    debugPrint('[SCRAPER] Requesting URL: $url');

    referer ??= url;

    String originHeader = url;
    try {
      final Uri? parsedUrl = Uri.tryParse(url);
      if (parsedUrl != null && parsedUrl.hasScheme && parsedUrl.hasAuthority) {
        originHeader = parsedUrl.origin;
      }
      final Uri? refUri = Uri.tryParse(referer);
      if (refUri != null && refUri.hasScheme && refUri.hasAuthority) {
        originHeader = refUri.origin;
      } else {
        originHeader = referer;
      }
    } catch (_) {}

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Referer': referer,
          'Origin': originHeader.isNotEmpty ? originHeader : url,
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9',
          'Sec-Ch-Ua': '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
          'Sec-Ch-Ua-Mobile': '?0',
          'Sec-Ch-Ua-Platform': '"Windows"',
          'Sec-Fetch-Dest': 'iframe',
          'Sec-Fetch-Mode': 'navigate',
          'Sec-Fetch-Site': 'cross-site',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('[SCRAPER] FAILED: URL returned status ${response.statusCode}');
        return null;
      }

      final html = response.body;
      debugPrint('[SCRAPER] Page loaded (${html.length} chars). Analyzing strategies...');

      // Strategy 1: Base64 Obfuscation
      final base64Regex = RegExp(r"window\.atob\('([^']+)'\)");
      final base64Match = base64Regex.firstMatch(html);
      if (base64Match != null && (base64Match.group(1)?.isNotEmpty ?? false)) {
        debugPrint('[SCRAPER] SUCCESS: Found Base64 payload.');
        final decodedUrl = utf8.decode(base64.decode(base64Match.group(1) ?? ""));
        return decodedUrl.replaceAll(RegExp(r'[\s\n\r]'), '');
      }

      // Strategy 2: Packed JS (eval function)
      if (html.contains('eval(function(p,a,c,k,e,d)')) {
        debugPrint('[SCRAPER] Strategy: Packed JS detected. Unpacking...');
        return await _extractCdnLiveTvStream(url, referer: referer);
      }

      // Strategy 3: Plain text M3U8/HLS fallback
      final hlsRegex = RegExp(r'''(https?://[^\s"']+\.m3u8[^\s"']*)''');
      final hlsMatch = hlsRegex.firstMatch(html);
      if (hlsMatch != null && (hlsMatch.group(0)?.isNotEmpty ?? false)) {
        debugPrint('[SCRAPER] SUCCESS: Found plain text stream link.');
        return (hlsMatch.group(0) ?? "").replaceAll(RegExp(r'[\s\n\r]'), '');
      }
      
      // Strategy 4: Adcash/OptimServe pattern detection
      if (html.contains('window["') && html.contains('] = "')) {
        debugPrint('[SCRAPER] Strategy: Detected Adcash/OptimServe obfuscation. Attempting Headless Extraction...');
        return await _extractUsingHeadlessWebView(url, referer: referer);
      }

      debugPrint('[SCRAPER] WARNING: No known stream patterns found. Falling back to Headless WebView...');
      return await _extractUsingHeadlessWebView(url, referer: referer);
    } catch (e) {
      debugPrint('[SCRAPER] ERROR: Analysis exception: $e');
    }
    return null;
  }

  /// Runs the URL in a headless browser to capture the stream URL from network logs.
  /// This is the most reliable way to bypass polymorphic obfuscation.
  static Future<String?> _extractUsingHeadlessWebView(String url, {String? referer}) async {
    debugPrint('[SCRAPER] Starting Aggressive Headless session for: $url');
    final completer = Completer<String?>();
    HeadlessInAppWebView? headlessWebView;

    final uri = Uri.tryParse(url);
    final origin = uri?.hasScheme == true ? uri!.origin : '';
    final actualReferer = referer ?? origin;

    headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(url),
        headers: {
          'Referer': actualReferer,
          'Origin': origin,
        },
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        useShouldInterceptRequest: true,
        javaScriptCanOpenWindowsAutomatically: false, // Prevent ad popups from taking focus
        contentBlockers: [
          ContentBlocker(
            trigger: ContentBlockerTrigger(urlFilter: ".*(popads|adcash|optimserve|ad-delivery|doubleclick|google-analytics|ad.html|jads.co|ad-maven|onclickads|popmyads|propellerads|exosrv|a-ads).*"),
            action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
          ),
        ],
      ),
      onConsoleMessage: (controller, consoleMessage) {
        // Log internal browser messages containing stream links
        final msg = consoleMessage.message;
        if (msg.contains('.m3u8') && !msg.contains('ad.html') && !completer.isCompleted) {
          final hlsRegex = RegExp(r'''(https?://[^\s"']+\.m3u8[^\s"']*)''');
          final match = hlsRegex.firstMatch(msg);
          if (match != null) {
            final foundUrl = match.group(0)!;
            debugPrint('[SCRAPER] SUCCESS (Console): Captured .m3u8: $foundUrl');
            completer.complete(foundUrl);
          }
        }
      },
      onLoadResource: (controller, resource) {
        final resourceUrl = resource.url?.toString() ?? "";
        if (resourceUrl.isNotEmpty && 
            resourceUrl.contains('.m3u8') && 
            !resourceUrl.contains('ad.html') && 
            !completer.isCompleted) {
          debugPrint('[SCRAPER] SUCCESS (Resource): Captured .m3u8: $resourceUrl');
          completer.complete(resourceUrl);
        }
      },
      shouldInterceptRequest: (controller, request) async {
        final requestUrl = request.url.toString();
        if (requestUrl.contains('.m3u8') && !requestUrl.contains('ad.html') && !completer.isCompleted) {
          debugPrint('[SCRAPER] SUCCESS (Intercept): Captured .m3u8: $requestUrl');
          completer.complete(requestUrl);
        }
        return null;
      },
      onLoadStop: (controller, webUrl) async {
        debugPrint('[SCRAPER] Page load complete. Monitoring stream via interactions...');
        
        // Iteratively try to trigger playback and scan for player variables
        for (int i = 0; i < 15; i++) {
          if (completer.isCompleted) return;
          
          final jsResult = await controller.evaluateJavascript(source: """
            (function() {
              // 1. Attempt to click through "click-to-play" overlays
              var selectors = ['.play-button', '#play', '.ytp-large-play-button', '#player', '.player-poster', 'video', '.play_icon'];
              selectors.forEach(function(s) {
                var el = document.querySelector(s);
                if (el) { el.click(); if(el.play) el.play(); }
              });

              function scan(w, depth) {
                if (depth > 3) return null;
                try {
                  // 2. Scan standard player objects for resolved stream URLs
                  if (w.hls && w.hls.url) return w.hls.url;
                  if (w.player && w.player.src) return typeof w.player.src === 'function' ? w.player.src() : w.player.src;
                  if (w.clappr && w.clappr.player && w.clappr.player.options) return w.clappr.player.options.source;
                  if (w.jwplayer && w.jwplayer().getPlaylist) {
                    var pl = w.jwplayer().getPlaylist();
                    if (pl && pl[0] && pl[0].file) return pl[0].file;
                  }
                  
                  var v = w.document.querySelector('video');
                  if (v && v.src && v.src.includes('.m3u8')) return v.src;
                  var s = w.document.querySelector('source');
                  if (s && s.src && s.src.includes('.m3u8')) return s.src;
                  
                  var frames = w.document.querySelectorAll('iframe');
                  for (var j = 0; j < frames.length; j++) {
                    var found = scan(frames[j].contentWindow, depth + 1);
                    if (found) return found;
                  }
                } catch(e) {}
                return null;
              }

              return scan(window, 0) || '';
            })()
          """);

          if (jsResult != null && jsResult.toString().isNotEmpty && !completer.isCompleted) {
            debugPrint('[SCRAPER] SUCCESS (JS Scan): Found URL via script: $jsResult');
            completer.complete(jsResult.toString());
            return;
          }
          await Future.delayed(const Duration(seconds: 2));
        }
      },
    );

    try {
      await headlessWebView.run();
      // Extended timeout for slow, ad-heavy mirrors
      final result = await completer.future.timeout(const Duration(seconds: 40), onTimeout: () {
        debugPrint('[SCRAPER] Aggressive session timed out.');
        return null;
      });
      return result;
    } catch (e) {
      debugPrint('[SCRAPER] Headless session critical error: $e');
      return null;
    } finally {
      await headlessWebView.dispose();
    }
  }

  Future<List<Sport>> fetchSports() async {
    if (_sportsCache.isNotEmpty) return _sportsCache;
    try {
      final response = await _get('/sports');
      if (response.statusCode == 200) {
        List<int> bytes = response.bodyBytes;
        
        // Skipping manual gzip decode for WASM compatibility. 
        // Browser naturally handles Content-Encoding: gzip.

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
  static Future<String?> _extractCdnLiveTvStream(String playerUrl, {String? referer}) async {
    try {
      debugPrint('[UNPACKER] Requesting Player Page: $playerUrl');
      final uri = Uri.tryParse(playerUrl);
      final actualReferer = referer ?? (uri?.hasScheme == true ? '${uri!.scheme}://${uri.host}/' : 'https://cdnlivetv.tv/');
      
      final response = await http.get(
        Uri.parse(playerUrl),
        headers: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
          'Referer': actualReferer,
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;
      final html = response.body;

      debugPrint('[UNPACKER] Identifying packed payload...');
      // Locate and isolate the payload string passed inside the packer function
      // Format: }("UUUmLUUm...", radix, ["dict"], offset, base)
      final packedRegex = RegExp(r'\}\s*\(\s*"([A-Za-z0-9+/=]+)"\s*,\s*(\d+)\s*,\s*\[([^\]]+)\]\s*,\s*(\d+)\s*,\s*(\d+)');
      final match = packedRegex.firstMatch(html);

      if (match == null) {
        debugPrint('[UNPACKER] FAILED: No packed JS payload found in source.');
        return null;
      }

      debugPrint('[UNPACKER] SUCCESS: Payload found. Beginning decryption loop...');
      final String h = match.group(1) ?? "";          // Encrypted string
      final String rawN = match.group(3) ?? "";       // Dictionary array
      final int t = int.tryParse(match.group(4) ?? "0") ?? 0;   // Offset
      final int e = int.tryParse(match.group(5) ?? "0") ?? 0;   // Base index

      if (h.isEmpty || rawN.isEmpty) return null;

      final List<String> n = rawN
          .split(',')
          .map((s) => s.trim().replaceAll('"', '').replaceAll("'", ""))
          .toList();

      // Safety check for dictionary bounds
      if (e >= n.length) return null;
      final String delimiter = n[e];

      String unpackedResult = "";
      int i = 0;
      
      while (i < h.length) {
        String s = "";
        while (i < h.length && h[i] != delimiter) {
          s += h[i];
          i++;
        }
        
        if (s.isNotEmpty) {
          // Decode base-radix and subtract offset t
          int decodedVal = _baseRadixDecode(s, e) - t;
          if (decodedVal > 0) {
            unpackedResult += String.fromCharCode(decodedVal);
          }
        }
        i++; // Skip delimiter
      }

      final unpackedHtml = Uri.decodeComponent(unpackedResult);

      // Pluck raw .m3u8 link from the unpacked source
      final streamRegex = RegExp(r'''(https://[^\s"']+\.m3u8[^\s"']*)''');
      final streamMatch = streamRegex.firstMatch(unpackedHtml);

      if (streamMatch != null && (streamMatch.group(0)?.isNotEmpty ?? false)) {
        final foundUrl = (streamMatch.group(0) ?? "").replaceAll(RegExp(r'[\s\n\r]'), '');
        debugPrint('[UNPACKER] SUCCESS: Extracted M3U8: $foundUrl');
        return foundUrl;
      }
      debugPrint('[UNPACKER] FAILED: No .m3u8 link found in unpacked source.');
    } catch (err) {
      debugPrint("[UNPACKER] CRITICAL ERROR: $err");
    }
    return null;
  }

  static int _baseRadixDecode(String digitStr, int base) {
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+/";
    int val = 0;
    List<String> chars = digitStr.split('').reversed.toList();
    for (int c = 0; c < chars.length; c++) {
      int index = alphabet.indexOf(chars[c]);
      if (index != -1) {
        val += (index * pow(base, c)).toInt();
      }
    }
    return val;
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

final List<Match> premiumChannelsList = [
   Match.premium(id: '766', title: 'ABC', logoUrl: 'https://1000logos.net/wp-content/uploads/2021/10/ABC-logo.png', epgId: 'WABCTV71.us'),
   Match.premium(id: '52', title: 'CBS', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/b/bd/CBS_Eyemark.svg/960px-CBS_Eyemark.svg.png', epgId: 'WFORTV41.us'),
  Match.premium(id: '308', title: 'CBS Sports Network', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/04/CBS_Sports_Network_2021.svg/960px-CBS_Sports_Network_2021.svg.png', epgId: 'CBSSportsNetwork.us'),
  Match.premium(id: '300', title: 'CW', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/b/b1/The_CW_2024.svg/960px-The_CW_2024.svg.png', epgId: 'CW.us'),
  Match.premium(id: '44', title: 'ESPN', logoUrl: 'https://1000logos.net/wp-content/uploads/2021/05/ESPN-logo-1536x922.png', epgId: 'ESPN.us'),
  Match.premium(id: '45', title: 'ESPN2', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/b/bf/ESPN2_logo.svg/960px-ESPN2_logo.svg.png', epgId: 'ESPN2.us'),
  Match.premium(id: '316', title: 'ESPN U', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/c/ca/ESPN_U_logo.svg/960px-ESPN_U_logo.svg.png', epgId: 'ESPNU.us'),
  Match.premium(id: '60', title: 'F1 (Sky Sports)', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/f/fa/Sky_Sports_F1_-_Logo_2025.svg/960px-Sky_Sports_F1_-_Logo_2025.svg.png', epgId: 'SkySportsF1.uk'),
  Match.premium(id: '54', title: 'Fox', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c0/Fox_Broadcasting_Company_logo_%282019%29.svg/960px-Fox_Broadcasting_Company_logo_%282019%29.svg.png', epgId: 'WSVN71.us'),
  Match.premium(id: '39', title: 'FS1', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/3/37/2015_Fox_Sports_1_logo.svg/960px-2015_Fox_Sports_1_logo.svg.png', epgId: 'FoxSports1.us'),
  Match.premium(id: '758', title: 'FS2', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/3/38/FS2_logo_2015.svg/960px-FS2_logo_2015.svg.png', epgId: 'FoxSports2.us'),
  Match.premium(id: '318', title: 'GOLF Channel', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/f/fb/Golf_Channel_logo_2025.svg/960px-Golf_Channel_logo_2025.svg.png', epgId: 'GolfChannel.us'),
  Match.premium(id: '325', title: 'ion', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/2/28/Ion_logo.svg/960px-Ion_logo.svg.png', epgId: 'IONTV.us'),
  Match.premium(id: '404', title: 'NBA TV', logoUrl: 'https://lunardrift.watch/scnsht/nbatv.png', epgId: 'NBATV.us'),
  Match.premium(id: '769', title: 'NBC', logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/7/7a/NBC_logo_2022_%28vertical%29.svg/960px-NBC_logo_2022_%28vertical%29.svg.png', epgId: 'WNBC471.us'),
  Match.premium(id: '753', title: 'NBC Sports Bay Area', logoUrl: 'https://iptv-org.github.io/logos/channels/en/NBCSportsBayArea.png', epgId: 'NBCSportsBayArea.us'),
  Match.premium(id: '754', title: 'NBC Sports Boston', logoUrl: 'https://iptv-org.github.io/logos/channels/en/NBCSportsBoston.png', epgId: 'NBCSportsBoston.us'),
  Match.premium(id: '755', title: 'NBC Sports California', logoUrl: 'https://iptv-org.github.io/logos/channels/en/NBCSportsCalifornia.png', epgId: 'NBCSportsCalifornia.us'),
  Match.premium(id: '777', title: 'NBC Sports Philadelphia', logoUrl: 'https://iptv-org.github.io/logos/channels/en/NBCSportsPhiladelphia.png', epgId: 'NBCSportsPhiladelphia.us'),
  Match.premium(id: '405', title: 'NFL Network', logoUrl: 'https://iptv-org.github.io/logos/channels/en/NFLNetwork.png', epgId: 'NFLNetwork.us'),
  Match.premium(id: '663', title: 'NHL Network', logoUrl: 'https://iptv-org.github.io/logos/channels/en/NHLNetwork.png', epgId: 'NHLNetwork.us'),
  Match.premium(id: '408', title: 'SportsNet East', logoUrl: 'https://iptv-org.github.io/logos/channels/en/SpectrumSportsNet.png', epgId: 'SpectrumSportsNet.us'), 
  Match.premium(id: '764', title: 'SportsNet LA', logoUrl: 'https://iptv-org.github.io/logos/channels/en/SpectrumSportsNetLA.png', epgId: 'SpectrumSportsNetLA.us'),
  Match.premium(id: '759', title: 'SportsNet NY', logoUrl: 'https://iptv-org.github.io/logos/channels/en/SNY.png', epgId: 'SNY.us'),
  Match.premium(id: '407', title: 'SportsNet West', logoUrl: 'https://iptv-org.github.io/logos/channels/en/SpectrumSportsNet.png', epgId: 'SpectrumSportsNet.us'),
  Match.premium(id: '982', title: 'SportsNet USA', logoUrl: 'https://iptv-org.github.io/logos/channels/en/SpectrumSportsNet.png', epgId: 'SpectrumSportsNet.us'),
  Match.premium(id: '336', title: 'tbs', logoUrl: 'https://iptv-org.github.io/logos/channels/en/TBS.png', epgId: 'TBS.us'),
  Match.premium(id: '338', title: 'TNT', logoUrl: 'https://iptv-org.github.io/logos/channels/en/TNT.png', epgId: 'TNT.us'),
  Match.premium(id: '40', title: 'TNT Sports', logoUrl: 'https://iptv-org.github.io/logos/channels/en/TNTSports.png', epgId: 'TNTSports.uk'),
  Match.premium(id: '341', title: 'truTV', logoUrl: 'https://iptv-org.github.io/logos/channels/en/TruTV.png', epgId: 'truTV.us'),
  Match.premium(id: '343', title: 'USA', logoUrl: 'https://iptv-org.github.io/logos/channels/en/USANetwork.png', epgId: 'USANetwork.us'),
  Match.premium(id: 'https://cdnlivetv.tv/api/v1/channels/player/?name=NBA%20League%20Pass%201&code=us&user=cdnlivetv&plan=free''', title: 'NBA League Pass 1', logoUrl: 'https://iptv-org.github.io/logos/channels/en/NBALeaguePass.png', epgId: 'NBALeaguePass1.us'),
];


class _LiveTVPageState extends State<LiveTVPage> {
  final _api = LiveSportsApi();
  bool _isLoading = true;
  // ignore: unused_field
  List<Sport> _sports = [];
  List<Match> _allMatches = [];

  // ignore: unused_field
  final List<Match> _premiumChannels = premiumChannelsList;

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

      final interestedEpgIds = premiumChannelsList
          .map((m) => m.epgId)
          .whereType<String>()
          .toSet();

      await EpgService().fetchAndParseEPG(interestedChannelIds: interestedEpgIds);

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
          const SliverToBoxAdapter(
            child: PremiumChannelGuide(),
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


class PremiumChannelGuide extends StatefulWidget {
  const PremiumChannelGuide({super.key});

  @override
  State<PremiumChannelGuide> createState() => _PremiumChannelGuideState();
}

class _PremiumChannelGuideState extends State<PremiumChannelGuide> {
  final ScrollController _scrollController = ScrollController();
  bool _isHovering = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateScrollButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateScrollButtons());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateScrollButtons);
    _scrollController.dispose();
    super.dispose();
  }

  void _updateScrollButtons() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final canScrollLeft = position.pixels > 0;
    final canScrollRight = position.pixels < position.maxScrollExtent;

    if (_canScrollLeft != canScrollLeft || _canScrollRight != canScrollRight) {
      setState(() {
        _canScrollLeft = canScrollLeft;
        _canScrollRight = canScrollRight;
      });
    }
  }

  void _scroll(double amount) {
    if (!_scrollController.hasClients) return;
    final target = (_scrollController.offset + amount).clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Text(
            'CHANNEL GUIDE',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ),
        MouseRegion(
          onEnter: isMobile ? null : (_) => setState(() => _isHovering = true),
          onExit: isMobile ? null : (_) => setState(() => _isHovering = false),
          child: SizedBox(
            height: 110,
            child: Stack(
              children: [
                ListView.builder(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  itemCount: premiumChannelsList.length,
                  itemBuilder: (context, index) {
                    final channel = premiumChannelsList[index];
                    final currentProgram = EpgService().getCurrentProgram(channel.epgId);

                    return GestureDetector(
                      onTap: () => handleMatchTap(context, channel),
                      child: Container(
                        width: 220,
                        margin: const EdgeInsets.symmetric(horizontal: 4.0),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1F24),
                          borderRadius: BorderRadius.circular(8.0),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Row(
                          children: [
                            _TeamLogo(url: channel.teamALogo, size: 45),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    channel.title,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    currentProgram?.title ?? 'No info available',
                                    style: const TextStyle(color: Color(0xFF1CE783), fontSize: 11, fontWeight: FontWeight.w600),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                if (!isMobile) ...[
                  IgnorePointer(
                    ignoring: !(_isHovering && _canScrollLeft),
                    child: AnimatedOpacity(
                      opacity: (_isHovering && _canScrollLeft) ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8.0),
                          child: IconButton(
                            iconSize: 32,
                            color: Colors.white,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black.withOpacity(0.7),
                              hoverColor: Colors.black,
                            ),
                            icon: const Icon(Icons.chevron_left),
                            onPressed: _canScrollLeft ? () => _scroll(-800) : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    ignoring: !(_isHovering && _canScrollRight),
                    child: AnimatedOpacity(
                      opacity: (_isHovering && _canScrollRight) ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: IconButton(
                            iconSize: 32,
                            color: Colors.white,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black.withOpacity(0.7),
                              hoverColor: Colors.black,
                            ),
                            icon: const Icon(Icons.chevron_right),
                            onPressed: _canScrollRight ? () => _scroll(800) : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// --- Match Display Widgets ---

class HorizontalMatchList extends StatefulWidget {
  final String categoryTitle;
  final List<Match> items;

  const HorizontalMatchList({super.key, required this.categoryTitle, required this.items});

  @override
  State<HorizontalMatchList> createState() => _HorizontalMatchListState();
}

class _HorizontalMatchListState extends State<HorizontalMatchList> {
  final ScrollController _scrollController = ScrollController();
  bool _isHovering = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateScrollButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateScrollButtons());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateScrollButtons);
    _scrollController.dispose();
    super.dispose();
  }

  void _updateScrollButtons() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final canScrollLeft = position.pixels > 0;
    final canScrollRight = position.pixels < position.maxScrollExtent;

    if (_canScrollLeft != canScrollLeft || _canScrollRight != canScrollRight) {
      setState(() {
        _canScrollLeft = canScrollLeft;
        _canScrollRight = canScrollRight;
      });
    }
  }

  void _scroll(double amount) {
    if (!_scrollController.hasClients) return;
    final target = (_scrollController.offset + amount).clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Text(
            widget.categoryTitle.toUpperCase(),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ),
        MouseRegion(
          onEnter: isMobile ? null : (_) => setState(() => _isHovering = true),
          onExit: isMobile ? null : (_) => setState(() => _isHovering = false),
          child: SizedBox(
            height: 175,
            child: Stack(
              children: [
                ListView.builder(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  itemCount: widget.items.length,
                  itemBuilder: (context, index) => MatchCard(match: widget.items[index]),
                ),
                if (!isMobile) ...[
                  IgnorePointer(
                    ignoring: !(_isHovering && _canScrollLeft),
                    child: AnimatedOpacity(
                      opacity: (_isHovering && _canScrollLeft) ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8.0),
                          child: IconButton(
                            iconSize: 32,
                            color: Colors.white,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black.withOpacity(0.7),
                              hoverColor: Colors.black,
                            ),
                            icon: const Icon(Icons.chevron_left),
                            onPressed: _canScrollLeft ? () => _scroll(-800) : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                  IgnorePointer(
                    ignoring: !(_isHovering && _canScrollRight),
                    child: AnimatedOpacity(
                      opacity: (_isHovering && _canScrollRight) ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: IconButton(
                            iconSize: 32,
                            color: Colors.white,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black.withOpacity(0.7),
                              hoverColor: Colors.black,
                            ),
                            icon: const Icon(Icons.chevron_right),
                            onPressed: _canScrollRight ? () => _scroll(800) : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// --- Navigation Helper ---
Future<void> handleMatchTap(BuildContext context, Match match) async {
  if (match.isLive || match.isPremium) {
    // Show a loading dialog while we fetch the specific live stream info
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator(color: Color.fromARGB(255, 250, 250, 250))),
    );

    String? streamUrl;
    Map<String, String>? customHeaders;

    const int maxRetries = 5;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      debugPrint('[SCRAPER] Attempt $attempt for channel: ${match.title}');
      
      if (match.isPremium) {
        streamUrl = await LiveSportsApi.extractM3u8Stream(match.id);
        if (streamUrl != null) {
          final uri = Uri.tryParse(match.id);
          final origin = uri?.hasScheme == true ? uri!.origin : 'https://dlhd.pk';
          final referer = uri?.hasScheme == true ? match.id : 'https://dlhd.pk/';
          
          customHeaders = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
            'Referer': referer,
            'Origin': origin,
            'Accept': '*/*',
            'Accept-Language': 'en-US,en;q=0.9',
            'Sec-Ch-Ua': '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
            'Sec-Ch-Ua-Mobile': '?0',
            'Sec-Ch-Ua-Platform': '"Windows"',
            'Sec-Fetch-Dest': 'empty',
            'Sec-Fetch-Mode': 'cors',
            'Sec-Fetch-Site': 'cross-site',
          };
          break; // Success, exit loop
        }
      } else if (match.sources.isNotEmpty) {
        // Default to the second source if available
        final source =
            match.sources.length > 1 ? match.sources[1] : match.sources.first;
        final embedUrl = await LiveSportsApi().fetchStreamUrl(
          source['source']!,
          source['id']!,
        );

        if (embedUrl != null) {
          debugPrint('[SCRAPER] Live match embed found ($embedUrl). Scraping for source...');
          streamUrl = await LiveSportsApi.extractM3u8Stream(embedUrl);
          
          if (streamUrl != null) {
            // Set headers based on the embed source to prevent 403 Forbidden
            customHeaders = {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
              'Referer': embedUrl,
              'Origin': Uri.tryParse(embedUrl)?.hasScheme == true ? Uri.parse(embedUrl).origin : embedUrl,
              'Accept': '*/*',
              'Accept-Language': 'en-US,en;q=0.9',
              'Sec-Fetch-Dest': 'empty',
              'Sec-Fetch-Mode': 'cors',
              'Sec-Fetch-Site': 'cross-site',
            };
            break; // Success, exit loop
          }
        }
      }
      
      if (attempt < maxRetries) {
        // Small incremental delay between retries
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }

    if (context.mounted) {
      Navigator.of(context).pop(); // Dismiss the loading dialog

      if (streamUrl != null && streamUrl.isNotEmpty) {
        // Append autoplay parameter if not already present
        if (!match.isPremium && !streamUrl.contains('autoplay=')) {
          final separator = streamUrl.contains('?') ? '&' : '?';
          // ignore: unnecessary_brace_in_string_interps
          streamUrl = '${streamUrl}${separator}autoplay=1';
        }

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VideoPlayerPage(
              videoUrl: streamUrl!,
              sources: match.sources,
              matchTitle: match.title,
              customHeaders: customHeaders,
            ),
          ),
        );
      } else {
        AppNotification.show(
          context,
          'No active streams available for this ${match.isPremium ? 'channel' : 'match'}.',
          color: Colors.red,
        );
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
                    httpHeaders: const {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'},
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
                    if (match.isPremium)
                      Expanded(
                        child: Center(
                          child: _TeamLogo(url: match.teamALogo, size: 65),
                        ),
                      )
                    else
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
      return Container(width: size, height: size, decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.shield, color: Colors.white24));
    }
    return CachedNetworkImage(
      imageUrl: url,
      width: size,
      height: size,
      fit: BoxFit.contain,
      httpHeaders: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
      },
      placeholder: (context, url) => Container(width: size, height: size, decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8))),
      errorWidget: (context, url, error) => Container(width: size, height: size, decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.shield, color: Colors.white24)),
    );
  }
}