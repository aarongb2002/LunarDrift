// ignore_for_file: unnecessary_cast, use_null_aware_elements, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'package:media_kit/media_kit.dart' hide PlayerState;
import 'package:media_kit_video/media_kit_video.dart';
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
// ignore: unused_import
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:webview_win_floating/webview_win_floating.dart';
import 'package:webview_flutter/webview_flutter.dart';
// ignore: depend_on_referenced_packages, unnecessary_import
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart' as gsi;
// ignore: unused_import
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'firebase_options.dart';
import 'live_tv_page.dart';
import 'schedule_guide_page.dart';
// ignore: unused_import
import 'web_player_stub.dart' if (dart.library.js_interop) 'web_player.dart';
// ignore: unused_import
import 'web_button_stub.dart' if (dart.library.js_interop) 'web_button.dart';
import 'download_manager.dart';

const String tmdbApiKey = '1334200a3782740ce2c83ced081d086e';
final Map<String, dynamic> _apiCache = {};

class WatchlistManager {
  static const _key = 'userWatchlist';
  static final _db = FirebaseFirestore.instance;

  static Future<List<Map<String, dynamic>>> getWatchlist() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user != null) {
      try {
        final snapshot = await _db
            .collection('users')
            .doc(user.uid)
            .collection('watchlist')
            .orderBy('added_at', descending: true)
            .get();
        if (snapshot.docs.isNotEmpty) {
          return snapshot.docs.map((doc) => doc.data()).toList();
        }
      } catch (e) {
        debugPrint('Firestore fetch error: $e');
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final items = prefs.getStringList(_key) ?? [];
    try {
      return items
          .map((item) => json.decode(item) as Map<String, dynamic>)
          .toList();
    } catch (e) {
      await prefs.remove(_key);
      return [];
    }
  }

  static Future<bool> isOnWatchlist(dynamic mediaId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && mediaId != null) {
      final doc = await _db
          .collection('users')
          .doc(user.uid)
          .collection('watchlist')
          .doc(mediaId.toString())
          .get();
      return doc.exists;
    }
    final watchlist = await getWatchlist();
    return watchlist.any((item) => item['id'] == mediaId);
  }

  static Future<void> addToWatchlist(dynamic media) async {
    final Map<String, dynamic> itemToCache = {
      'id': media['id']?.toString() ?? '',
      'media_type':
          media['media_type'] ??
          (media['first_air_date'] != null ? 'tv' : 'movie'),
      'added_at': DateTime.now().toIso8601String(),
    };

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await _db
          .collection('users')
          .doc(user.uid)
          .collection('watchlist')
          .doc(media['id'].toString())
          .set(itemToCache);
    }

    final watchlist = await getWatchlist();
    if (watchlist.any((item) => item['id'] == media['id'])) {
      return; // Already exists
    }

    watchlist.insert(0, itemToCache);
    await _saveWatchlist(watchlist);
  }

  static Future<void> removeFromWatchlist(dynamic mediaId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await _db
          .collection('users')
          .doc(user.uid)
          .collection('watchlist')
          .doc(mediaId.toString())
          .delete();
    }

    final watchlist = await getWatchlist();
    watchlist.removeWhere((item) => item['id'] == mediaId);
    await _saveWatchlist(watchlist);
  }

  static Future<void> _saveWatchlist(
    List<Map<String, dynamic>> watchlist,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final items = watchlist.map((item) => json.encode(item)).toList();
    await prefs.setStringList(_key, items);
  }
}

class ProgressManager {
  static final _db = FirebaseFirestore.instance;

  static Future<void> saveProgress({
    required dynamic media,
    required double progress,
    int? season,
    int? episode,
    int? position,
    int? runtime,
    bool isStart = false,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null ||
        media == null ||
        (media['id'] == null && media['show_id'] == null)) {
      return;
    }

    final String mediaId = (media['id'] ?? media['show_id'] ?? '').toString();
    if (mediaId.isEmpty) return;
    final String mediaType =
        (media['media_type'] ??
                (media['first_air_date'] != null ? 'tv' : 'movie'))
            .toString();
    final isTv = mediaType == 'tv';

    // Unique ID for episodes, shared ID for movies
    final docId = isTv ? '${mediaId}_s${season}_e$episode' : mediaId;
    final String safeId = mediaId.toString();

    final data = {
      'id': safeId,
      'media_type': mediaType,
      'progress': progress,
      'is_completed': progress >= 0.9, // Mark as completed if > 90%
      'last_watched_at': FieldValue.serverTimestamp(),

      if (isTv) 'show_id': safeId, // Reference for grouping
      if (season != null) 'season': season,
      if (episode != null) 'episode': episode,
      if (position != null) 'position': position,
      if (runtime != null) 'runtime': runtime,
    };

    await _db
        .collection('users')
        .doc(user.uid)
        .collection('progress')
        .doc(docId)
        .set(data, SetOptions(merge: true));

    // Increment global watch counter if this is the start of a session
    if (isStart) {
      await _db.collection('global_trending').doc(safeId).set({
        'id': safeId,
        'media_type': mediaType,
        'watch_count': FieldValue.increment(1),
        'last_watched_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  static Future<Map<String, dynamic>?> getProgress(
    dynamic mediaId, {
    int? season,
    int? episode,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || mediaId == null) return null;

    final isTv = season != null && episode != null;
    // ignore: unnecessary_brace_in_string_interps
    final String docId = isTv
        ? '${mediaId}_s${season}_e$episode'
        : mediaId.toString();

    final doc = await _db
        .collection('users')
        .doc(user.uid)
        .collection('progress')
        .doc(docId)
        .get();
    return doc.data();
  }

  static Future<List<Map<String, dynamic>>> getWatchHistory() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return [];

    final snapshot = await _db
        .collection('users')
        .doc(user.uid)
        .collection('progress')
        .orderBy('last_watched_at', descending: true)
        .limit(21)
        .get();

    final List<Map<String, dynamic>> results = [];
    final Set<String> seenShowIds = {};

    for (var doc in snapshot.docs) {
      final data = doc.data();
      if (data['media_type'] == 'tv') {
        final showId = data['show_id']?.toString();
        if (showId != null && !seenShowIds.add(showId)) continue;
      }
      results.add(data);
    }
    return results;
  }

  static Future<List<Map<String, dynamic>>> getShowProgress(
    dynamic showId,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || showId == null) return [];

    final snapshot = await _db
        .collection('users')
        .doc(user.uid)
        .collection('progress')
        .where(
          'show_id',
          isEqualTo: showId,
        ) // Firestore can query by mixed types if necessary, but TMDb IDs are preferred
        .get();

    return snapshot.docs.map((doc) => doc.data()).toList();
  }

  static Future<List<Map<String, dynamic>>> getContinueWatching() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return [];

    final snapshot = await _db
        .collection('users')
        .doc(user.uid)
        .collection('progress')
        .orderBy('last_watched_at', descending: true)
        .limit(
          60,
        ) // Fetch a larger pool to allow for filtering and deduplication
        .get();

    final List<Map<String, dynamic>> results = [];
    final Set<String> seenShowIds = {};

    for (var doc in snapshot.docs) {
      final data = doc.data();

      // 1. Only show partially watched films/episodes (< 90%)
      final bool isCompleted = data['is_completed'] ?? false;
      if (isCompleted) continue;

      // 2. For TV shows, only show the latest episode being watched
      final mediaType = data['media_type'];
      if (mediaType == 'tv') {
        final showId = data['show_id']?.toString();
        if (showId != null) {
          if (seenShowIds.contains(showId)) continue;
          seenShowIds.add(showId);
        }
      }

      results.add(data);
      if (results.length >= 20) break;
    }

    return results;
  }

  static Future<List<Map<String, dynamic>>> getGlobalTrending() async {
    try {
      final snapshot = await _db
          .collection('global_trending')
          .orderBy('watch_count', descending: true)
          .limit(10)
          .get();
      return snapshot.docs.map((doc) => doc.data()).toList();
    } catch (e) {
      debugPrint('Error fetching global trending: $e');
      return [];
    }
  }

  static Future<void> deleteProgress(
    dynamic mediaId,
    String? mediaType, {
    int? season,
    int? episode,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null ||
        mediaType == null ||
        mediaId == null ||
        mediaId.toString().isEmpty) {
      return;
    }

    if (mediaType == 'tv') {
      if (season != null && episode != null) {
        // Delete only this specific episode
        final docId = '${mediaId}_s${season}_e$episode';
        await _db
            .collection('users')
            .doc(user.uid)
            .collection('progress')
            .doc(docId)
            .delete();
      } else {
        // Delete all episodes for this show
        final snapshot = await _db
            .collection('users')
            .doc(user.uid)
            .collection('progress')
            .where('show_id', isEqualTo: mediaId.toString())
            .get();

        final batch = _db.batch();
        for (var doc in snapshot.docs) {
          batch.delete(doc.reference);
        }
        await batch.commit();
      }
    } else {
      final docId = mediaId.toString();
      await _db
          .collection('users')
          .doc(user.uid)
          .collection('progress')
          .doc(docId)
          .delete();
    }
  }

  static Future<void> clearWatchHistory() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await _db
        .collection('users')
        .doc(user.uid)
        .collection('progress')
        .get();

    final batch = _db.batch();
    for (var doc in snapshot.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }
}

bool _isGoogleSignInInitialized = false;

Future<dynamic> fetchWithCache(String url, {bool forceRefresh = false}) async {
  if (!forceRefresh && _apiCache.containsKey(url)) {
    return _apiCache[url];
  }
  try {
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode == 200) {
      List<int> bytes = response.bodyBytes;

      // Manual Gzip check: Some network environments or proxies return compressed data
      // without the correct 'Content-Encoding' header, causing utf8.decode to fail.
      // Gzip magic number is 0x1F 0x8B.
      if (!kIsWeb &&
          bytes.length >= 2 &&
          bytes[0] == 0x1F &&
          bytes[1] == 0x8B) {
        try {
          bytes = gzip.decode(bytes);
        } catch (e) {
          debugPrint('Gzip manual decode failed, attempting raw: $e');
        }
      }

      final String decodedBody = utf8.decode(bytes);
      final data = json.decode(decodedBody);
      _apiCache[url] = data;
      return data;
    } else {
      throw Exception('Failed to load data: ${response.statusCode}');
    }
  } catch (e) {
    debugPrint('fetchWithCache error for $url: $e');
    rethrow;
  }
}

bool _isReleased(dynamic item, {bool strictFilter = false}) {
  if (item is! Map) return false;

  // Filter out explicit adult content globally
  if (item['adult'] == true || item['adult'] == 'true') {
    return false;
  }

  final originalLanguage = item['original_language']?.toString();
  if (originalLanguage != null && originalLanguage != 'en') {
    // Allow foreign languages ONLY for Anime (Animation genre 16 + Japanese language)
    final List genreIds = item['genre_ids'] is List
        ? item['genre_ids'] as List
        : [];
    final isAnime = genreIds.contains(16) && originalLanguage == 'ja';
    if (!isAnime) return false;
  }

  if (strictFilter) {
    // Hide documentaries (Genre ID 99) from general browsing/home pages
    if (item['genre_ids'] is List && (item['genre_ids'] as List).contains(99)) {
      return false;
    }
  }

  if (strictFilter) {
    final voteAverageRaw = item['vote_average'];
    if (voteAverageRaw != null) {
      final voteAverage = double.tryParse(voteAverageRaw.toString()) ?? 0.0;
      if (voteAverage == 0.0) return false;
    }
  }
  final mediaType = item['media_type'];
  final isMovie =
      mediaType == 'movie' ||
      (mediaType == null &&
          item['title'] != null &&
          item['release_date'] != null);

  if (isMovie) {
    // Filter out short films (< 20 mins) if runtime data is present
    final runtimeRaw = item['runtime'];
    if (runtimeRaw != null) {
      final runtime = double.tryParse(runtimeRaw.toString()) ?? 0.0;
      if (runtime > 0 && runtime < 20) return false;
    }

    final releaseDateStr = item['release_date']?.toString();
    if (releaseDateStr == null || releaseDateStr.trim().isEmpty) return false;
    try {
      final releaseDate = DateTime.parse(releaseDateStr);
      if (releaseDate.isAfter(DateTime.now())) return false;
    } catch (_) {}
  }
  return true;
}

Future<void> main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();

    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }

    // Initialize MediaKit after Firebase to ensure the platform thread 
    // is ready to handle the native DLL hooks.
    MediaKit.ensureInitialized();



    // Set preferred orientation to portrait on app startup for mobile.
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS)) {
      await windowManager.ensureInitialized();
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      WindowsWebViewPlatform.registerWith();
    }
    runApp(const MyApp());
  } catch (e, stackTrace) {
    debugPrint('App initialization error: $e\n$stackTrace');
    runApp(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF0F1014),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Text(
                'Failed to launch:\n\n$e',
                style: const TextStyle(color: Colors.red, fontSize: 16),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NativeTestPlayerPage extends StatefulWidget {
  final String streamUrl;
  const NativeTestPlayerPage({super.key, required this.streamUrl});

  @override
  State<NativeTestPlayerPage> createState() => _NativeTestPlayerPageState();
}

class _NativeTestPlayerPageState extends State<NativeTestPlayerPage> {
  late final Player _player = Player();
  late final VideoController _videoController = VideoController(_player);
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _refererController = TextEditingController(text: "https://player.videasy.net/");
  final TextEditingController _originController = TextEditingController(text: "https://player.videasy.net");

  @override
  void initState() {
    super.initState();
    _urlController.text = widget.streamUrl;
    if (widget.streamUrl.isNotEmpty) {
      _setupPlayer(widget.streamUrl, _refererController.text, _originController.text);
    }
  }

  void _setupPlayer(String url, String referer, String origin) {
    if (url.isEmpty) return;

    final headers = {
      "Referer": referer,
      "Origin": origin,
      "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    };

    if (!kIsWeb && _player.platform is NativePlayer) {
      final dynamic nativePlayer = _player.platform;
      try {
        nativePlayer.setProperty('referrer', referer);
        nativePlayer.setProperty('user-agent', headers['User-Agent']!);
        
        final headerFields = headers.entries.map((e) => "${e.key}: ${e.value}").join(',');
        nativePlayer.setProperty('http-header-fields', headerFields);
      } catch (e) {
        debugPrint("Failed to set native player test headers: $e");
      }
    }

    _player.open(
      Media(
        url,
        httpHeaders: headers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("Native Player Test", style: TextStyle(color: Colors.white)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _urlController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: "Paste .m3u8 link here",
                          hintStyle: TextStyle(color: Colors.white54),
                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: () => _setupPlayer(
                        _urlController.text.trim(),
                        _refererController.text.trim(),
                        _originController.text.trim(),
                      ),
                      child: const Text("Load"),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _refererController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: "Referer Header",
                          labelStyle: TextStyle(color: Colors.white54),
                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _originController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: "Origin Header",
                          labelStyle: TextStyle(color: Colors.white54),
                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: Video(controller: _videoController),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _refererController.dispose();
    _originController.dispose();
    _player.dispose();
    super.dispose();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LunarDrift',
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0F1014),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromARGB(255, 254, 255, 255), // Hulu Green
          brightness: Brightness.dark,
          primary: const Color.fromARGB(255, 176, 176, 176),
        ),
      ),
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  Stream<User?>? _authStream;

  @override
  void initState() {
    super.initState();
    // Delay the stream subscription slightly on Windows to ensure the platform thread 
    // and message pump are fully ready to handle background callbacks from native code.
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _authStream = FirebaseAuth.instance.authStateChanges();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_authStream == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0F1014),
        body: Center(
          child: CircularProgressIndicator(
            color: Color.fromARGB(255, 252, 253, 253),
          ),
        ),
      );
    }
    return StreamBuilder<User?>(
      stream: _authStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFF0F1014),
            body: Center(
              child: CircularProgressIndicator(
                color: Color.fromARGB(255, 252, 253, 253),
              ),
            ),
          );
        }
        if (snapshot.hasData) {
          return const TMDBHomePage(title: 'cinestream');
        }
        return const LoginPage();
      },
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
  }

  Future<void> _authenticate(bool isSignUp) async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      AppNotification.show(
        context,
        'Please enter both email and password.',
        color: Colors.red,
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      if (isSignUp) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      }
    } catch (e) {
      String errorMessage = e.toString();

      // The Firebase Desktop SDK maps "INVALID_LOGIN_CREDENTIALS" to a generic internal error.
      if (e is FirebaseAuthException && e.code == 'internal-error') {
        if (!kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.linux)) {
          errorMessage =
              'Invalid email or password. (If you created this account with Google/Microsoft, please use those buttons).';
        }
      }

      if (mounted) {
        AppNotification.show(context, errorMessage, color: Colors.red);
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.linux)) {
        // --- NATIVE DESKTOP LOOPBACK WORKAROUND ---

        // You MUST create a "Desktop app" OAuth Client ID in Google Cloud Console
        const String clientId =
            '651005734001-e060vcsc7hslmcb4joemh194ms4vits1.apps.googleusercontent.com';
        const String clientSecret = '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';

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final redirectUri = 'http://localhost:${server.port}';

        final authUrl =
            'https://accounts.google.com/o/oauth2/v2/auth'
            '?client_id=$clientId'
            '&response_type=code'
            '&redirect_uri=$redirectUri'
            '&scope=openid%20email%20profile';

        if (defaultTargetPlatform == TargetPlatform.windows) {
          await Process.run('cmd', [
            '/c',
            'start',
            authUrl.replaceAll('&', '^&'),
          ]);
        } else {
          await Process.run('xdg-open', [authUrl]);
        }

        try {
          final request = await server.first.timeout(
            const Duration(minutes: 3),
          );
          final code = request.uri.queryParameters['code'];

          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              '<html><body style="background:#0F1014;color:#1CE783;text-align:center;margin-top:20%;font-family:sans-serif;"><h2>Login successful! You can close this window and return to LunarDrift.</h2><script>window.close();</script></body></html>',
            );
          await request.response.close();

          if (code != null) {
            final tokenResponse = await http.post(
              Uri.parse('https://oauth2.googleapis.com/token'),
              body: {
                'client_id': clientId,
                'client_secret': clientSecret,
                'code': code,
                'redirect_uri': redirectUri,
                'grant_type': 'authorization_code',
              },
            );

            if (tokenResponse.statusCode == 200) {
              final tokenData = json.decode(tokenResponse.body);
              final credential = GoogleAuthProvider.credential(
                idToken: tokenData['id_token'],
                accessToken: tokenData['access_token'],
              );
              await FirebaseAuth.instance.signInWithCredential(credential);
            } else {
              throw Exception(
                'Failed to exchange token: ${tokenResponse.body}',
              );
            }
          } else {
            throw Exception('No authorization code received.');
          }
        } on TimeoutException {
          throw Exception(
            'Sign-in timed out or was cancelled. Please try again.',
          );
        } finally {
          await server.close(force: true);
        }
      } else if (kIsWeb) {
        final googleProvider = GoogleAuthProvider();
        await FirebaseAuth.instance.signInWithPopup(googleProvider);
      } else {
        // Android / iOS native Google Sign-In
        if (!_isGoogleSignInInitialized) {
          await gsi.GoogleSignIn.instance.initialize(
            serverClientId:
                '651005734001-6034o9sft52au196976sqjidjqo8a9nv.apps.googleusercontent.com',
          );
          _isGoogleSignInInitialized = true;
        }

        // ignore: unnecessary_nullable_for_final_variable_declarations
        final gsi.GoogleSignInAccount? googleUser = await gsi
            .GoogleSignIn
            .instance
            .authenticate();

        if (googleUser == null) {
          // User cancelled the sign-in.
          return;
        }

        final gsi.GoogleSignInAuthentication googleAuth =
            googleUser.authentication; // Synchronous in v7+
        final OAuthCredential credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
        );

        await FirebaseAuth.instance.signInWithCredential(credential);
      }
    } catch (e) {
      if (e is FirebaseAuthException &&
          e.code == 'account-exists-with-different-credential') {
        if (mounted) {
          await _handleAccountLinking(e.credential, e.email);
        }
      } else {
        // Don't show an error if the user just cancelled the login flow.
        final isCancellation =
            e is FirebaseAuthException &&
            (e.code == 'web-context-cancelled' ||
                e.code == 'cancelled-popup-request');
        if (mounted) {
          if (!isCancellation) {
            AppNotification.show(context, e.toString(), color: Colors.red);
          }
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _signInWithMicrosoft() async {
    setState(() => _isLoading = true);
    try {
      if (kIsWeb) {
        final microsoftProvider = OAuthProvider('microsoft.com');
        microsoftProvider.addScope('User.Read');
        final userCred = await FirebaseAuth.instance.signInWithPopup(
          microsoftProvider,
        );
        final credential = userCred.credential;
        final token = credential is OAuthCredential
            ? credential.accessToken
            : null;
        if (userCred.user != null && token != null) {
          await _updateMicrosoftPhoto(userCred.user!, token);
        }
      } else {
        final microsoftProvider = OAuthProvider('microsoft.com');
        microsoftProvider.addScope('User.Read');
        final userCred = await FirebaseAuth.instance.signInWithProvider(
          microsoftProvider,
        );
        final credential = userCred.credential;
        final token = credential is OAuthCredential
            ? credential.accessToken
            : null;
        if (userCred.user != null && token != null) {
          await _updateMicrosoftPhoto(userCred.user!, token);
        }
      }
    } catch (e) {
      if (e is FirebaseAuthException &&
          e.code == 'account-exists-with-different-credential') {
        if (mounted) {
          await _handleAccountLinking(e.credential, e.email);
        }
      } else {
        final isCancellation =
            e is FirebaseAuthException &&
            (e.code == 'web-context-cancelled' ||
                e.code == 'cancelled-popup-request');
        if (mounted) {
          if (!isCancellation) {
            AppNotification.show(context, e.toString(), color: Colors.red);
          }
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _updateMicrosoftPhoto(User user, String accessToken) async {
    // Skip if they already have a standard URL (e.g. from a linked Google account)
    if (user.photoURL != null && !user.photoURL!.startsWith('data:')) return;

    try {
      // Try to fetch a small 48x48 image to ensure the Base64 string safely fits inside Firebase's photoURL field
      final response = await http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/photos/48x48/\$value'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode == 200) {
        final base64Data = base64Encode(response.bodyBytes);
        await user.updatePhotoURL(
          'data:${response.headers['content-type'] ?? 'image/jpeg'};base64,$base64Data',
        );
      } else {
        // Fallback to default photo endpoint if the user's account doesn't support explicit resizing
        final fallback = await http.get(
          Uri.parse('https://graph.microsoft.com/v1.0/me/photo/\$value'),
          headers: {'Authorization': 'Bearer $accessToken'},
        );
        if (fallback.statusCode == 200) {
          final base64Data = base64Encode(fallback.bodyBytes);
          await user.updatePhotoURL(
            'data:${fallback.headers['content-type'] ?? 'image/jpeg'};base64,$base64Data',
          );
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch Microsoft photo: $e');
    }
  }

  Future<void> _handleAccountLinking(
    AuthCredential? credential,
    String? email,
  ) async {
    if (credential == null || email == null || !mounted) return;

    final password = await _promptForPassword(email);
    if (password == null || password.isEmpty || !mounted) return;

    setState(() => _isLoading = true);
    try {
      // Sign in with email and password to verify user
      final userCredential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);

      // Link the new (social) credential
      await userCredential.user?.linkWithCredential(credential);

      if (mounted) {
        AppNotification.show(
          context,
          'Successfully linked account!',
          color: Colors.green,
        );
      }
    } on FirebaseAuthException catch (authError) {
      if (mounted) {
        AppNotification.show(
          context,
          'Failed to link: ${authError.message}',
          color: Colors.red,
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<String?> _promptForPassword(String email) {
    final passwordController = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1F24),
          title: const Text(
            'Link Account',
            style: TextStyle(color: Colors.white),
          ),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(
                  'An account already exists with $email. Please enter your password to link it.',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    labelStyle: TextStyle(color: Colors.white54),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: Color.fromARGB(255, 82, 82, 82),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white70),
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color.fromARGB(255, 97, 97, 97),
                foregroundColor: Colors.black,
              ),
              onPressed: () =>
                  Navigator.of(context).pop(passwordController.text.trim()),
              child: const Text('Link'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1014),
      body: Center(
        child: SizedBox(
          width: kIsWeb
              ? (MediaQuery.sizeOf(context).width * 0.25).clamp(320.0, 450.0)
              : null,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'LunarDrift',
                  style: TextStyle(
                    color: Color.fromARGB(255, 82, 82, 82),
                    fontWeight: FontWeight.w900,
                    fontSize: 36,
                    letterSpacing: -1.0,
                  ),
                ),
                const SizedBox(height: 48),
                TextField(
                  controller: _emailController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    labelStyle: TextStyle(color: Colors.white54),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: Color.fromARGB(255, 88, 88, 88),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    labelStyle: TextStyle(color: Colors.white54),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: Color.fromARGB(255, 76, 76, 76),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                if (_isLoading)
                  const CircularProgressIndicator(
                    color: Color.fromARGB(255, 255, 255, 255),
                  )
                else ...[
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color.fromARGB(255, 156, 156, 156),
                      foregroundColor: Colors.black,
                      minimumSize: const Size.fromHeight(50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    onPressed: () => _authenticate(false),
                    child: const Text(
                      'Sign In',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () => _authenticate(true),
                    child: const Text(
                      'Create Account',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Expanded(child: Divider(color: Colors.white24)),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'OR',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                      const Expanded(child: Divider(color: Colors.white24)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(50),
                      side: const BorderSide(color: Colors.white54),
                    ),
                    onPressed: _signInWithGoogle,
                    icon: Image.network(
                      'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/48px-Google_%22G%22_logo.svg.png',
                      height: 24,
                    ),
                    label: const Text(
                      'Sign in with Google',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (kIsWeb ||
                      (defaultTargetPlatform != TargetPlatform.windows &&
                          defaultTargetPlatform != TargetPlatform.linux)) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(50),
                        side: const BorderSide(color: Colors.white54),
                      ),
                      onPressed: _signInWithMicrosoft,
                      icon: Image.network(
                        'https://upload.wikimedia.org/wikipedia/commons/thumb/4/44/Microsoft_logo.svg/48px-Microsoft_logo.svg.png',
                        height: 24,
                      ),
                      label: const Text(
                        'Sign in with Microsoft',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const Map<String, String> _cachedImageHttpHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
};

class SearchBody extends StatelessWidget {
  final List<dynamic> results;
  final List<dynamic> recentSearches;
  final List<dynamic> watchHistory;
  final bool isLoading;
  final Function(dynamic) onResultTapped;
  final VoidCallback? onRefresh;
  final String searchQuery;

  const SearchBody({
    super.key,
    required this.results,
    required this.recentSearches,
    required this.watchHistory,
    required this.isLoading,
    required this.onResultTapped,
    this.onRefresh,
    required this.searchQuery,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: kToolbarHeight + MediaQuery.of(context).padding.top),
        Expanded(
          child: isLoading
              ? const Center(
                  child: CircularProgressIndicator(
                    color: Color.fromARGB(255, 255, 255, 255),
                  ),
                )
              : searchQuery.isEmpty
              ? _buildLandingContent(context)
              : results.isEmpty
              ? Center(
                  child: Text(
                    'No results found.',
                    style: const TextStyle(color: Colors.white54),
                  ),
                )
              : _buildSearchResultsGrid(),
        ),
      ],
    );
  }

  Widget _buildLandingContent(BuildContext context) {
    final bool isKeyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    if (isKeyboardVisible || (recentSearches.isEmpty && watchHistory.isEmpty)) {
      return const Center(
        child: Text(
          'Search for movies and TV shows.',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 120.0),
      children: [
        if (recentSearches.isNotEmpty)
          HorizontalMediaList(
            categoryTitle: 'Recently Viewed',
            items: recentSearches,
          ),
        if (recentSearches.isNotEmpty && watchHistory.isNotEmpty)
          const SizedBox(height: 24),
        if (watchHistory.isNotEmpty)
          HorizontalMediaList(
            categoryTitle: 'Watch History',
            items: watchHistory,
          ),
      ],
    );
  }

  Widget _buildSearchResultsGrid() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 120.0),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160.0,
        childAspectRatio: 2 / 3,
        crossAxisSpacing: 12.0,
        mainAxisSpacing: 12.0,
      ),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final media = results[index];
        final posterPath = media['poster_path'];
        final imageUrl = posterPath != null
            ? 'https://image.tmdb.org/t/p/w500$posterPath'
            : 'https://via.placeholder.com/500x750?text=No+Image';
        final heroTag = 'search_${media['media_type']}_${media['id']}_$index';
        return GestureDetector(
          onTap: () {
            onResultTapped(media);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    MediaDetailsPage(media: media, heroTag: heroTag),
              ),
            ).then((refresh) { if (refresh == true) onRefresh?.call(); });
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8.0),
            child: Hero(
              tag: heroTag,
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                httpHeaders: _cachedImageHttpHeaders,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(color: Colors.black26),
                errorWidget: (context, url, error) => Container(
                  color: Colors.black26,
                  child: const Icon(Icons.broken_image, color: Colors.white54),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
enum PlayerMenu { none, subtitles, quality }
class LocalVideoPlayerPage extends StatefulWidget {
  final File videoFile; 
  final String title;
  const LocalVideoPlayerPage({
    super.key,
    required this.videoFile,
    required this.title,
  });

  @override
  State<LocalVideoPlayerPage> createState() => _LocalVideoPlayerPageState();
}

class _LocalVideoPlayerPageState extends State<LocalVideoPlayerPage> with TickerProviderStateMixin {
  late final Player _player = Player();
  late final VideoController _videoController = VideoController(_player);
  bool _isInitialized = false;
  late AnimationController _loadingProgressController;
  bool _isControlsVisible = true;
  Timer? _controlsTimer;
  PlayerMenu _activeMenu = PlayerMenu.none;
  String? _initializationError;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _bufferSubscription;
  StreamSubscription? _trackSubscription;
  Duration _buffer = Duration.zero;
  bool _isHoveringSeekBar = false;
  bool _isHoveringVolume = false;
  double _volume = 1.0;

  @override
  void initState() {
    super.initState();
    _loadingProgressController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..animateTo(0.9, curve: Curves.easeOut);

    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initializePlayer();

    _positionSubscription = _player.stream.position.listen((_) {
      if (mounted) setState(() {});
    });
    _bufferSubscription = _player.stream.buffer.listen((b) {
      if (mounted) setState(() => _buffer = b);
    });
    _player.stream.volume.listen((v) {
      if (mounted) setState(() => _volume = v / 100.0);
    });
    _trackSubscription = _player.stream.tracks.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _initializePlayer() async {
    debugPrint("[FVP_PLAYER_DEBUG] _initializePlayer: Starting.");
    debugPrint("[FVP_PLAYER_DEBUG] Video file path: ${widget.videoFile.path}");
    final bool fileExists = await widget.videoFile.exists();
    debugPrint("[FVP_PLAYER_DEBUG] File exists: $fileExists");

    if (!fileExists) {
      if (mounted) {
        setState(
          () =>
              _initializationError = "File not found: ${widget.videoFile.path}",
        );
      }
      return;
    }

    try {
      debugPrint("[PLAYER_DEBUG] Opening local file with MediaKit...");
      await _player.open(Media(widget.videoFile.path));

      if (mounted) {
        _loadingProgressController.animateTo(1.0, duration: const Duration(milliseconds: 400)).then((_) {
          if (mounted) {
            setState(() => _isInitialized = true);
          }
        });
        _player.play();
        _resetControlsTimer();
      }
      debugPrint("[PLAYER_DEBUG] _initializePlayer: Finished.");
    } catch (e, s) {
      debugPrint("[PLAYER_DEBUG] ERROR: $e\n$s");
      if (mounted) setState(() => _initializationError = "Failed to create player: $e");
    }
  }

  void _resetControlsTimer() {
    _controlsTimer?.cancel();
    if (mounted) {
      setState(() => _isControlsVisible = true);
      if (!_isControlsVisible) _activeMenu = PlayerMenu.none;
      _controlsTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _isControlsVisible = false;
            _activeMenu = PlayerMenu.none;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    debugPrint("[FVP_PLAYER_DEBUG] dispose: Starting.");
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _controlsTimer?.cancel();
    _positionSubscription?.cancel();
    _bufferSubscription?.cancel();
    _trackSubscription?.cancel();
    _player.dispose();
    _loadingProgressController.dispose();
    if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.macOS)) {
      windowManager.setFullScreen(false);
    }
    debugPrint("[PLAYER_DEBUG] dispose: Finished.");
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return "${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}";
    } else {
      return "${twoDigits(minutes)}:${twoDigits(seconds)}";
    }
  }

  Widget _buildProgressBar() {
    final position = _player.state.position;
    final duration = _player.state.duration;
    double sliderValue = 0.0;
    if (duration.inMilliseconds > 0) {
      sliderValue = position.inMilliseconds / duration.inMilliseconds;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MouseRegion(
            onEnter: (_) => setState(() => _isHoveringSeekBar = true),
            onExit: (_) => setState(() => _isHoveringSeekBar = false),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (details) {
                    final box = context.findRenderObject() as RenderBox;
                    final dx = details.localPosition.dx;
                    final pct = (dx / box.size.width).clamp(0.0, 1.0);
                    _player.seek(duration * pct);
                    _resetControlsTimer();
                  },
                  onTapDown: (details) {
                    final box = context.findRenderObject() as RenderBox;
                    final dx = details.localPosition.dx;
                    final pct = (dx / box.size.width).clamp(0.0, 1.0);
                    _player.seek(duration * pct);
                    _resetControlsTimer();
                  },
                  child: Container(
                    height: 20, // Hit target
                    alignment: Alignment.center,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Background
                        Container(
                          height: _isHoveringSeekBar ? 6 : 4,
                          width: double.infinity,
                          color: Colors.white10,
                        ),
                        // Buffer Bar
                        FractionallySizedBox(
                          widthFactor: duration.inMilliseconds > 0 
                              ? (_buffer.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0) 
                              : 0.0,
                          child: Container(
                            height: _isHoveringSeekBar ? 6 : 4,
                            color: Colors.white24,
                          ),
                        ),
                        // Progress Bar
                        FractionallySizedBox(
                          widthFactor: sliderValue.clamp(0.0, 1.0),
                          child: Container(
                            height: _isHoveringSeekBar ? 6 : 4,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(position),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                Text(
                  _formatDuration(duration),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_initializationError != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          leading: BackButton(onPressed: () => Navigator.of(context).pop()),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Text(
              "Player Error:\n\n$_initializationError",
              style: const TextStyle(color: Colors.red, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (!_isInitialized && _initializationError == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            const Center(child: CircularProgressIndicator(color: Colors.white24, strokeWidth: 2)),
            Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(
                child: AnimatedBuilder(
                  animation: _loadingProgressController,
                  builder: (context, child) => LinearProgressIndicator(
                    value: _loadingProgressController.value,
                    backgroundColor: Colors.white10,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF1CE783)),
                    minHeight: 2,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () {
          if (_activeMenu != PlayerMenu.none) setState(() => _activeMenu = PlayerMenu.none);
          _resetControlsTimer();
        },
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: <Widget>[
            Center(
              child: Video(
                controller: _videoController,
                controls: NoVideoControls,
                fill: Colors.black,
              ),
            ),
            AnimatedOpacity(
              opacity: _isControlsVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: Container(
                color: Colors.black26,
                child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const Spacer(),
                  SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildProgressBar(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Row(
                            children: [
                              // Left side controls
                              IconButton(
                                icon: Icon(_player.state.playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
                                onPressed: () { _player.playOrPause(); _resetControlsTimer(); },
                              ),
                              IconButton(
                                icon: const Icon(Icons.replay_10, color: Colors.white),
                                onPressed: () { _player.seek(_player.state.position - const Duration(seconds: 10)); _resetControlsTimer(); },
                              ),
                              IconButton(
                                icon: const Icon(Icons.forward_10, color: Colors.white),
                                onPressed: () { _player.seek(_player.state.position + const Duration(seconds: 10)); _resetControlsTimer(); },
                              ),
                              const SizedBox(width: 8),
                              MouseRegion(
                                onEnter: (_) => setState(() => _isHoveringVolume = true),
                                onExit: (_) => setState(() => _isHoveringVolume = false),
                                child: Row(
                                  children: [
                                    IconButton(
                                      icon: Icon(_volume == 0 ? Icons.volume_off : Icons.volume_up, color: Colors.white),
                                      onPressed: () { _player.setVolume(_volume == 0 ? 100 : 0); _resetControlsTimer(); },
                                    ),
                                    AnimatedContainer(
                                      duration: const Duration(milliseconds: 200),
                                      width: _isHoveringVolume ? 60 : 0,
                                      child: _isHoveringVolume 
                                        ? SliderTheme(
                                            data: SliderTheme.of(context).copyWith(
                                              trackHeight: 2,
                                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                                              overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                                            ),
                                            child: Slider(
                                              value: _volume,
                                              activeColor: Colors.white,
                                              inactiveColor: Colors.white24,
                                              onChanged: (v) {
                                                _player.setVolume(v * 100);
                                                _resetControlsTimer();
                                              },
                                            ),
                                          )
                                        : const SizedBox.shrink(),
                                    ),
                                  ],
                                ),
                              ),
                              const Spacer(),
                              // Right side controls
                              if (_player.state.tracks.subtitle.length > 1)
                                IconButton(
                                  icon: const Icon(Icons.subtitles, color: Colors.white),
                                  onPressed: () => _toggleMenu(PlayerMenu.subtitles),
                                ),
                              IconButton(
                                icon: const Icon(Icons.fullscreen, color: Colors.white),
                                onPressed: () async {
                                  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.macOS)) {
                                    bool isFull = await windowManager.isFullScreen();
                                    await windowManager.setFullScreen(!isFull);
                                  } else if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
                                    bool isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
                                    SystemChrome.setPreferredOrientations(isPortrait ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : [DeviceOrientation.portraitUp]);
                                    SystemChrome.setEnabledSystemUIMode(isPortrait ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
                                  }
                                  _resetControlsTimer();
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              opacity: _isControlsVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: SafeArea(
                bottom: false,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
                        onPressed: () => Navigator.of(context).pop(true),
                        
                      ),
                     const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  
                ),
              ),
            ),
            )
          ),
           if (_isControlsVisible)
            _buildSubtitlesMenuLocal(),
        ],
      ),
    ));
  }

void _toggleMenu(PlayerMenu menu) {
    _resetControlsTimer();
    setState(() {
      _activeMenu = _activeMenu == menu ? PlayerMenu.none : menu;
    });
  }

  Widget _buildSubtitlesMenuLocal() {
    final subs = _player.state.tracks.subtitle;
    final double height = (subs.length * 48.0 + 16.0).clamp(0.0, 300.0);
    
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      bottom: _activeMenu == PlayerMenu.subtitles ? 80 : 40,
      right: 64,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: _activeMenu == PlayerMenu.subtitles ? 1.0 : 0.0,
        child: IgnorePointer(
          ignoring: _activeMenu != PlayerMenu.subtitles,
          child: Container(
            width: 220,
            height: height,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1F24),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
              boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
            ),
            child: Material(
              color: Colors.transparent,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: subs.length,
                itemBuilder: (context, i) {
                  final t = subs[i];
                  final label = (t.language ?? t.title ?? t.id).split(' - ').first;
                  final display = label.isEmpty ? 'Unknown' : label[0].toUpperCase() + label.substring(1).toLowerCase();
                  final isSelected = _player.state.track.subtitle == t;
                  
                  return ListTile(
                    dense: true,
                    title: Text(display, style: TextStyle(color: isSelected ? const Color(0xFF1CE783) : Colors.white, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                    trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF1CE783), size: 16) : null,
                    onTap: () {
                      _player.setSubtitleTrack(t);
                      _toggleMenu(PlayerMenu.none);
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
class DownloadedItemWidget extends StatelessWidget {
  final CachedDownloadItem item;
  const DownloadedItemWidget({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final posterPath = item.posterPath;
    final imageUrl = posterPath != null
        ? 'https://image.tmdb.org/t/p/w500$posterPath'
        : 'https://via.placeholder.com/500x750?text=No+Image';
    final heroTag = 'downloaded_${item.mediaId}';

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                DownloadedMediaDetailsPage(item: item, heroTag: heroTag),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: Hero(
          tag: heroTag,
          child: CachedNetworkImage(
            imageUrl: imageUrl,
            httpHeaders: _cachedImageHttpHeaders,
            fit: BoxFit.cover,
            placeholder: (context, url) => Container(color: Colors.black26),
            errorWidget: (context, url, error) => Container(
              color: Colors.black26,
              child: const Icon(Icons.broken_image, color: Colors.white54),
            ),
          ),
        ),
      ),
    );
  }
}

class InProgressDownloadItemWidget extends StatefulWidget {
  final DownloadTask task;
  const InProgressDownloadItemWidget({super.key, required this.task});

  @override
  State<InProgressDownloadItemWidget> createState() =>
      _InProgressDownloadItemWidgetState();
}

class _InProgressDownloadItemWidgetState
    extends State<InProgressDownloadItemWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _spinnerController;

  @override
  void initState() {
    super.initState();
    _spinnerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    widget.task.addListener(_onTaskUpdate);
  }

  @override
  void dispose() {
    widget.task.removeListener(_onTaskUpdate);
    _spinnerController.dispose();
    super.dispose();
  }

  void _onTaskUpdate() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final posterPath = widget.task.posterPath;
    final imageUrl = posterPath != null
        ? 'https://image.tmdb.org/t/p/w500$posterPath'
        : 'https://via.placeholder.com/500x750?text=No+Image';

    final status = widget.task.status;
    final progress = widget.task.progress;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8.0),
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: imageUrl,
            fit: BoxFit.cover,
            placeholder: (context, url) => Container(color: Colors.black26),
            errorWidget: (context, url, error) => Container(
              color: Colors.black26,
              child: const Icon(Icons.broken_image, color: Colors.white54),
            ),
          ),
          Container(
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.6)),
          ),
          Center(
            child: SizedBox(
              width: 64,
              height: 64,
              child: CustomPaint(
                painter: DownloadProgressPainter(
                  status: status,
                  progress: progress,
                  rotationAnimation: _spinnerController,
                ),
                child: Center(
                  child: status == DownloadStatus.downloading
                      ? Text(
                          '${(progress * 100).floor()}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FullListPage extends StatefulWidget {
  final String title;
  final List<dynamic> items;
  final String? apiUrl;
  final String? defaultMediaType;

  const FullListPage({
    super.key,
    required this.title,
    required this.items,
    this.apiUrl,
    this.defaultMediaType,
  });

  @override
  State<FullListPage> createState() => _FullListPageState();
}

class _FullListPageState extends State<FullListPage> {
  late List<dynamic> _currentItems = [];
  int _currentPage = 1;
  bool _isFetching = false;
  bool _hasMore = true;
  bool _hasMadeChanges = false;
  final ScrollController _scrollController = ScrollController();
  final Set<String> _seenIds = {};

  @override
  void initState() {
    super.initState();
    if (widget.apiUrl != null) {
      _fetchPage(1);
      _scrollController.addListener(() {
        if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 600) {
          _loadMore();
        }
      });
    } else {
      _currentItems = List.from(widget.items);
      _hasMore = false;
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchPage(int page) async {
    if (_isFetching || widget.apiUrl == null) return;
    setState(() => _isFetching = true);

    try {
      final separator = widget.apiUrl!.contains('?') ? '&' : '?';
      final url = '${widget.apiUrl}${separator}page=$page';
      final data = await fetchWithCache(url);

      if (mounted) {
        final List results = data['results'] as List? ?? [];
        final List filtered = [];

        for (var item in results) {
          final id = item['id']?.toString();
          if (id != null && !_seenIds.contains(id) && _isReleased(item)) {
            _seenIds.add(id);
            if (item['media_type'] == null && widget.defaultMediaType != null) {
              item['media_type'] = widget.defaultMediaType;
            }
            filtered.add(item);
          }
        }

        setState(() {
          _currentItems.addAll(filtered);
          _currentPage = page;
          _isFetching = false;
          if (results.isEmpty || page >= (data['total_pages'] ?? 1)) {
            _hasMore = false;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isFetching = false);
    }
  }

  void _loadMore() {
    if (!_isFetching && _hasMore) {
      _fetchPage(_currentPage + 1);
    }
  }

  void _handleDeleteItem(dynamic item) async {
    _hasMadeChanges = true;
    if (widget.title == 'Downloads') {
      if (item is CachedDownloadItem) {
        final file = File(item.filePath);
        if (await file.exists()) {
          await file.delete();
        }
        await DownloadManager().removeDownloadFromCache(item.mediaId);
      }
    } else if (widget.title == 'Watchlist') {
      if (item is Map<String, dynamic>) {
        await WatchlistManager.removeFromWatchlist(item['id']);
      }
    } else if (widget.title == 'Continue Watching' ||
        widget.title == 'Watch History') {
      if (item is Map<String, dynamic>) {
        final mediaId = item['id'];
        final mediaType = item['media_type'];
        await ProgressManager.deleteProgress(
          mediaId,
          mediaType,
          season: item['season'],
          episode: item['episode'],
        );
      }
    }

    if (mounted) {
      setState(() {
        _currentItems.remove(item);
      });
      AppNotification.show(context, 'Item removed.', color: Colors.green);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        leading: BackButton(onPressed: () => Navigator.pop(context, _hasMadeChanges)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: _currentItems.isEmpty
          ? const Center(
              child: Text(
                'No items in this list.',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
            )
          : (widget.title == 'Continue Watching' ||
                widget.title == 'Watch History' ||
                widget.title == 'Watchlist' ||
                widget.title == 'Downloads')
          ? ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.only(top: 16.0, bottom: 120.0),
              itemCount: _currentItems.length,
              itemBuilder: (context, index) {
                final item = _currentItems[index];
                return FullListItem(
                  itemData: item,
                  listType: widget.title,
                  onDelete: () => _handleDeleteItem(item),
                );
              },
            )
          : GridView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 120.0),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                childAspectRatio: 2 / 3,
                crossAxisSpacing: 12.0,
                mainAxisSpacing: 12.0,
              ),
              itemCount: _currentItems.length + (_isFetching ? 3 : 0),
              itemBuilder: (context, index) {
                if (index >= _currentItems.length) {
                  return Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  );
                }
                final item = _currentItems[index];
                return GridMediaItem(
                  itemData: item,
                  listType: widget.title,
                  index: index,
                  onDelete: () => _handleDeleteItem(item),
                );
              },
            ),
    );
  }
}

class GridMediaItem extends StatefulWidget {
  final dynamic itemData;
  final String listType;
  final int index;
  final VoidCallback onDelete;

  const GridMediaItem({
    super.key,
    required this.itemData,
    required this.listType,
    required this.index,
    required this.onDelete,
  });

  @override
  State<GridMediaItem> createState() => _GridMediaItemState();
}

class _GridMediaItemState extends State<GridMediaItem> {
  String? _posterPath;

  @override
  void initState() {
    super.initState();
    if (widget.itemData is Map<String, dynamic>) {
      _posterPath = widget.itemData['poster_path'];
      if (_posterPath == null) _fetchPoster();
    }
  }

  Future<void> _fetchPoster() async {
    final id = widget.itemData['id'];
    final type = widget.itemData['media_type'] ?? (widget.itemData['first_air_date'] != null ? 'tv' : 'movie');
    if (id == null) return;
    try {
      final url = 'https://api.themoviedb.org/3/$type/$id?api_key=$tmdbApiKey';
      final data = await fetchWithCache(url);
      if (mounted) setState(() => _posterPath = data['poster_path']);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemData is DownloadTask) {
      return InProgressDownloadItemWidget(task: widget.itemData as DownloadTask);
    }

    final String? posterPath;
    final String mediaId;

    if (widget.itemData is CachedDownloadItem) {
      final item = widget.itemData as CachedDownloadItem;
      posterPath = item.posterPath;
      mediaId = item.mediaId;
    } else if (widget.itemData is Map<String, dynamic>) {
      final item = widget.itemData as Map<String, dynamic>;
      posterPath = _posterPath ?? item['poster_path'];
      mediaId = item['id'].toString();
    } else {
      return const SizedBox.shrink();
    }

    final imageUrl = posterPath != null
        ? 'https://image.tmdb.org/t/p/w500$posterPath'
        : 'https://via.placeholder.com/500x750?text=No+Image';

    final heroTag = 'grid_list_${widget.listType}_${mediaId}_${widget.index}';

    return GestureDetector(
      onTap: () {
        if (widget.itemData is CachedDownloadItem) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => DownloadedMediaDetailsPage(
                item: widget.itemData as CachedDownloadItem,
                heroTag: heroTag,
              ),
            ),
          );
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => MediaDetailsPage(
                media: widget.itemData as Map<String, dynamic>,
                heroTag: heroTag,
              ),
            ),
          );
        }
      },
      onLongPress:
          (widget.listType == 'Downloads' ||
              widget.listType == 'Watchlist' ||
              widget.listType == 'Continue Watching')
          ? () async {
              final bool? confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: const Color(0xFF1E1F24),
                  title: const Text(
                    'Remove Item',
                    style: TextStyle(color: Colors.white),
                  ),
                  content: Text(
                    'Are you sure you want to remove this from your ${widget.listType.toLowerCase()}?',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                widget.onDelete();
              }
            }
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: Hero(
          tag: heroTag,
          child: CachedNetworkImage(
            httpHeaders: _cachedImageHttpHeaders,
            imageUrl: imageUrl,
            fit: BoxFit.cover,
            placeholder: (context, url) => Container(color: Colors.black26),
            errorWidget: (context, url, error) => Container(
              color: Colors.black26,
              child: const Icon(Icons.movie, color: Colors.white24),
            ),
          ),
        ),
      ),
    );
  }
}

class FullListItem extends StatefulWidget {
  final dynamic itemData;
  final String listType;
  final VoidCallback onDelete;

  const FullListItem({
    super.key,
    required this.itemData,
    required this.listType,
    required this.onDelete,
  });

  @override
  State<FullListItem> createState() => _FullListItemState();
}

class _FullListItemState extends State<FullListItem> {
  Map<String, dynamic>? _mediaDetails;
  bool _isLoading = true;
  String _fileSize = '';

  @override
  void initState() {
    super.initState();
    _fetchMediaDetails();
    _calculateFileSize();
  }

  Future<void> _calculateFileSize() async {
    if (widget.listType == 'Downloads' &&
        widget.itemData is CachedDownloadItem) {
      final item = widget.itemData as CachedDownloadItem;
      try {
        final file = File(item.filePath);
        if (await file.exists()) {
          final bytes = await file.length();
          if (mounted) {
            setState(() {
              _fileSize = _formatBytes(bytes);
            });
          }
        }
      } catch (e) {
        debugPrint('Could not calculate file size for ${item.filePath}: $e');
      }
    }
  }

  String _formatBytes(int bytes, [int decimals = 1]) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = (log(bytes) / log(1024)).floor();
    if (i == 0) decimals = 0;
    return '${(bytes / pow(1024, i)).toStringAsFixed(decimals)} ${suffixes[i]}';
  }

  Future<void> _fetchMediaDetails() async {
    if (widget.itemData is DownloadTask) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    final String mediaId;
    String? mediaType;

    if (widget.itemData is CachedDownloadItem) {
      mediaId = (widget.itemData as CachedDownloadItem).mediaId;
      mediaType = (widget.itemData as CachedDownloadItem).mediaType;
    } else if (widget.itemData is Map<String, dynamic>) {
      mediaId = (widget.itemData as Map<String, dynamic>)['id'].toString();
      mediaType = (widget.itemData as Map<String, dynamic>)['media_type'];
    } else {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    // Try fetching as a movie first
    if (mediaType == 'movie' || mediaType == null) {
      try {
        final url =
            'https://api.themoviedb.org/3/movie/$mediaId?api_key=$tmdbApiKey';
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200 && mounted) {
          setState(() {
            _mediaDetails = json.decode(response.body);
            _mediaDetails?['media_type'] = 'movie';
            _isLoading = false;
          });
          return;
        }
      } catch (e) {
        /* Ignore and try TV */
      }
    }

    // If movie fails or type is TV, try fetching as a TV show
    if (mediaType == 'tv' || mediaType == null) {
      try {
        final url =
            'https://api.themoviedb.org/3/tv/$mediaId?api_key=$tmdbApiKey';
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200 && mounted) {
          setState(() {
            _mediaDetails = json.decode(response.body);
            _mediaDetails?['media_type'] = 'tv';
            _isLoading = false;
          });
          return;
        }
      } catch (e) {
        /* Ignore, will show placeholder */
      }
    }

    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemData is DownloadTask) {
      final task = widget.itemData as DownloadTask;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: SizedBox(
          height: 100,
          child: InProgressDownloadItemWidget(task: task),
        ),
      );
    }

    final String? posterPath;
    final String title;
    final String mediaId;

    if (widget.itemData is CachedDownloadItem) {
      final item = widget.itemData as CachedDownloadItem;
      posterPath = item.posterPath;
      title = item.title;
      mediaId = item.mediaId;
    } else if (widget.itemData is Map<String, dynamic>) {
      final item = widget.itemData as Map<String, dynamic>;
      posterPath = _mediaDetails?['poster_path'] ?? item['poster_path'];
      title = _mediaDetails?['title'] ?? _mediaDetails?['name'] ?? item['title'] ?? item['name'] ?? 'Loading...';
      mediaId = item['id'].toString();
    } else {
      return const SizedBox.shrink();
    }

    final imageUrl = posterPath != null
        ? 'https://image.tmdb.org/t/p/w500$posterPath'
        : 'https://via.placeholder.com/500x750?text=No+Image';

    String runtimeStr = '';
    if (_mediaDetails != null) {
      final runtimeRaw =
          _mediaDetails!['runtime'] ??
          (_mediaDetails!['episode_run_time'] is List &&
                  (_mediaDetails!['episode_run_time'] as List).isNotEmpty
              ? (_mediaDetails!['episode_run_time'] as List)[0]
              : null);
      if (runtimeRaw is num && runtimeRaw > 0) {
        final int hrs = runtimeRaw.toInt() ~/ 60;
        final int mins = runtimeRaw.toInt() % 60;
        runtimeStr = hrs > 0 ? '${hrs}h ${mins}m' : '${mins}m';
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: GestureDetector(
        onTap: () {
          if (widget.itemData is CachedDownloadItem) {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => DownloadedMediaDetailsPage(
                  item: widget.itemData,
                  heroTag: 'list_item_$mediaId',
                ),
              ),
            );
          } else {
            final Map<String, dynamic> mediaData = widget.itemData;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => MediaDetailsPage(
                  media: mediaData,
                  heroTag: 'list_item_$mediaId',
                ),
              ),
            );
          }
        },
        child: SizedBox(
          height: 100,
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4.0),
                child: AspectRatio(
                  aspectRatio: 2 / 3,
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    httpHeaders: _cachedImageHttpHeaders,
                    fit: BoxFit.cover,
                    placeholder: (context, url) =>
                        Container(color: Colors.black26),
                    errorWidget: (context, url, error) => Container(
                      color: Colors.black26,
                      child: const Icon(Icons.movie, color: Colors.white24),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (_isLoading)
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white54,
                            ),
                          )
                        else if (runtimeStr.isNotEmpty)
                          Text(
                            runtimeStr,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),

                        if (widget.listType == 'Downloads' &&
                            runtimeStr.isNotEmpty)
                          const Text(
                            ' • ',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),

                        if (widget.listType == 'Downloads')
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white38),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'HD',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  if (_fileSize.isNotEmpty)
                    Text(
                      _fileSize,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  if (widget.listType == 'Downloads' ||
                      widget.listType == 'Watchlist' ||
                      widget.listType == 'Continue Watching' ||
                      widget.listType == 'Watch History')
                    IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.white54,
                      ),
                      onPressed: () async {
                        final bool? confirm = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            backgroundColor: const Color(0xFF1E1F24),
                            title: const Text(
                              'Remove Item',
                              style: TextStyle(color: Colors.white),
                            ),
                            content: Text(
                              'Are you sure you want to remove this from your ${widget.listType.toLowerCase()}?',
                              style: const TextStyle(color: Colors.white70),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text(
                                  'Cancel',
                                  style: TextStyle(color: Colors.white70),
                                ),
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: const Text('Remove'),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          widget.onDelete();
                        }
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MyStuffSheet extends StatefulWidget {
  const MyStuffSheet({super.key});

  @override
  State<MyStuffSheet> createState() => _MyStuffSheetState();
}

class _MyStuffSheetState extends State<MyStuffSheet> {
  List<dynamic> _downloads = [];
  List<dynamic> _watchlistItems = [];
  bool _isLoadingDownloads = true;
  StreamSubscription? _downloadMessageSubscription;
  // ignore: unused_field
  bool _hasMadeChanges = false;
  @override
  void initState() {
    super.initState();
    _loadCachedDownloads();
    _syncAndRefreshDownloads();
    _fetchWatchlist();
    _downloadMessageSubscription = DownloadManager().messages.listen(
      _onDownloadMessage,
    );
  }

  @override
  void dispose() {
    _downloadMessageSubscription?.cancel();
    // When MyStuffSheet is dismissed, return the _hasMadeChanges flag
    // This is handled by the Navigator.pop in the build method,
    // but if the sheet is dismissed by dragging, we need to ensure
    // the flag is returned. This is implicitly handled by the DraggableScrollableSheet
    // returning its last state when it's popped.
    // For explicit pop, we'll modify the settings button.
    super.dispose();
  }

  void _onDownloadMessage(String message) {
    if (message.startsWith('SUCCESS:') && mounted) {
      // A download finished, the cache was updated. We can just reload from cache.
      _loadCachedDownloads();
    } else if (message.startsWith('ERROR:') && mounted) {
      // A download failed, refresh to remove it from in-progress list.
      _loadCachedDownloads();
    }
  }

  Future<void> _loadCachedDownloads() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedStrings = prefs.getStringList('downloadedItemsCache') ?? [];
    final cachedItems = cachedStrings
        .map((s) {
          try {
            return CachedDownloadItem.fromJson(json.decode(s));
          } catch (e) {
            return null;
          }
        })
        .whereType<CachedDownloadItem>()
        .toList();

    cachedItems.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));

    final allTasks = DownloadManager().allTasks;
    final inProgressTasks = allTasks
        .where(
          (task) =>
              task.status == DownloadStatus.requesting ||
              task.status == DownloadStatus.downloading,
        )
        .toList();

    if (mounted) {
      setState(() {
        _downloads = [...inProgressTasks, ...cachedItems];
        _isLoadingDownloads = false;
      });
    }
  }

  Future<void> _syncAndRefreshDownloads() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedStrings = prefs.getStringList('downloadedItemsCache') ?? [];
      final cachedItems = cachedStrings
          .map((s) {
            try {
              return CachedDownloadItem.fromJson(json.decode(s));
            } catch (e) {
              return null;
            }
          })
          .whereType<CachedDownloadItem>()
          .toList();

      final docsDir = await getApplicationDocumentsDirectory();
      final cineStreamDir = Directory('${docsDir.path}/LunarDrift/Movies');

      List<File> onDiskFiles = [];
      if (await cineStreamDir.exists()) {
        onDiskFiles = await cineStreamDir
            .list()
            .where((item) => item is File && item.path.endsWith('.mp4'))
            .map((item) => item as File)
            .toList();
      }

      bool cacheWasModified = false;

      // 1. Remove items from cache that are no longer on disk
      final onDiskPaths = onDiskFiles.map((f) => f.path).toSet();
      final initialCount = cachedItems.length;
      cachedItems.removeWhere((item) => !onDiskPaths.contains(item.filePath));
      if (cachedItems.length < initialCount) cacheWasModified = true;

      // 2. Add items to cache that are on disk but not in cache
      final cachedPaths = cachedItems.map((item) => item.filePath).toSet();
      List<File> newFiles = onDiskFiles
          .where((file) => !cachedPaths.contains(file.path))
          .toList();

      if (newFiles.isNotEmpty) {
        cacheWasModified = true;
        for (final file in newFiles) {
          final filename = file.path.split('/').last;
          final parts = filename.split('+');
          if (parts.isEmpty) continue;
          final mediaId = parts.first;

          final mediaDetails = await _fetchMediaDetailsForSync(mediaId);
          if (mediaDetails != null) {
            cachedItems.add(
              CachedDownloadItem(
                mediaId: mediaId,
                title:
                    mediaDetails['title'] ?? mediaDetails['name'] ?? 'Unknown',
                posterPath: mediaDetails['poster_path'],
                mediaType: mediaDetails['media_type'],
                filePath: file.path,
                downloadedAt: await file.lastModified(),
              ),
            );
          }
        }
      }

      if (cacheWasModified) {
        final updatedCachedStrings = cachedItems
            .map((item) => json.encode(item.toJson()))
            .toList();
        await prefs.setStringList('downloadedItemsCache', updatedCachedStrings);
        await _loadCachedDownloads();
      }
    } catch (e) {
      debugPrint("Error syncing downloads: $e");
    }
  }

  Future<Map<String, dynamic>?> _fetchMediaDetailsForSync(
    String mediaId,
  ) async {
    try {
      final movieUrl =
          'https://api.themoviedb.org/3/movie/$mediaId?api_key=$tmdbApiKey';
      var response = await http.get(Uri.parse(movieUrl));
      if (response.statusCode == 200) {
        final details = json.decode(response.body) as Map<String, dynamic>;
        details['media_type'] = 'movie';
        return details;
      }
    } catch (_) {}

    try {
      final tvUrl =
          'https://api.themoviedb.org/3/tv/$mediaId?api_key=$tmdbApiKey';
      var response = await http.get(Uri.parse(tvUrl));
      if (response.statusCode == 200) {
        final details = json.decode(response.body) as Map<String, dynamic>;
        details['media_type'] = 'tv';
        return details;
      }
    } catch (_) {}

    return null;
  }

  Future<void> _fetchWatchlist() async {
    try {
      final watchlist = await WatchlistManager.getWatchlist();
      if (mounted) {
        setState(() {
          _watchlistItems = watchlist;
        });
      }
    } catch (e) {
      debugPrint('Error fetching watchlist from cache: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final screenHeight = MediaQuery.of(context).size.height;
    // Calculate max size to stop just below the AppBar, leaving it visible.
    final maxChildSize =
        (screenHeight - topPadding - kToolbarHeight - 10) / screenHeight;

    final downloads = _downloads
        .where((e) => e is DownloadTask || e is CachedDownloadItem)
        .toList();

    return DraggableScrollableSheet(
      initialChildSize: maxChildSize, // Start nearly full screen
      minChildSize: 0.5,
      maxChildSize: maxChildSize,
      builder: (BuildContext context, ScrollController scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1E1F24),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 10, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text(
                      'My Stuff',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24, // Consistent with other titles
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings, color: Colors.white70),
                      onPressed: () async {
                        final bool? settingsChanged =
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => const SettingsPage(),
                              ),
                            );
                        if (settingsChanged == true) {
                          setState(() => _hasMadeChanges = true);
                          _fetchWatchlist(); // Refresh watchlist if settings changed (e.g., cleared history)
                          _loadCachedDownloads(); // Refresh downloads if settings changed
                        }
                      },
                    ),
                  ],
                ),
              ),
              // Content
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    _buildSectionHeader(context, 'Downloads', () {
                      // Downloads FullListPage doesn't currently return a value,
                      // but if it did, we'd handle it here.
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => FullListPage(
                            title: 'Downloads',
                            items: downloads,
                          ),
                        ),
                      );
                    }),
                    _buildHorizontalDownloadsList(downloads),
                    const SizedBox(height: 24), // Spacing between sections
                    _buildSectionHeader(context, 'Watchlist', () {
                      // Await result from FullListPage for Watchlist
                      Navigator.push<bool?>(
                        // Specify return type
                        context,
                        MaterialPageRoute(
                          builder: (context) => FullListPage(
                            title: 'Watchlist',
                            items: _watchlistItems,
                          ),
                        ),
                      ).then((changed){
                        if(changed == true){
                          _fetchWatchlist(); // Refresh watchlist after returning
                        }
                      });
                    }),
                    _buildHorizontalWatchlist(_watchlistItems),
                    const SizedBox(
                      height: 40,
                    ), // Internal padding for the sheet content
                    // Add a button or gesture detector to explicitly pop the sheet
                    // and return the _hasMadeChanges flag if needed, though
                    // DraggableScrollableSheet handles dismissal implicitly.
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    VoidCallback onViewAll,
  ) {
    return GestureDetector(
      onTap: onViewAll,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white70),
          ],
        ),
      ),
    );
  }

  Widget _buildHorizontalDownloadsList(List<dynamic> items) {
    if (_isLoadingDownloads && items.isEmpty) {
      return const SizedBox(
        height: 200,
        child: Center(
          child: CircularProgressIndicator(
            color: Color.fromARGB(255, 255, 255, 255),
          ),
        ),
      );
    }
    if (items.isEmpty) {
      return const SizedBox(
        height: 100,
        child: Center(
          child: Text(
            'No downloads yet.',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }
    return SizedBox(
      height: 200,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12.0),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: SizedBox(
              width: 135,
              child: item is DownloadTask
                  ? InProgressDownloadItemWidget(task: item)
                  : (item is CachedDownloadItem
                        ? DownloadedItemWidget(item: item)
                        : const SizedBox.shrink()),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHorizontalWatchlist(List<dynamic> items) {
    if (items.isEmpty && !_isLoadingDownloads) {
      return const SizedBox(
        height: 100,
        child: Center(
          child: Text(
            'Your watchlist is empty.',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }
    if (items.isEmpty && _isLoadingDownloads) {
      return const SizedBox(
        height: 180,
        child: Center(
          child: CircularProgressIndicator(
            color: Color.fromARGB(255, 255, 255, 255),
          ),
        ),
      );
    }
    return HorizontalMediaList(
      categoryTitle: '',
      showTitle: false,
      items: items,
      listPadding: const EdgeInsets.symmetric(horizontal: 12.0),
    );
  }
}

class TMDBHomePage extends StatefulWidget {
  const TMDBHomePage({super.key, required this.title});
  final String title;

  @override
  State<TMDBHomePage> createState() => _TMDBHomePageState();
}

class _TMDBHomePageState extends State<TMDBHomePage>
    with TickerProviderStateMixin {
  List<dynamic> mediaList = [];
  bool isLoading = true;
  String _liveTvMode = 'live';
  int _selectedIndex = 0;
  int _lastSelectedIndex = 0;
  bool _isMuted = true;
  // ignore: unused_field
  bool _isSearchActive = false;

  // Data for the main page sections
  List<dynamic> _continueWatching = [];
  List<dynamic> _globalTrending = [];
  List<dynamic> _latestMovieRecs = [];
  String _latestMovieTitle = '';
  List<dynamic> _latestTvRecs = [];
  String _latestTvTitle = '';
  // --- State lifted from SearchBody ---
  // These are already part of TMDBHomePage state, so no need to duplicate.
  // They are passed to SearchBody.
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  List<dynamic> _watchHistory = [];
  final List<dynamic> _recentSearches = [];
  bool _isLoadingSearch = false;
  Timer? _searchDebounce;
  StreamSubscription? _downloadSub;
  double _maxKeyboardHeight = 0.0;

  late AnimationController _profileSpinnerController;

  @override
  void initState() {
    super.initState();
    _initialFetch();
    _fetchContinueWatching();
    _fetchGlobalTrending();
    _fetchWatchHistory();
}

  Future<void> _initialFetch() async {
    final url = 'https://api.themoviedb.org/3/trending/all/day?api_key=$tmdbApiKey';
    bool wasCached = _apiCache.containsKey(url);
    
    await fetchTrending(background: false);
    if (mounted && wasCached) {
      await Future.delayed(const Duration(seconds: 1));
      fetchTrending(background: true);
    }
    // Prefetch sports data in the background on app load
    LiveSportsApi().prefetch();

    _loadRecentSearches();
    _profileSpinnerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    // Listen for global download messages
    _downloadSub = DownloadManager().messages.listen((message) {
      if (mounted && message.isNotEmpty) {
        final parts = message.split(':');
        _fetchContinueWatching();
        _fetchWatchHistory();
        final type = parts.first;
        final content = parts.sublist(1).join(':');
        Color backgroundColor;
        switch (type) {
          case 'SUCCESS':
            backgroundColor = Colors.green;
            break;
          case 'ERROR':
            backgroundColor = Colors.red;
            break;
          default:
            backgroundColor = Colors.blue;
            break;
        }
        AppNotification.show(context, content, color: backgroundColor);
      }
    });
  }

  Future<void> _fetchContinueWatching() async {
    final list = await ProgressManager.getContinueWatching();
    if (mounted) {
      setState(() {
        _continueWatching = list;
      });
      _fetchRecommendations(list);
    }
  }

  Future<void> _fetchWatchHistory() async {
    final list = await ProgressManager.getWatchHistory();
    if (mounted) setState(() => _watchHistory = list);
  }

  Future<void> _fetchGlobalTrending() async {
    final list = await ProgressManager.getGlobalTrending();
    if (mounted) {
      setState(() => _globalTrending = list);
    }
  }

  Future<void> _fetchRecommendations(
    List<Map<String, dynamic>> continueWatching,
  ) async {
    if (continueWatching.isEmpty) return;

    Map<String, dynamic>? latestMovie;
    Map<String, dynamic>? latestTv;

    for (var item in continueWatching) {
      if (item['media_type'] == 'movie' && latestMovie == null) {
        latestMovie = item;
      }
      if (item['media_type'] == 'tv' && latestTv == null) latestTv = item;
      if (latestMovie != null && latestTv != null) break;
    }

    if (latestMovie != null) {
      final title = (latestMovie['title'] ?? latestMovie['name'] ?? 'Unknown')
          .toString();
      final recs = await _getRecommendations('movie', latestMovie['id']);
      if (mounted) {
        setState(() {
          _latestMovieTitle = title;
          _latestMovieRecs = recs;
        });
      }
    }

    if (latestTv != null) {
      final title = (latestTv['title'] ?? latestTv['name'] ?? 'Unknown')
          .toString();
      final recs = await _getRecommendations('tv', latestTv['id']);
      if (mounted) {
        setState(() {
          _latestTvTitle = title;
          _latestTvRecs = recs;
        });
      }
    }
  }

  Future<List<dynamic>> _getRecommendations(String type, dynamic id) async {
    try {
      final url =
          'https://api.themoviedb.org/3/$type/$id/recommendations?api_key=$tmdbApiKey';
      final data = await fetchWithCache(url);
      final List recs = data['results'] as List? ?? [];

      var filtered = recs
          .where((item) => _isReleased(item, strictFilter: true))
          .toList();
      if (filtered.isEmpty) {
        filtered = recs.where((item) => _isReleased(item)).toList();
      }

      return filtered.map((item) {
        item['media_type'] =
            item['media_type'] ?? (type == 'movie' ? 'movie' : 'tv');
        return item;
      }).toList();
    } catch (e) {
      debugPrint('Error fetching recommendations: $e');
      return [];
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _profileSpinnerController.dispose();
    _downloadSub?.cancel();
    // No need to dispose _webController or _ytController here, as they are managed by FeaturedMediaItem
    super.dispose();
  }

  // --- Methods lifted from SearchBody ---
  Future<void> _loadRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('recentSearches');
    if (saved != null && mounted) {
      setState(() {
        _recentSearches.clear();
        _recentSearches.addAll(saved.map((e) => json.decode(e)));
      });
    }
  }

  Future<void> _saveRecentSearches() async {
    final prefs = await SharedPreferences.getInstance();
    final serialized = _recentSearches.map((e) => json.encode(e)).toList();
    await prefs.setStringList('recentSearches', serialized);
  }

  void _onSearchChanged(String query) {
    if (_searchDebounce?.isActive ?? false) _searchDebounce!.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), () {
      if (query.trim().isNotEmpty) {
        _performSearch(query.trim());
      } else {
        setState(() {
          _searchResults = [];
          _isLoadingSearch = false;
        });
      }
    });
  }

  Future<void> _performSearch(String query) async {
    setState(() => _isLoadingSearch = true);
    try {
      final url =
          'https://api.themoviedb.org/3/search/multi?api_key=$tmdbApiKey&query=${Uri.encodeComponent(query)}';
      final data = await fetchWithCache(url);
      if (mounted) {
        setState(() {
          _searchResults = (data['results'] as List)
              .where(
                (item) => item['media_type'] != 'person' && _isReleased(item),
              )
              .toList();
          _isLoadingSearch = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingSearch = false);
    }
  }

  Future<void> fetchTrending({bool background = false}) async {
    try {
      final url =
          'https://api.themoviedb.org/3/trending/all/day?api_key=$tmdbApiKey';
      final data = await fetchWithCache(url, forceRefresh: background);
      if (mounted) {
        setState(() {
          final rawList = data['results'] as List? ?? [];
          final filtered = rawList
              .where((item) => _isReleased(item, strictFilter: true))
              .toList();
          final basicFiltered = rawList
              .where((item) => _isReleased(item))
              .toList();

          // Fallback if strict filter is too aggressive for the trending feed
          mediaList = filtered.isNotEmpty
              ? filtered
              : (basicFiltered.isNotEmpty ? basicFiltered : rawList);

          for (var item in mediaList) {
            if (item is Map && item['media_type'] == null) {
              item['media_type'] = item['title'] != null ? 'movie' : 'tv';
            }
          }
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
      debugPrint('Error: $e');
    }
  }

  void _handleResultTapped(dynamic media) {
    if (media is Map) {
      setState(() {
        _recentSearches.removeWhere((item) => item['id'] == media['id']);
        _recentSearches.insert(0, media);
        if (_recentSearches.length > 20) {
          _recentSearches.removeLast();
        }
      });
    }
    _saveRecentSearches();
  }

  // --- UI Builder Methods for Animated Bottom Bar ---

  Widget _buildNavBarContainer({required Widget child, bool isCircle = false}) {
    final borderRadius = isCircle ? 28.0 : 40.0;
    return Container(
      clipBehavior: Clip.hardEdge,
      height: 56,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: Colors.white.withOpacity(0.15), width: 1.0),
      ),
      child: child,
    );
  }

  // ignore: unused_element
  Widget _buildSearchIcon() {
    return IconButton(
      key: const ValueKey('search_icon'),
      iconSize: 56,
      padding: EdgeInsets.zero,
      icon: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.15)),
        ),
        child: const Icon(Icons.search, color: Colors.white, size: 28),
      ),
      onPressed: () {
        setState(() {
          _lastSelectedIndex = _selectedIndex;
          _selectedIndex = 3;
          _isSearchActive = true;
        });
      },
    );
  }

  Widget _buildSearchBar() {
    return _buildNavBarContainer(
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _searchController,
        builder: (context, value, child) {
          return TextField(
            key: const ValueKey('search_field'),
            controller: _searchController,
            autofocus: false,
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.left,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              hintText: 'Search movies, shows...',
              hintStyle: const TextStyle(color: Colors.white54),
              prefixIcon: Container(
                width: 48,
                alignment: Alignment.center,
                child: const Icon(Icons.search, color: Colors.white54),
              ),
              suffixIcon: value.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.white54),
                      onPressed: () {
                        _searchController.clear();
                        _onSearchChanged('');
                      },
                    )
                  : const SizedBox(width: 48),
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
            onChanged: _onSearchChanged,
          );
        },
      ),
    );
  }

  // ignore: unused_element
  Widget _buildCloseKeyboardIcon() {
    return IconButton(
      key: const ValueKey('close_keyboard_icon'),
      iconSize: 56,
      padding: EdgeInsets.zero,
      icon: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(0.15)),
        ),
        child: const Icon(Icons.close, color: Colors.white, size: 28),
      ),
      onPressed: () {
        FocusScope.of(context).unfocus();
        setState(() {
          _searchController.clear();
          _onSearchChanged('');
          _isSearchActive = false;
          _selectedIndex = _lastSelectedIndex;
        });
      },
    );
  }

  Widget _buildLiveTvModeSwitcher() {
    final itemValues = ['live', 'schedule'];
    final selectedIndex = itemValues.indexOf(_liveTvMode);
    const double itemWidth = 75.0;
    const double switcherWidth =
        (itemWidth * 2) + 2.0; // Account for 1px borders on each side
    const double switcherHeight =
        50.0; // Account for 1px borders on top and bottom

    return Container(
      width: switcherWidth,
      height: switcherHeight,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(40.0),
        border: Border.all(color: Colors.white.withOpacity(0.15), width: 1.0),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Sliding indicator
          AnimatedPositioned(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOutCubic,
            left: (selectedIndex * itemWidth),
            top: 0,
            width: itemWidth,
            height: switcherHeight,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(switcherHeight / 2),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
              ),
            ),
          ),
          // Icons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLiveTvSwitcherItem(
                Icons.live_tv,
                'live',
                selectedIndex == 0,
              ),
              _buildLiveTvSwitcherItem(
                Icons.calendar_today,
                'schedule',
                selectedIndex == 1,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLiveTvSwitcherItem(
    IconData icon,
    String value,
    bool isSelected,
  ) {
    const double itemWidth = 75.0;
    return GestureDetector(
      onTap: () => setState(() => _liveTvMode = value),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: itemWidth,
        height: 48.0,
        child: Center(
          child: AnimatedScale(
            scale: isSelected ? 1.1 : 1.0,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutBack,
            child: Icon(
              icon,
              color: isSelected ? Colors.white : Colors.white70,
              size: 28,
            ),
          ),
        ),
        // The search bar itself is handled by the AnimatedSwitcher below
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    // ignore: unused_local_variable
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
    if (keyboardHeight == 0) {
      // Reset max height when keyboard is closed to handle orientation/keyboard changes
      _maxKeyboardHeight = 0.0;
    } else if (keyboardHeight > _maxKeyboardHeight) {
      _maxKeyboardHeight = keyboardHeight;
    }
    // ignore: unused_local_variable
    final double screenWidth = MediaQuery.of(context).size.width;
    ImageProvider? profileImage;
    if (user?.photoURL != null) {
      if (user!.photoURL!.startsWith('data:image')) {
        final base64String = user.photoURL!.split(',').last;
        profileImage = MemoryImage(base64Decode(base64String));
      } else {
        profileImage = CachedNetworkImageProvider(user.photoURL!, headers: _cachedImageHttpHeaders);
      }
    }

    String appBarTitle = '';
    switch (_selectedIndex) {
      case 0:
        appBarTitle = 'LunarDrift';
        break;
      case 1:
        appBarTitle = 'Movies';
        break;
      case 2:
        appBarTitle = 'TV Shows';
        break;
      case 3:
        appBarTitle =
            'Search'; // This will now be triggered by the new app bar button
        break;
      case 4:
        appBarTitle = 'Live TV';
        break;
    }

    return Scaffold(
      // The resizeToAvoidBottomInset property is crucial for handling keyboard visibility
      // and preventing widgets from being obscured by the keyboard.
      // It should be true if the body contains editable text fields that might be covered.
      // In this case, the SearchBody handles its own keyboard interaction,
      // and the main content scrolls, so it's generally safe.
      // If issues arise, consider setting it to false and manually adjusting padding.
      resizeToAvoidBottomInset: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      extendBody: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        title: _selectedIndex == 4
            ? _buildLiveTvModeSwitcher()
            : Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(28.0),
                  border: Border.all(color: Colors.white.withOpacity(0.2)),
                ),
                child: Text(
                  appBarTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
        actionsPadding: const EdgeInsets.only(right: 16.0),
        actions: [
          if (_selectedIndex <= 2)
            IconButton(
              iconSize: 52,
              padding: EdgeInsets.zero,
              icon: Icon(
                _isMuted ? Icons.volume_off : Icons.volume_up,
                color: Colors.white,
                size: 28,
              ),
              onPressed: () {
                setState(() {
                  _isMuted = !_isMuted;
                });
              },
            ),
          if (_selectedIndex <= 2) const SizedBox(width: 12.0),
          IconButton(
            iconSize: 52,
            padding: EdgeInsets.zero,
            onPressed: () {
              // Await the result from MyStuffSheet to know if a refresh is needed
              showModalBottomSheet<bool?>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (context) => const MyStuffSheet(),
              ).then((myStuffChanged) {
                if (myStuffChanged == true) _refreshAllHomePageData();
              });
            },
            icon: ValueListenableBuilder<DownloadTask?>(
              valueListenable: DownloadManager().activeTaskNotifier,
              builder: (context, activeTask, child) {
                if (activeTask == null) {
                  return child!;
                }
                return AnimatedBuilder(
                  animation: activeTask,
                  builder: (context, _) {
                    final status = activeTask.status;
                    if (status == DownloadStatus.none ||
                        status == DownloadStatus.done) {
                      return child!;
                    }
                    return CustomPaint(
                      painter: DownloadProgressPainter(
                        status: status,
                        progress: activeTask.progress,
                        rotationAnimation: _profileSpinnerController,
                      ),
                      child: child,
                    );
                  },
                );
              },
              child: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(shape: BoxShape.circle),
                child: ClipOval(
                  child: profileImage == null
                      ? Container(
                          color: Colors.white24,
                          child: const Icon(
                            Icons.person,
                            size: 28,
                            color: Colors.white,
                          ),
                        )
                      : Image(
                          image: profileImage,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => 
                              Container(color: Colors.white24),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: RepaintBoundary(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: _selectedIndex == 0
              ? (isLoading
                    ? const Center(
                        key: ValueKey('home_loading'),
                        child: CircularProgressIndicator(
                          color: Color.fromARGB(255, 255, 255, 255),
                        ),
                      )
                    : SingleChildScrollView(
                        key: const ValueKey('home_content'),
                        padding: EdgeInsets.zero,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (mediaList.isNotEmpty)
                              FeaturedMediaItem(
                                mediaList: mediaList.take(5).toList(),
                                isMuted: _isMuted,
                                onRefresh: _refreshAllHomePageData,
                              ),
                            // This is where the FeaturedMediaItem is built.
                            // Its onTap navigates to MediaDetailsPage.
                            // We need to ensure that when MediaDetailsPage pops,
                            // TMDBHomePage refreshes its data if changes occurred.
                            // The onTap for FeaturedMediaItem is already modified above
                            // to await the result and call _fetchLogo().
                            const SizedBox(height: 20),
                            HorizontalMediaList(
                              categoryTitle: 'Trending Now',
                              items: mediaList.length > 5
                                  ? mediaList.skip(5).toList()
                                  : mediaList,
                              apiUrl:
                                  'https://api.themoviedb.org/3/trending/all/day?api_key=$tmdbApiKey',
                              onChildRefresh: () => fetchTrending(background: true),
                            ),
                            const SizedBox(height: 16),
                            if (_globalTrending.isNotEmpty)
                              HorizontalMediaList(
                                categoryTitle: 'What People are Watching',
                                onChildRefresh: () {
                                  _fetchWatchHistory();
                                  _fetchContinueWatching();
                                },
                                items: _globalTrending,
                              ),
                            const SizedBox(height: 16),
                            if (_continueWatching.isNotEmpty)
                              HorizontalMediaList(
                                categoryTitle: 'Continue Watching',
                                items: _continueWatching,
                                onChildRefresh: () {
                                  _fetchWatchHistory();
                                  _fetchContinueWatching();
                                },
                                onRefresh: _refreshAllHomePageData,
                              ),
                            const SizedBox(height: 16),
                            if (_latestTvRecs.isNotEmpty)
                              HorizontalMediaList(
                                categoryTitle: 'More Like $_latestTvTitle',
                                items: _latestTvRecs,
                                apiUrl: () {
                                  final item = _continueWatching.firstWhere(
                                    (i) => i['media_type']?.toString() == 'tv',
                                    orElse: () => <String, dynamic>{},
                                  );
                                  final id = item?['id']?.toString() ?? '';
                                  return id.isEmpty
                                      ? null
                                      : 'https://api.themoviedb.org/3/tv/$id/recommendations?api_key=$tmdbApiKey';
                                }(),
                                onChildRefresh: () {
                                  _fetchWatchHistory();
                                  _fetchContinueWatching();
                                },
                                defaultMediaType: 'tv',
                              ),
                            const SizedBox(height: 16),
                            if (_latestMovieRecs.isNotEmpty)
                              HorizontalMediaList(
                                categoryTitle: 'More Like $_latestMovieTitle',
                                items: _latestMovieRecs,
                                apiUrl: () {
                                  final item = _continueWatching.firstWhere(
                                    (i) =>
                                        i['media_type']?.toString() == 'movie',
                                    orElse: () => <String, dynamic>{},
                                  );
                                  final id = item?['id']?.toString() ?? '';
                                  return id.isEmpty
                                      ? null
                                      : 'https://api.themoviedb.org/3/movie/$id/recommendations?api_key=$tmdbApiKey';
                                }(),
                                onChildRefresh: () {
                                  _fetchWatchHistory();
                                  _fetchContinueWatching();
                                },
                                defaultMediaType: 'movie',
                              ),
                            const SizedBox(height: 120),
                          ],
                        ),
                      ))
              : _selectedIndex == 1
              ? MediaCategoryBody(
                  key: const ValueKey('movie'),
                  mediaType: 'movie',
                  isMuted: _isMuted,
                )
              : _selectedIndex == 2
              ? MediaCategoryBody(
                  key: const ValueKey('tv'),
                  mediaType: 'tv',
                  isMuted: _isMuted,
                )
              : _selectedIndex == 3
              ? SearchBody(
                  key: const ValueKey('search'),
                  results: _searchResults,
                  recentSearches: _recentSearches,
                  watchHistory: _watchHistory,
                  isLoading: _isLoadingSearch,
                  onResultTapped: _handleResultTapped,
                  onRefresh: _refreshAllHomePageData,
                  searchQuery: _searchController.text,
                )
              : _selectedIndex == 4
              ? (_liveTvMode == 'live'
                    ? const LiveTVPage(key: ValueKey('live_tv'))
                    : const ScheduleGuidePage(key: ValueKey('schedule_guide')))
              : const SizedBox.shrink(key: ValueKey('empty')),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(left: 16.0, bottom: 24.0 + keyboardHeight),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: SizedBox(
            height: 56,
            width: 418.0,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeInOutCubic,
                  left: 0,
                  width: _isSearchActive ? 0.0 : 284.0,
                  height: 56,
                  child: _buildNavBarContainer(
                    isCircle: false,
                    child: SlidingGlassBottomNavBar(
                      selectedIndex: _selectedIndex,
                      showIndicator: !_isSearchActive,
                      onTap: (index) {
                        setState(() {
                          _selectedIndex = index;
                          _isSearchActive = false;
                        });
                        if (index == 0) _refreshAllHomePageData();
                      },
                      isSearchActive: _isSearchActive,
                      expandedWidth: 282.0,
                      collapsedWidth: 0.0,
                      items: const [
                        BottomNavigationBarItem(
                          icon: Icon(Icons.home),
                          label: 'Home',
                        ),
                        BottomNavigationBarItem(
                          icon: Icon(Icons.movie),
                          label: 'Movies',
                        ),
                        BottomNavigationBarItem(
                          icon: Icon(Icons.tv),
                          label: 'TV Shows',
                        ),
                        BottomNavigationBarItem(
                          icon: Icon(Icons.sports_basketball),
                          label: 'Sports',
                        ),
                      ],
                      itemValues: const [0, 1, 2, 4],
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeInOutCubic,
                  left: _isSearchActive ? 0.0 : 294.0,
                  width: _isSearchActive ? 350.0 : 56.0,
                  height: 56,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _isSearchActive
                        ? _buildSearchBar()
                        : _buildSearchIcon(),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeInOutCubic,
                  left: _isSearchActive ? 362.0 : 418.0,
                  width: 56,
                  height: 56,
                  child: _buildCloseKeyboardIcon(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Helper to refresh all relevant data on the home page
  void _refreshAllHomePageData() {
    fetchTrending(background: true);
    _fetchGlobalTrending();
    _fetchWatchHistory();
    _fetchContinueWatching();
    _loadRecentSearches();
  }
}

class SlidingGlassBottomNavBar extends StatelessWidget {
  final int selectedIndex;
  final Function(int) onTap;
  final List<int>? itemValues;
  final List<BottomNavigationBarItem> items;
  final bool showIndicator;
  final bool isSearchActive;
  final double expandedWidth;
  final double collapsedWidth;

  const SlidingGlassBottomNavBar({
    super.key,
    required this.selectedIndex,
    required this.onTap,
    this.itemValues,
    required this.items,
    this.showIndicator = true,
    this.isSearchActive = false,
    required this.expandedWidth,
    required this.collapsedWidth,
  });

  @override
  Widget build(BuildContext context) {
    final values =
        itemValues ?? List<int>.generate(items.length, (index) => index);
    final activeItemIndex = values.indexOf(selectedIndex);
    const indicatorHeight = 56.0; // Use fixed height of the parent container

    final expandedItemWidth = items.isNotEmpty
        ? expandedWidth / items.length
        : 0.0;
    final indicatorTargetWidth = isSearchActive
        ? collapsedWidth
        : expandedItemWidth;
    final indicatorTargetLeft = activeItemIndex != -1
        ? activeItemIndex * expandedItemWidth
        : 0.0;

    return Stack(
      alignment: Alignment.centerLeft,
      clipBehavior: Clip.hardEdge,
      children: [
        // Sliding glass indicator
        if (activeItemIndex != -1)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOutCubic,
            left: indicatorTargetLeft,
            top: 0,
            width: indicatorTargetWidth,
            height: indicatorHeight,
            child: AnimatedOpacity(
              opacity: showIndicator ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOutCubic,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(indicatorHeight / 2),
                  border: Border.all(color: Colors.white.withOpacity(0.2)),
                ),
              ),
            ),
          ),
        // Icons
        Row(
          children: items.asMap().entries.map((entry) {
            final index = entry.key;
            final item = entry.value;
            final isSelected = values[index] == selectedIndex;
            final isHomeButton = index == 0;

            final homeItemTargetWidth = isSearchActive
                ? collapsedWidth
                : expandedItemWidth;
            final otherItemTargetWidth = isSearchActive
                ? 0.0
                : expandedItemWidth;
            final targetWidth = isHomeButton
                ? homeItemTargetWidth
                : otherItemTargetWidth;

            Widget iconWidget = GestureDetector(
              onTap: () => onTap(values[index]),
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: AnimatedScale(
                  scale: isSelected && showIndicator ? 1.2 : 1.0,
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutBack,
                  child: Icon(
                    (item.icon as Icon).icon,
                    color: isSelected && showIndicator
                        ? Colors.white
                        : Colors.white70,
                  ),
                ),
              ),
            );

            return AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOutCubic,
              width: targetWidth,
              clipBehavior: Clip.hardEdge,
              decoration: const BoxDecoration(),
              child: AnimatedOpacity(
                opacity: !isSearchActive ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOutCubic,
                child: iconWidget,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  // Add a state variable to track if any changes were made
  Widget _buildSettingsItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return ListTile(
      leading: Icon(
        icon,
        color: isDestructive ? Colors.redAccent : Colors.white70,
        size: 28,
      ),
      title: Text(
        title,
        style: TextStyle(
          color: isDestructive ? Colors.redAccent : Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            )
          : null,
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 24.0,
        vertical: 8.0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Use a StatefulBuilder to manage a local state for changes
    return StatefulBuilder(
      builder: (context, setState) {
        final user = FirebaseAuth.instance.currentUser;

        ImageProvider? profileImage;
        if (user?.photoURL != null) {
          if (user!.photoURL!.startsWith('data:image')) {
            final base64String = user.photoURL!.split(',').last;
            profileImage = MemoryImage(base64Decode(base64String));
          } else {
            profileImage = CachedNetworkImageProvider(user.photoURL!, headers: _cachedImageHttpHeaders);
          }
        }

        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0, // Remove shadow
            scrolledUnderElevation: 0, // Remove shadow when scrolled
            surfaceTintColor: Colors.transparent, // Remove tint color
            title: const Text(
              'Settings',
              style: TextStyle(
                // Ensure title is visible against transparent app bar
                // This might need to be adjusted based on the actual design
                // of the app bar in the overall theme.
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: ListView(
            children: [
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Row(
                  children: [
                    if (profileImage != null)
                      CircleAvatar(radius: 30, backgroundImage: profileImage)
                    else
                      const CircleAvatar(
                        radius: 30,
                        backgroundColor: Colors.white24,
                        child: Icon(
                          Icons.person,
                          size: 30,
                          color: Colors.white,
                        ),
                      ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (user?.displayName != null &&
                                    user!.displayName!.isNotEmpty)
                                ? user.displayName!
                                : 'Account',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (user?.email != null &&
                              user!.email!.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              user.email!,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Divider(color: Colors.white24, height: 1),
              _buildSettingsItem(
                context,
                icon: Icons.delete_sweep_outlined,
                title: 'Clear Search History',
                subtitle: 'Removes all your recent searches.',
                onTap: () async {
                  final bool? confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        backgroundColor: const Color(0xFF1E1F24),
                        title: const Text(
                          'Clear Search History',
                          style: TextStyle(color: Colors.white),
                        ),
                        content: const Text(
                          'Are you sure you want to clear your recent searches? This cannot be undone.',
                          style: TextStyle(color: Colors.white70),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text(
                              'Cancel',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () => Navigator.of(context).pop(true),
                            child: const Text('Clear'),
                          ),
                        ],
                      );
                    },
                  );

                  if (confirm == true) {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove('recentSearches');
                    if (context.mounted) {
                      AppNotification.show(
                        context,
                        'Search history cleared.',
                        color: Colors.green,
                      );
                    }
                  }
                },
              ),
              const Divider(
                color: Colors.white24,
                indent: 24,
                endIndent: 24,
                height: 1,
              ),
              _buildSettingsItem(
                context,
                icon: Icons.history,
                title: 'Clear Watch History',
                subtitle:
                    'Removes your entire continue watching and watch history.',
                onTap: () async {
                  final bool? confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) {
                      return AlertDialog(
                        backgroundColor: const Color(0xFF1E1F24),
                        title: const Text(
                          'Clear Watch History',
                          style: TextStyle(color: Colors.white),
                        ),
                        content: const Text(
                          'Are you sure you want to clear your entire watch history? This cannot be undone.',
                          style: TextStyle(color: Colors.white70),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text(
                              'Cancel',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () => Navigator.of(context).pop(true),
                            child: const Text('Clear'),
                          ),
                        ],
                      );
                    },
                  );

                  if (confirm == true) {
                    await ProgressManager.clearWatchHistory();
                    if (context.mounted) {
                      AppNotification.show(
                        context,
                        'Watch history cleared.',
                        color: Colors.green,
                      );
                    }
                  }
                },
              ),
              const Divider(
                color: Colors.white24,
                indent: 24,
                endIndent: 24,
                height: 1,
              ),
              _buildSettingsItem(
                context,
                icon: Icons.logout,
                title: 'Sign Out',
                isDestructive: true,
                onTap: () async {
                  try {
                    try {
                      if (!kIsWeb &&
                          (defaultTargetPlatform == TargetPlatform.android ||
                              defaultTargetPlatform == TargetPlatform.iOS)) {
                        await gsi.GoogleSignIn.instance.signOut();
                      }
                    } catch (_) {}

                    await FirebaseAuth.instance.signOut();
                    if (context.mounted) {
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    }
                  } catch (e) {
                    debugPrint('Error signing out: $e');
                  }
                },
              ),
              const Divider(
                color: Colors.white24,
                indent: 24,
                endIndent: 24,
                height: 1,
              ),
              _buildSettingsItem(
                context,
                icon: Icons.developer_mode_outlined,
                title: 'Native Player Test',
                subtitle: 'Test direct stream links with custom headers.',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const NativeTestPlayerPage(streamUrl: ''),
                    ),
                  );
                },
              ),
              const Divider(
                color: Colors.white24,
                indent: 24,
                endIndent: 24,
                height: 1,
              ),
              _buildSettingsItem(
                context,
                icon: Icons.person_remove_outlined,
                title: 'Delete Account',
                subtitle: 'Permanently delete your account and data.',
                isDestructive: true,
                onTap: () async {
                  final bool? confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: const Color(0xFF1E1F24),
                      title: const Text(
                        'Delete Account',
                        style: TextStyle(color: Colors.white),
                      ),
                      content: const Text(
                        'This will permanently delete your account and all your data. This action cannot be undone.',
                        style: TextStyle(color: Colors.white70),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true) {
                    try {
                      final user = FirebaseAuth.instance.currentUser;
                      if (user == null) return;

                      // Delete Firestore data first
                      final db = FirebaseFirestore.instance;
                      final batch = db.batch();

                      final watchlist = await db
                          .collection('users')
                          .doc(user.uid)
                          .collection('watchlist')
                          .get();
                      // ignore: curly_braces_in_flow_control_structures
                      for (var doc in watchlist.docs) {
                        batch.delete(doc.reference);
                      }

                      final progress = await db
                          .collection('users')
                          .doc(user.uid)
                          .collection('progress')
                          .get();
                      // ignore: curly_braces_in_flow_control_structures
                      for (var doc in progress.docs) {
                        batch.delete(doc.reference);
                      }

                      batch.delete(db.collection('users').doc(user.uid));
                      await batch.commit();

                      // Delete Firebase Auth user
                      await user.delete();

                      if (context.mounted) {
                        Navigator.of(
                          context,
                        ).popUntil((route) => route.isFirst);
                        AppNotification.show(
                          context,
                          'Account deleted successfully.',
                          color: Colors.green,
                        );
                      }
                    } on FirebaseAuthException catch (e) {
                      if (e.code == 'requires-recent-login') {
                        if (context.mounted) {
                          AppNotification.show(
                            context,
                            'Please sign out and sign back in to delete your account.',
                            color: Colors.red,
                          );
                        }
                      } else {
                        if (context.mounted) {
                          AppNotification.show(
                            context,
                            'Error deleting account: ${e.message}',
                            color: Colors.red,
                          );
                        }
                      }
                    } catch (e) {
                      if (context.mounted) {
                        AppNotification.show(
                          context,
                          'Error: $e',
                          color: Colors.red,
                        );
                      }
                    }
                  }
                },
              ),
              const Divider(color: Colors.white24, height: 1),
            ],
          ),
        );
      },
    ); // End of StatefulBuilder
  }
}

class FeaturedMediaItem extends StatefulWidget {
  final List<dynamic> mediaList;
  final bool isMuted;
  final VoidCallback? onRefresh;

  const FeaturedMediaItem({
    super.key,
    required this.mediaList,
    this.isMuted = true,
    this.onRefresh,
  });

  @override
  State<FeaturedMediaItem> createState() => _FeaturedMediaItemState();
}

class _FeaturedMediaItemState extends State<FeaturedMediaItem>
    with TickerProviderStateMixin {
  late AnimationController _progressController;
  int _currentIndex = 0;
  String? _logoPath;
  bool _showContent = false;
  String _contentRating = '';
  String _displayYear = '';

  WebViewController? _webController;
  YoutubePlayerController? _ytController;
  bool _isVideoPlaying = false;
  String? _trailerKey;
  Timer? _trailerDelayTimer;
  Timer? _fadeDelayTimer;
  int _selectedSeason = 1;
  int _selectedEpisode = 1;
  double _featuredMovieProgress = 0.0;
  Map<int, Map<int, double>> _featuredTvProgress = {};
  Timer? _audioFadeTimer;
  Timer? _audioFadeInterval;
  Timer? _transitionTimer;
  Color? _dominantColor;
  bool _isCamRelease = false;
  bool get _useWebView =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(vsync: this);
    _progressController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        _goToItem((_currentIndex + 1) % widget.mediaList.length);
        _featuredMovieProgress = 0.0; // Reset for next item
        _featuredTvProgress = {}; // Reset for next item
      }
    });
    _fetchLogo();
  }

  @override
  void didUpdateWidget(FeaturedMediaItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isMuted != widget.isMuted) {
      if (_useWebView && _webController != null) {
        _webController!.runJavaScript(
          'if (typeof setMute === "function") setMute(${widget.isMuted});',
        );
      } else if (!_useWebView && _ytController != null) {
        if (widget.isMuted) {
          _ytController!.mute();
        } else {
          _ytController!.unMute();
          _ytController!.setVolume(100);
        }
      }
    }
    if (oldWidget.mediaList.isEmpty ||
        widget.mediaList.isEmpty ||
        oldWidget.mediaList[0]['id'] != widget.mediaList[0]['id']) {
      _stopTrailerVideo();
      _progressController.reset();
      _transitionTimer?.cancel();
      setState(() {
        _currentIndex = 0;
        _showContent = false;
        _displayYear = '';
        _isVideoPlaying = false;
        _isCamRelease = false;
        _featuredMovieProgress = 0.0; // Reset for next item
        _featuredTvProgress = {}; // Reset for next item
      });
      _fetchLogo();
    }
  }

  void _goToItem(int index) {
    if (!mounted || _currentIndex == index) return;
    _stopTrailerVideo(keepVideoVisible: true);
    _progressController.stop();
    _progressController.reset();
    _transitionTimer?.cancel();
    setState(() {
      _showContent = false;
    });
    _transitionTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() {
        _currentIndex = index;
        _displayYear = '';
        _isVideoPlaying = false;
        _dominantColor = null;
        _featuredMovieProgress = 0.0; // Reset for next item
        _featuredTvProgress = {}; // Reset for next item
        _isCamRelease = false;
      });
      _fetchLogo();
    });
  }

  Future<void> _extractDominantColor(String imageUrl) async {
    try {
      final colorScheme = await ColorScheme.fromImageProvider(
        provider: CachedNetworkImageProvider(imageUrl, headers: _cachedImageHttpHeaders),
        brightness: Brightness.dark,
      );

      if (mounted) {
        setState(() {
          _dominantColor = colorScheme.primary;
        });
      }
    } catch (e) {
      debugPrint('Error extracting color: $e');
    }
  }

  Future<void> _fetchLogo() async {
    if (widget.mediaList.isEmpty) return;
    final media = widget.mediaList[_currentIndex];
    final mediaType = media['media_type'] ?? 'movie';
    final mediaId = media['id'];
    if (mediaId == null) {
      if (mounted) setState(() => _showContent = true);
      return;
    }

    final url =
        'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey&append_to_response=images,content_ratings,release_dates,videos&include_image_language=en,null';
    try {
      final data = await fetchWithCache(url);
      if (mounted && media['id'] == widget.mediaList[_currentIndex]['id']) {
        String? extractedLogo;
        if (data['images'] != null && data['images']['logos'] is List) {
          final logos = data['images']['logos'] as List;
          final validLogos = logos
              .where(
                (l) =>
                    l is Map &&
                    !(l['file_path']?.toString().toLowerCase().endsWith(
                          '.svg',
                        ) ??
                        false),
              )
              .toList();
          if (validLogos.isNotEmpty) {
            validLogos.sort((a, b) {
              final double voteA =
                  double.tryParse(a['vote_average']?.toString() ?? '0') ?? 0.0;
              final double voteB =
                  double.tryParse(b['vote_average']?.toString() ?? '0') ?? 0.0;
              return voteB.compareTo(voteA);
            });
            final enLogo = validLogos.firstWhere(
              (l) => l['iso_639_1'] == 'en',
              orElse: () => validLogos.first,
            );
            extractedLogo = enLogo['file_path'];
          }
        }

        if (extractedLogo != null) {
          await _extractDominantColor(
            'https://image.tmdb.org/t/p/w500$extractedLogo',
          );
        } else if (media['poster_path'] != null) {
          _extractDominantColor(
            'https://image.tmdb.org/t/p/w300${media['poster_path']}',
          );
        } else {
          if (mounted) { // Added await
            setState(() => _dominantColor = null);
          }
        }

        String? extractedTrailer;
        if (data['videos'] != null && data['videos']['results'] is List) {
          for (var v in data['videos']['results']) {
            if (v is Map && v['type'] == 'Trailer' && v['site'] == 'YouTube') {
              extractedTrailer = v['key'];
              break;
            }
          }
        }

        String cert = '';
        if (mediaType == 'movie' &&
            data['release_dates'] != null &&
            data['release_dates']['results'] is List) {
          final results = data['release_dates']['results'] as List;
          for (var r in results) {
            if (r is Map &&
                r['iso_3166_1'] == 'US' &&
                r['release_dates'] is List) {
              for (var d in r['release_dates']) {
                if (d is Map &&
                    d['certification'] != null &&
                    d['certification'].toString().isNotEmpty) {
                  cert = d['certification'].toString();
                  break;
                }
              }
              break;
            }
          }
        } else if (mediaType == 'tv' &&
            data['content_ratings'] != null &&
            data['content_ratings']['results'] is List) {
          final results = data['content_ratings']['results'] as List;
          for (var r in results) {
            if (r is Map && r['iso_3166_1'] == 'US' && r['rating'] != null) {
              cert = r['rating'].toString();
              break;
            }
          }
        }

        String fetchedYear = '';
        if (mediaType == 'tv') {
          final firstAir = data['first_air_date']?.toString();
          final lastAir = data['last_air_date']?.toString();
          final status = data['status']?.toString() ?? '';
          final numSeasons = data['number_of_seasons'];

          String startYear = '';
          if (firstAir != null && firstAir.length >= 4) {
            startYear = firstAir.substring(0, 4);
          } else {
            final fallback = media['first_air_date']?.toString();
            if (fallback != null && fallback.length >= 4) {
              startYear = fallback.substring(0, 4);
            }
          }

          String endYear = '';
          if (lastAir != null && lastAir.length >= 4) {
            endYear = lastAir.substring(0, 4);
          }

          String seasonStr = '';
          if (numSeasons != null && numSeasons > 0) {
            seasonStr = ' • $numSeasons Season${numSeasons == 1 ? '' : 's'}';
          }

          if (startYear.isNotEmpty) {
            if (status == 'Ended' || status == 'Canceled') {
              if (endYear.isNotEmpty && endYear != startYear) {
                fetchedYear = '$startYear - $endYear$seasonStr';
              } else {
                fetchedYear = '$startYear$seasonStr';
              }
            } else {
              fetchedYear = '$startYear - Present$seasonStr';
            }
          } else if (seasonStr.isNotEmpty) {
            fetchedYear = seasonStr.substring(3);
          }
        } else {
          final releaseDateRaw = data['release_date'] ?? media['release_date'];
          if (releaseDateRaw != null && releaseDateRaw.toString().length >= 4) {
            fetchedYear = releaseDateRaw.toString().substring(0, 4);
          }
          final runtime = data['runtime'];
          if (runtime != null && runtime > 0) {
            final int hrs = runtime ~/ 60;
            final int mins = runtime % 60;
            final runtimeStr = hrs > 0 ? ' • ${hrs}h ${mins}m' : ' • ${mins}m';
            fetchedYear = '$fetchedYear$runtimeStr';
          }
        }

        bool isCam = false;
        if (mediaType == 'movie' &&
            data['release_dates'] != null &&
            data['release_dates']['results'] is List) {
          bool isOlderThanOneYear = false;
          if (data['release_date'] != null &&
              data['release_date'].toString().isNotEmpty) {
            try {
              final mainRelease = DateTime.parse(
                data['release_date'].toString(),
              );
              if (DateTime.now().difference(mainRelease).inDays > 365) {
                isOlderThanOneYear = true;
              }
            } catch (_) {}
          }

          if (!isOlderThanOneYear) {
            final results = data['release_dates']['results'] as List;
            for (var r in results) {
              if (r is Map &&
                  r['iso_3166_1'] == 'US' &&
                  r['release_dates'] is List) {
                final dates = r['release_dates'] as List;
                final now = DateTime.now();
                List<Map<String, dynamic>> pastReleases = [];

                for (var d in dates) {
                  if (d is Map && d['release_date'] != null) {
                    final date = DateTime.tryParse(d['release_date']);
                    if (date != null && date.isBefore(now)) {
                      pastReleases.add({
                        'date': date,
                        'type': d['type'] as int? ?? 0,
                      });
                    }
                  }
                }

                if (pastReleases.isNotEmpty) {
                  pastReleases.sort(
                    (a, b) => (a['date'] as DateTime).compareTo(
                      b['date'] as DateTime,
                    ),
                  );
                  final latestType = pastReleases.last['type'] as int;
                  if (latestType == 2 || latestType == 3) {
                    isCam =
                        pastReleases.length == 1 ||
                        [1, 2, 3].contains(
                          pastReleases[pastReleases.length - 2]['type'] as int,
                        );
                  }
                }
                break;
              }
            }
          }
        }
        // --- NEW: Fetch and update progress ---
        if (mediaType == 'tv') {
          final showProgress = await ProgressManager.getShowProgress(mediaId);
          if (mounted) {
            final Map<int, Map<int, double>> tempTvProgress = {};
            for (var prog in showProgress) {
              final s = prog['season'] as int?;
              final e = prog['episode'] as int?;
              if (s != null && e != null) {
                tempTvProgress.putIfAbsent(s, () => {})[e] =
                    (prog['progress'] as num?)?.toDouble() ?? 0.0;
              }
            }

            int latestSeason = 1;
            int latestEpisode = 1;
            double latestProgress = 0.0;

            if (tempTvProgress.isNotEmpty) {
              // Find the highest season with any progress
              latestSeason = tempTvProgress.keys.reduce(
                (a, b) => a > b ? a : b,
              );
              Map<int, double>? episodesInLatestSeason =
                  tempTvProgress[latestSeason];

              if (episodesInLatestSeason != null &&
                  episodesInLatestSeason.isNotEmpty) {
                // Find the highest episode watched in that season
                latestEpisode = episodesInLatestSeason.keys.reduce(
                  (a, b) => a > b ? a : b,
                );
                latestProgress = episodesInLatestSeason[latestEpisode] ?? 0.0;
              }
            }

            // If the latest episode is completed (>= 90%), suggest the next one
            if (latestProgress >= 0.9) {
              _selectedSeason = latestSeason;
              _selectedEpisode = latestEpisode + 1; // Suggest next episode
            } else {
              // Otherwise, resume the last watched one
              _selectedSeason = latestSeason;
              _selectedEpisode = latestEpisode;
            }
            _featuredTvProgress = tempTvProgress;
          }
        } else {
          // movie
          final savedProgress = await ProgressManager.getProgress(mediaId);
          if (mounted) {
            _featuredMovieProgress =
                (savedProgress?['progress'] as num?)?.toDouble() ?? 0.0;
          }
        }
        // --- END NEW ---
        setState(() {
          _logoPath = extractedLogo;
          _contentRating = cert;
          _displayYear = fetchedYear;
          _trailerKey = extractedTrailer; // Only update _trailerKey here
          // Removed: _isVideoPlaying = false; // This flag should be controlled by the video player's state
          _isCamRelease = isCam;
        });

        if (_trailerKey != null && defaultTargetPlatform != TargetPlatform.windows) {
          _trailerDelayTimer?.cancel();
          _trailerDelayTimer = Timer(const Duration(seconds: 2), () {
            if (mounted &&
                media['id'] == widget.mediaList[_currentIndex]['id']) {
              _loadTrailerVideo(_trailerKey!);
            }
          });
        } else {
          _stopTrailerVideo();
          if (mounted && media['id'] == widget.mediaList[_currentIndex]['id']) {
            _progressController.duration = const Duration(seconds: 10);
            _progressController.forward(from: 0.0);
          }
        }
      }
    } catch (_) {}

    if (mounted && media['id'] == widget.mediaList[_currentIndex]['id']) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted && media['id'] == widget.mediaList[_currentIndex]['id']) {
          setState(() => _showContent = true);
        }
      });
    }
  }

  void _onVideoStarted(double duration) {
    if (!mounted) return;
    if (!_isVideoPlaying) {
      _fadeDelayTimer?.cancel();
      _fadeDelayTimer = Timer(const Duration(seconds: 0), () {
        if (mounted) setState(() => _isVideoPlaying = true);
      });

      double playSeconds = duration > 30.0 ? 30.0 : duration;
      if (playSeconds <= 0) playSeconds = 30.0;

      _progressController.duration = Duration(
        milliseconds: (playSeconds * 1000).toInt(),
      );
      _progressController.forward(from: 0.0);

      if (playSeconds > 2.0) {
        _audioFadeTimer?.cancel();
        _audioFadeTimer = Timer(
          Duration(milliseconds: ((playSeconds - 2.0) * 1000).toInt()),
          () {
            _startAudioFade();
          },
        );
      }
    }
  }

  void _startAudioFade() {
    if (widget.isMuted || !mounted) return;
    int currentVol = 100;
    _audioFadeInterval?.cancel();
    _audioFadeInterval = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (widget.isMuted || !mounted) {
        timer.cancel();
        return;
      }
      currentVol -= 5;
      if (currentVol <= 0) {
        currentVol = 0;
        timer.cancel();
      }
      if (_useWebView && _webController != null) {
        _webController!.runJavaScript(
          'if (typeof player !== "undefined" && typeof player.setVolume === "function") { player.setVolume($currentVol); }',
        );
      } else if (!_useWebView && _ytController != null) {
        _ytController!.setVolume(currentVol);
      }
    });
  }

  void _initWebController() {
    late final PlatformWebViewControllerCreationParams params;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      params = WindowsWebViewControllerCreationParams();
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    _webController = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel(
        'FlutterVideo',
        onMessageReceived: (message) {
          if (message.message.startsWith('playing') && mounted) {
            final parts = message.message.split(':');
            double duration = 0.0;
            if (parts.length > 1) {
              duration = double.tryParse(parts[1]) ?? 0.0;
            }
            _onVideoStarted(duration);
          }
        },
      );

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        (_webController!.platform as dynamic)
            .setMediaPlaybackRequiresUserGesture(false);
      } catch (_) {}
    }
  }

  void _loadTrailerVideo(String key) {
    if (_useWebView) {
      if (_webController == null) {
        _initWebController();
        final html =
            '''
          <!DOCTYPE html>
          <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>body { margin: 0; background: black; overflow: hidden; pointer-events: none; } iframe { border: none; width: 100vw; height: 100vh; pointer-events: none; }</style>
          </head>
          <body>
            <div id="player"></div>
            <script>
              var tag = document.createElement('script');
              tag.src = "https://www.youtube.com/iframe_api";
              var firstScriptTag = document.getElementsByTagName('script')[0];
              firstScriptTag.parentNode.insertBefore(tag, firstScriptTag);
              
              var player;
              function onYouTubeIframeAPIReady() {
                player = new YT.Player('player', {
                  height: '100%',
                  width: '100%',
                  videoId: '$key',
                  playerVars: {
                    'autoplay': 1,
                    'controls': 0,
                    'disablekb': 1,
                    'fs': 0,
                    'modestbranding': 1,
                    'playsinline': 1,
                    'mute': ${widget.isMuted ? 1 : 0},
                    'rel': 0,
                    'iv_load_policy': 3
                  },
                  events: {
                    'onReady': function(event) {
                      event.target.playVideo();
                    },
                    'onStateChange': function(event) {
                      if (event.data == YT.PlayerState.ENDED) {
                        player.playVideo();
                      }
                      if (event.data == YT.PlayerState.PLAYING) {
                        var duration = player.getDuration();
                        var msg = 'playing:' + duration;
                        if (typeof FlutterVideo !== 'undefined') FlutterVideo.postMessage(msg);
                        else if (window.FlutterVideo) window.FlutterVideo.postMessage(msg);
                      }
                    }
                  }
                });
              }
              function setMute(mute) {
                if (player && typeof player.mute === 'function') {
                  if (mute) player.mute();
                  else { player.unMute(); player.setVolume(100); }
                }
              }
            </script>
          </body>
          </html>
        ''';
        _webController!.loadHtmlString(html, baseUrl: 'http://localhost:5000');
        if (mounted) {
          setState(() {});
        }
      } else {
        _webController!.runJavaScript(
          'if (typeof player !== "undefined" && typeof player.loadVideoById === "function") { player.setVolume(100); player.loadVideoById("$key"); player.playVideo(); }',
        );
      }
    } else {
      if (_ytController == null) {
        _ytController = YoutubePlayerController.fromVideoId(
          videoId: key,
          autoPlay: true,
          params: YoutubePlayerParams(
            showControls: false,
            mute: widget.isMuted,
            showFullscreenButton: false,
            pointerEvents: PointerEvents.none,
            loop: true,
            showVideoAnnotations: false,
            strictRelatedVideos: true,
          ),
        );
        _ytController!.listen((event) {
          if (event.playerState == PlayerState.playing && !_isVideoPlaying) {
            double duration = event.metaData.duration.inMilliseconds / 1000.0;
            _onVideoStarted(duration);
          }
        });
        if (mounted) {
          setState(() {});
        }
      } else {
        _ytController!.setVolume(100);
        _ytController!.loadVideoById(videoId: key);
        _ytController!.playVideo();
      }
    }
  }

  void _stopTrailerVideo({
    bool isDisposing = false,
    bool keepVideoVisible = false,
  }) {
    _trailerDelayTimer?.cancel();
    _fadeDelayTimer?.cancel();
    _audioFadeTimer?.cancel();
    _audioFadeInterval?.cancel();
    if (mounted && !isDisposing) {
      _progressController.stop();
    }
    if (_useWebView && _webController != null) {
      _webController!.runJavaScript(
        'if (typeof player !== "undefined" && typeof player.pauseVideo === "function") { player.pauseVideo(); }',
      );
    }
    if (!_useWebView && _ytController != null) {
      _ytController!.pauseVideo();
    }
    if (mounted && _isVideoPlaying && !isDisposing && !keepVideoVisible) {
      setState(() => _isVideoPlaying = false);
    }
  }

  @override
  void dispose() {
    _trailerDelayTimer?.cancel();
    _transitionTimer?.cancel();
    _progressController.dispose();
    _stopTrailerVideo(isDisposing: true);
    _ytController?.close();
    if (_webController != null) {
      // Loading a blank page is a good way to release web resources.
      _webController!.loadRequest(Uri.parse('about:blank'));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mediaList.isEmpty) return const SizedBox.shrink();

    // Ensure _currentIndex is within bounds
    if (_currentIndex >= widget.mediaList.length) {
      _currentIndex = 0;
    }

    final size = MediaQuery.sizeOf(context);

    final isMobile = size.width < 600;

    // Fade starts at 800px width; the content area becomes more transparent as window widens
    final double bgOpacity = (1.0 - (size.width - 800) / 1400).clamp(0.15, 1.0);
    final media = widget.mediaList[_currentIndex];
    final imageUrl = media['backdrop_path'] != null
        ? 'https://image.tmdb.org/t/p/original${media['backdrop_path']}'
        : (media['poster_path'] != null
              ? 'https://image.tmdb.org/t/p/original${media['poster_path']}'
              : 'https://via.placeholder.com/1280x720?text=No+Image');
    final String title = (media['title'] ?? media['name'] ?? 'Unknown')
        .toString();
    final overview = media['overview']?.toString() ?? '';
    final releaseDateRaw = media['release_date'] ?? media['first_air_date'];
    final releaseDate = releaseDateRaw?.toString() ?? '';
    final releaseYear = releaseDate.length >= 4
        ? releaseDate.substring(0, 4)
        : '';
    final displayYearText = _displayYear.isNotEmpty
        ? _displayYear
        : releaseYear;
    final voteAverageRaw = media['vote_average'];
    final voteAverage = voteAverageRaw != null
        ? double.tryParse(voteAverageRaw.toString())?.toStringAsFixed(1) ?? ''
        : '';
    final heroTag = 'featured_${media['media_type']}_${media['id']}';

    final isTvShow =
        media['media_type'] == 'tv' || media['first_air_date'] != null;
    double currentProgress = 0.0;
    int selectedSeason = 1;
    int selectedEpisode = 1;

    if (isTvShow) {
      selectedSeason = _selectedSeason;
      selectedEpisode = _selectedEpisode;
      if (_featuredTvProgress.containsKey(selectedSeason) &&
          _featuredTvProgress[selectedSeason]!.containsKey(selectedEpisode)) {
        currentProgress =
            _featuredTvProgress[selectedSeason]![selectedEpisode]!;
      } else {
        currentProgress =
            0.0; // If no progress for this specific episode, assume 0
      }
    } else {
      currentProgress = _featuredMovieProgress;
    }

    String playButtonText = isTvShow
        ? ((currentProgress > 0 && currentProgress < 1.0)
              ? (isMobile
                    ? 'Resume'
                    : 'Resume S$selectedSeason E$selectedEpisode')
              : (isMobile ? 'Play' : 'Play S$selectedSeason E$selectedEpisode'))
        : ((currentProgress > 0 && currentProgress < 1.0)
              ? (_isCamRelease ? 'Resume (Cam)' : 'Resume')
              : (_isCamRelease ? 'Play (Cam)' : 'Play'));

    final Color? btnBaseColor = (!isTvShow && _isCamRelease)
        ? Colors.red
        : _dominantColor;

    return GestureDetector(
      onTap: () {
        _stopTrailerVideo();
        // Explicitly nullify controllers to force re-initialization when returning
        _webController = null;
        _ytController?.close();
        _ytController = null;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                MediaDetailsPage(media: media, heroTag: heroTag),
          ),
        ).then((shouldRefresh) {
          if (mounted) {
            if (shouldRefresh == true) widget.onRefresh?.call();
            setState(() {
              _isVideoPlaying = false;
              _showContent = false;
            });
            _progressController.reset();
            _fetchLogo();
          }
        });
      },
      onHorizontalDragEnd: (details) {
        if (widget.mediaList.length <= 1) return;
        if (details.primaryVelocity == null) return;

        if (details.primaryVelocity! < -100) {
          // Swiped Left -> Go to Next Item
          _goToItem((_currentIndex + 1) % widget.mediaList.length);
        } else if (details.primaryVelocity! > 100) {
          // Swiped Right -> Go to Previous Item
          _goToItem(
            (_currentIndex - 1 + widget.mediaList.length) %
                widget.mediaList.length,
          );
        }
      },
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          SizedBox(
            height: 660, // Combined banner area
            width: double.infinity,
            child: Stack(
              children: [
                // On Windows, the floating WebView stays on top of all Flutter content, 
                // covering the UI. We disable the background trailer for Windows specifically 
                // to ensure the Home page remains usable.
                if (_trailerKey != null && !kIsWeb && defaultTargetPlatform != TargetPlatform.windows)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: FittedBox(
                        fit: BoxFit.cover,
                        child: Transform.scale(
                          scale: 1.35,
                          child: SizedBox(
                            width: 1280,
                            height: 720,
                            child: _useWebView && _webController != null
                                ? WebViewWidget(controller: _webController!)
                                : (!_useWebView && _ytController != null
                                      ? YoutubePlayer(
                                          controller: _ytController!,
                                        )
                                      : const SizedBox.shrink()),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 500),
                    child: _isVideoPlaying
                        ? const SizedBox.expand(key: ValueKey('empty_video_bg'))
                        : Hero(
                            key: ValueKey(heroTag),
                            tag: heroTag,
                            child: CachedNetworkImage(
                              httpHeaders: _cachedImageHttpHeaders,
                              imageUrl: imageUrl,
                              width: double.infinity,
                              height: double.infinity,
                              fit: BoxFit.cover,
                              alignment: Alignment.topCenter,
                              placeholder: (context, url) =>
                                  Container(color: Colors.black26),
                              errorWidget: (context, url, error) => Container(
                                color: Colors.black26,
                                child: const Icon(
                                  Icons.broken_image,
                                  size: 50,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height:
                      600, // Extended height upwards by 20% for a longer cinematic fade
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(
                            0xFF0F1014,
                          ), // Always solid at the bottom edge to match section below
                          const Color(0xFF0F1014).withOpacity(
                            bgOpacity,
                          ), // Grounding area for text/buttons
                          const Color(
                            0xFF0F1014,
                          ).withOpacity(0.0), // Fade into the image
                        ],
                        stops: const [
                          0.0,
                          0.35,
                          1.0,
                        ], // Solid base at bottom, fading up
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: AnimatedOpacity(
              opacity: _showContent ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 400),
              child: Container(
                padding: isMobile
                    ? const EdgeInsets.all(16.0)
                    : EdgeInsets.zero,
                decoration: const BoxDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (_logoPath != null)
                      CachedNetworkImage(
                        imageUrl: 'https://image.tmdb.org/t/p/w500$_logoPath',
                        httpHeaders: _cachedImageHttpHeaders,
                        width: 250,
                        height: 100,
                        fit: BoxFit.contain,
                        alignment: Alignment.center,
                      )
                    else
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          height: 1.1,
                        ),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_contentRating.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white54),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _contentRating,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: isMobile ? 12 : 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        if (displayYearText.isNotEmpty)
                          Text(
                            displayYearText,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: isMobile ? 14 : 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        if (voteAverage.isNotEmpty)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.star,
                                color: const Color.fromARGB(255, 255, 255, 255),
                                size: isMobile ? 16 : 18,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '$voteAverage / 10',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: isMobile ? 14 : 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                    if (overview.isNotEmpty) ...[
                      SizedBox(height: isMobile ? 8 : 12),
                      Center(
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: kIsWeb
                                ? MediaQuery.sizeOf(context).width * 0.7
                                : double.infinity,
                          ),
                          child: Text(
                            overview,
                            maxLines: 3,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: isMobile ? 12 : 14,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (!isTvShow && currentProgress >= 1.0) ...[
                      SizedBox(height: isMobile ? 8 : 12),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Watched',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: isMobile ? 11 : 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(width: 8),
                          Icon(
                            Icons.check_circle,
                            color: const Color.fromARGB(255, 255, 255, 255),
                            size: isMobile ? 14 : 16,
                          ),
                        ],
                      ),
                    ],
                    SizedBox(height: isMobile ? 16 : 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: isMobile ? 200 : 240,
                          height: 56,
                          decoration: BoxDecoration(
                            color: (btnBaseColor ?? Colors.white).withOpacity(
                              0.05,
                            ),
                            border: Border.all(
                              color: (btnBaseColor ?? Colors.white).withOpacity(
                                0.15,
                              ),
                            ),
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              foregroundColor: btnBaseColor ?? Colors.white,
                              minimumSize: const Size.fromHeight(56),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                            ),
                            onPressed: () async {
                              _stopTrailerVideo();
                              int resumeSeconds = 0;
                              if (currentProgress > 0 &&
                                  currentProgress < 1.0) {
                                int rTime = isTvShow ? 45 : 120;
                                try {
                                  final mediaId = media['id'];
                                  final mediaType = isTvShow ? 'tv' : 'movie';
                                  final url =
                                      'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey';
                                  final data = await fetchWithCache(url);

                                  if (isTvShow) {
                                    final epUrl =
                                        'https://api.themoviedb.org/3/tv/$mediaId/season/$selectedSeason/episode/$selectedEpisode?api_key=$tmdbApiKey';
                                    try {
                                      final epData = await fetchWithCache(
                                        epUrl,
                                      );
                                      if (epData['runtime'] != null) {
                                        rTime = epData['runtime'];
                                      } else if (data['episode_run_time']
                                              is List &&
                                          data['episode_run_time'].isNotEmpty) {
                                        rTime = data['episode_run_time'][0];
                                      }
                                    } catch (_) {
                                      if (data['episode_run_time'] is List &&
                                          data['episode_run_time'].isNotEmpty) {
                                        rTime = data['episode_run_time'][0];
                                      }
                                    }
                                  } else {
                                    if (data['runtime'] != null) {
                                      rTime = data['runtime'];
                                    }
                                  }
                                } catch (_) {}
                                resumeSeconds = (rTime * 60 * currentProgress)
                                    .toInt();
                              }

                              final String smId =
                                  (media['id']?.toString() ?? '').trim();
                              if (smId.isEmpty) return;

                              final String pLink = isTvShow
                                  ? Uri.https(
                                      'player.videasy.net',
                                      'tv/$smId/$selectedSeason/$selectedEpisode',
                                      {
                                        'color': '1ce783',
                                        'autoPlay': 'true',
                                        'nextEpisode': 'true',
                                        'overlay': 'true',
                                        'progress': resumeSeconds.toString(),
                                      },
                                    ).toString()
                                  : Uri.https(
                                      'player.videasy.net',
                                      'movie/$smId',
                                      {
                                        'color': '1ce783',
                                        'autoPlay': 'true',
                                        'overlay': 'true',
                                        'progress': resumeSeconds.toString(),
                                      },
                                    ).toString();

                              final Map<String, dynamic> cleanMedia = {
                                'id': smId,
                                'title':
                                    (media['title'] ??
                                            media['name'] ??
                                            'Unknown')
                                        .toString(),
                                'media_type':
                                    (media['media_type']?.toString() ??
                                            (isTvShow ? 'tv' : 'movie'))
                                        .toString(),
                                'poster_path': media['poster_path']?.toString(),
                                'backdrop_path': media['backdrop_path']
                                    ?.toString(),
                                'vote_average': media['vote_average'],
                                'overview': media['overview']?.toString(),
                              };

                              ProgressManager.saveProgress(
                                media: cleanMedia,
                                progress: currentProgress == 0
                                    ? 0.05
                                    : currentProgress,
                                season: isTvShow ? selectedSeason : null,
                                episode: isTvShow ? selectedEpisode : null,
                                position: resumeSeconds,
                                isStart: true,
                              );

                              if (!context.mounted) return;
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => VideoPlayerPage(
                                    videoUrl: pLink,
                                    media: cleanMedia,
                                    season: isTvShow ? selectedSeason : null,
                                    episode: isTvShow ? selectedEpisode : null,
                                  ),
                                ),
                              ).then((_) {
                                if (mounted) {
                                  setState(() {
                                    _isVideoPlaying = false;
                                    _showContent = false;
                                  });
                                  _progressController.reset();
                                  _fetchLogo();
                                  widget.onRefresh?.call();
                                }
                              });
                            },
                            icon: const Icon(Icons.play_arrow, size: 24),
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                playButtonText,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(width: 12),
                        Container(
                          width: isMobile ? 130 : 140,
                          height: 56,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.15),
                            ),
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(56),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              side: BorderSide.none,
                            ),
                            onPressed: () {
                              _stopTrailerVideo();
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => MediaDetailsPage(
                                    media: media,
                                    heroTag: heroTag,
                                  ),
                                ),
                              ).then((_) {
                                if (mounted) {
                                  setState(() {
                                    _isVideoPlaying = false;
                                    _showContent = false;
                                  });
                                  _progressController.reset();
                                  _fetchLogo();
                                  widget.onRefresh?.call();
                                }
                              });
                            },
                            icon: const Icon(Icons.list, size: 24),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'Details',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (widget.mediaList.length > 1)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(widget.mediaList.length, (index) {
                  final isActive = index == _currentIndex;
                  return GestureDetector(
                    onTap: () => _goToItem(index),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 10,
                        ),
                        color: Colors.transparent,
                        child: Container(
                          height: 4,
                          width: isActive ? 32 : 8,
                          clipBehavior: Clip.hardEdge,
                          decoration: BoxDecoration(
                            color: Colors.white38,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: isActive
                              ? AnimatedBuilder(
                                  animation: _progressController,
                                  builder: (context, child) {
                                    return Align(
                                      alignment: Alignment.centerLeft,
                                      child: FractionallySizedBox(
                                        widthFactor: _progressController.value,
                                        child: Container(
                                          color: const Color.fromARGB(
                                            255,
                                            255,
                                            255,
                                            255,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                )
                              : null,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
        ],
      ),
    );
  }
}

class HoverableMediaItem extends StatefulWidget {
  final dynamic media;
  final String heroTag;
  final String imageUrl;
  final Function()? onRefreshParent; // New callback

  const HoverableMediaItem({
    super.key,
    required this.media,
    required this.heroTag,
    required this.imageUrl,
    this.onRefreshParent, // Initialize new parameter
  });

  @override
  State<HoverableMediaItem> createState() => _HoverableMediaItemState();
}

class _HoverableMediaItemState extends State<HoverableMediaItem> {
  bool _isHovered = false;
  String _displayYear = '';
  String _contentRating = '';
  String _voteAverage = '';
  String _overview = '';
  String? _internalTitle;
  String? _internalPosterPath;
  bool _detailsFetched = false;
  Map<int, Map<int, double>> _tvProgress = {};
  double _movieProgress = 0.0;

  @override
  void didUpdateWidget(HoverableMediaItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Force re-fetch of progress from Firestore when the parent page refreshes
    _detailsFetched = false;
  }

  @override
  void initState() {
    super.initState();
    _internalTitle = widget.media['title'] ?? widget.media['name'];
    _internalPosterPath = widget.media['poster_path'];
    _calculateInitialYear();
    if (_internalTitle == null || _internalPosterPath == null) {
      _fetchMoreDetails();
    }
  }

  void _calculateInitialYear() {
    final media = widget.media;
    final releaseDateRaw = media['release_date'] ?? media['first_air_date'];
    if (releaseDateRaw != null && releaseDateRaw.toString().length >= 4) {
      _displayYear = releaseDateRaw.toString().substring(0, 4);
    }
  }

  Future<void> _fetchMoreDetails() async {
    if (_detailsFetched) return;
    _detailsFetched = true;

    final media = widget.media;
    final mediaType =
        media['media_type'] ??
        (media['first_air_date'] != null ? 'tv' : 'movie');
    final mediaId = media['id'];

    if (mediaId != null) {
      try {
        final url =
            'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey&append_to_response=content_ratings,release_dates';
        final data = await fetchWithCache(url);
        if (mounted) {
          String cert = '';
          String vote = data['vote_average']?.toString() ?? '';
          String desc = data['overview']?.toString() ?? '';

          if (mediaType == 'movie' &&
              data['release_dates'] != null &&
              data['release_dates']['results'] is List) {
            final results = data['release_dates']['results'] as List;
            for (var r in results) {
              if (r is Map &&
                  r['iso_3166_1'] == 'US' &&
                  r['release_dates'] is List) {
                for (var d in r['release_dates']) {
                  if (d is Map &&
                      d['certification'] != null &&
                      d['certification'].toString().isNotEmpty) {
                    cert = d['certification'].toString();
                    break;
                  }
                }
                break;
              }
            }
          } else if (mediaType == 'tv' &&
              data['content_ratings'] != null &&
              data['content_ratings']['results'] is List) {
            final results = data['content_ratings']['results'] as List;
            for (var r in results) {
              if (r is Map && r['iso_3166_1'] == 'US' && r['rating'] != null) {
                cert = r['rating'].toString();
                break;
              }
            }
          }

          String yearText = _displayYear;
          if (mediaType == 'tv') {
            final firstAir = data['first_air_date']?.toString();
            final lastAir = data['last_air_date']?.toString();
            final status = data['status']?.toString() ?? '';
            final numSeasons = data['number_of_seasons'];

            String startYear = '';
            if (firstAir != null && firstAir.length >= 4) {
              startYear = firstAir.substring(0, 4);
            } else {
              startYear = _displayYear;
            }

            String endYear = '';
            if (lastAir != null && lastAir.length >= 4) {
              endYear = lastAir.substring(0, 4);
            }

            String seasonStr = '';
            if (numSeasons != null && numSeasons > 0) {
              seasonStr = ' • $numSeasons Season${numSeasons == 1 ? '' : 's'}';
            }

            if (startYear.isNotEmpty) {
              if (status == 'Ended' || status == 'Canceled') {
                yearText = (endYear.isNotEmpty && endYear != startYear)
                    ? '$startYear - $endYear$seasonStr'
                    : '$startYear$seasonStr';
              } else {
                yearText = '$startYear - Present$seasonStr';
              }
            } else if (seasonStr.isNotEmpty) {
              yearText = seasonStr.substring(3);
            }
          } else {
            final runtime = data['runtime'];
            if (runtime != null && runtime > 0) {
              final int hrs = runtime ~/ 60;
              final int mins = runtime % 60;
              final runtimeStr = hrs > 0
                  ? ' • ${hrs}h ${mins}m'
                  : ' • ${mins}m';
              yearText = '$_displayYear$runtimeStr';
            }
          }

          setState(() {
            if (cert.isNotEmpty) _contentRating = cert;
            if (vote.isNotEmpty) _voteAverage = vote;
            if (desc.isNotEmpty) _overview = desc;
            _displayYear = yearText;
            _internalTitle ??= data['title'] ?? data['name'];
            _internalPosterPath ??= data['poster_path'];
          });

          // Fetch progress from Firestore
          if (mediaType == 'tv') {
            final showProgress = await ProgressManager.getShowProgress(mediaId);
            if (mounted) {
              setState(() {
                _tvProgress = {};
                for (var prog in showProgress) {
                  final s = prog['season'] as int?;
                  final e = prog['episode'] as int?;
                  if (s != null && e != null) {
                    _tvProgress.putIfAbsent(s, () => {})[e] =
                        (prog['progress'] as num?)?.toDouble() ?? 0.0;
                  }
                }
              });
            }
          } else {
            final savedProgress = await ProgressManager.getProgress(mediaId);
            if (mounted) {
              setState(() {
                _movieProgress =
                    (savedProgress?['progress'] as num?)?.toDouble() ?? 0.0;
              });
            }
          }
        }
      } catch (_) {}
    }
  }

  void _onHover(bool isHovered) {
    setState(() => _isHovered = isHovered);
    if (isHovered) {
      _fetchMoreDetails();
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    final title = _internalTitle ?? media['title'] ?? media['name'] ?? 'Loading...';
    final voteAverageRaw = _voteAverage.isNotEmpty ? _voteAverage : media['vote_average'];
    final voteAverage = voteAverageRaw != null
        ? double.tryParse(voteAverageRaw.toString())?.toStringAsFixed(1) ??
              '0.0'
        : '0.0';
    final overview = _overview.isNotEmpty 
        ? _overview 
        : (media['overview']?.toString() ?? 'No overview available.');
    final watchCount = media['watch_count']?.toString() ?? '';
    
    final posterPath = _internalPosterPath ?? media['poster_path'];
    final displayImageUrl = posterPath != null 
        ? 'https://image.tmdb.org/t/p/w500$posterPath' 
        : widget.imageUrl;
        
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    final mediaType =
        media['media_type'] ??
        (media['first_air_date'] != null ? 'tv' : 'movie');
    final isTvShow = mediaType == 'tv';
    double currentProgress = 0.0;
    int selectedSeason = 1;
    int selectedEpisode = 1;

    if (isTvShow) {
      if (_tvProgress.isNotEmpty) {
        int maxS = _tvProgress.keys.reduce((a, b) => a > b ? a : b);
        if (_tvProgress[maxS]!.isNotEmpty) {
          int maxE = _tvProgress[maxS]!.keys.reduce((a, b) => a > b ? a : b);
          selectedSeason = maxS;
          selectedEpisode = maxE;
          currentProgress = _tvProgress[maxS]![maxE]!;
        }
      }
    } else {
      currentProgress = _movieProgress;
    }

    bool isFullyWatched = !isTvShow && currentProgress >= 1.0;

    return MouseRegion(
      onEnter: isMobile ? null : (_) => _onHover(true),
      onExit: isMobile ? null : (_) => _onHover(false),
      child: GestureDetector(
        onTap: () {
          Navigator.push<bool?>(
            // Specify return type
            context,
            MaterialPageRoute(
              builder: (context) =>
                  MediaDetailsPage(media: media, heroTag: widget.heroTag),
            ),
          ).then((bool? shouldRefresh) {
            if (shouldRefresh == true && widget.onRefreshParent != null) {
              widget.onRefreshParent!(); // Trigger refresh on parent
            }
          });
        }, // Removed async as it's not needed here
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 4.0),
          decoration: BoxDecoration(
            color: _isHovered ? const Color(0xFF1E1F24) : Colors.transparent,
            borderRadius: BorderRadius.circular(8.0),
            border: Border.all(
              color: _isHovered ? Colors.white24 : Colors.transparent,
              width: 1,
            ),
            boxShadow: _isHovered
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ]
                : [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Hero(
                  tag: widget.heroTag,
                  child: CachedNetworkImage( // Use resolved image
                    imageUrl: displayImageUrl,
                    httpHeaders: _cachedImageHttpHeaders,
                    width: 135,
                    fit: BoxFit.cover,
                    placeholder: (context, url) =>
                        Container(width: 135, color: Colors.black26),
                    errorWidget: (context, url, error) => Container(
                      width: 135,
                      color: Colors.black26,
                      child: const Icon(
                        Icons.broken_image,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  width: _isHovered ? 200 : 0,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: 200,
                      maxWidth: 200,
                      child: AnimatedOpacity(
                        opacity: _isHovered ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeIn,
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              if (_contentRating.isNotEmpty ||
                                  _displayYear.isNotEmpty)
                                Row(
                                  children: [
                                    if (_contentRating.isNotEmpty) ...[
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Colors.white54,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          _contentRating,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                    ],
                                    if (_displayYear.isNotEmpty)
                                      Expanded(
                                        child: Text(
                                          _displayYear,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12,
                                          ),
                                          maxLines: 1,
                                          softWrap: false,
                                          overflow: TextOverflow.fade,
                                        ),
                                      ),
                                  ],
                                ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.star,
                                    color: Color.fromARGB(255, 255, 255, 255),
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      '$voteAverage / 10',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.fade,
                                    ),
                                  ),
                                ],
                              ),
                              if (isFullyWatched) ...[
                                const SizedBox(height: 6),
                                const Row(
                                  children: [
                                    Text(
                                      'Watched',
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    SizedBox(width: 4),
                                    Icon(
                                      Icons.check_circle,
                                      color: Color.fromARGB(255, 255, 255, 255),
                                      size: 12,
                                    ),
                                  ],
                                ),
                              ] else if (currentProgress > 0 &&
                                  currentProgress < 1.0) ...[
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Text(
                                      isTvShow
                                          ? 'Resume S$selectedSeason E$selectedEpisode'
                                          : 'Resume',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      maxLines: 1,
                                      softWrap: false,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: LinearProgressIndicator(
                                        value: currentProgress,
                                        backgroundColor: Colors.white24,
                                        valueColor:
                                            const AlwaysStoppedAnimation<Color>(
                                              Color.fromARGB(
                                                255,
                                                255,
                                                255,
                                                255,
                                              ),
                                            ),
                                        minHeight: 4,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                ),
                              ] else ...[
                                const SizedBox(height: 6),
                              ],
                              if (watchCount.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    const Icon(Icons.people, color: Colors.white54, size: 14),
                                    const SizedBox(width: 4),
                                    Text(
                                      '$watchCount watching',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 8),
                              Expanded(
                                child: Text(
                                  overview,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 11,
                                    height: 1.3,
                                  ),
                                  maxLines: 4,
                                  overflow: TextOverflow.fade,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ContinueWatchingMediaItem extends StatefulWidget {
  final dynamic media;
  final String heroTag;
  final VoidCallback? onRemove;
  final Function()? onRefreshParent; // New callback

  const ContinueWatchingMediaItem({
    super.key,
    required this.media,
    required this.heroTag,
    this.onRemove,
    this.onRefreshParent, // Initialize new parameter
  });

  @override
  State<ContinueWatchingMediaItem> createState() => _ContinueWatchingMediaItemState();
}

class _ContinueWatchingMediaItemState extends State<ContinueWatchingMediaItem> {
  String? _title;
  String? _posterPath;
  String? _backdropPath;
  bool _isFetching = false;

  @override
  void initState() {
    super.initState();
    _title = widget.media['title'] ?? widget.media['name'];
    _posterPath = widget.media['poster_path'];
    _backdropPath = widget.media['backdrop_path'];
    
    if (_title == null || _posterPath == null) {
      _fetchMetadata();
    }
  }

  Future<void> _fetchMetadata() async {
    if (_isFetching) return;
    _isFetching = true;
    final id = widget.media['id'];
    final type = widget.media['media_type'] ?? (widget.media['first_air_date'] != null ? 'tv' : 'movie');
    if (id == null) return;
    
    try {
      final url = 'https://api.themoviedb.org/3/$type/$id?api_key=$tmdbApiKey';
      final data = await fetchWithCache(url);
      if (mounted) {
        setState(() {
          _title = data['title'] ?? data['name'];
          _posterPath = data['poster_path'];
          _backdropPath = data['backdrop_path'];
          _isFetching = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isFetching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    final title = _title ?? 'Loading...';
    final backdrop = _backdropPath ?? _posterPath;
    final imageUrl = backdrop != null
        ? 'https://image.tmdb.org/t/p/w500$backdrop'
        : 'https://via.placeholder.com/500x281?text=No+Image';

    final bool isTv = media['media_type'] == 'tv' || media['first_air_date'] != null;
    final mediaType = (media['media_type'] ?? (isTv ? 'tv' : 'movie')).toString();
    final int? season = media['season'] as int?;
    final int? episode = media['episode'] as int?;
    final double progress = (media['progress'] as num?)?.toDouble() ?? 0.0;

    String subtitle = '';
    if (isTv) {
      subtitle = 'S${season ?? 1} E${episode ?? 1}';
    } else {
      final runtime = media['runtime'];
      if (runtime != null && runtime is num) {
        final int hrs = runtime.toInt() ~/ 60;
        final int mins = runtime.toInt() % 60;
        subtitle = 'Movie • ${hrs > 0 ? '${hrs}h ' : ''}${mins}m';
      } else {
        subtitle = 'Movie';
      }
    }

    return GestureDetector(
      onTap: () async {
        // Make async
        final bool? shouldRefresh = await Navigator.push<bool?>(
          // Specify return type
          context,
          MaterialPageRoute(
            builder: (context) =>
                MediaDetailsPage(media: media, heroTag: widget.heroTag),
          ),
        );
        if (shouldRefresh == true && widget.onRefreshParent != null) {
          widget.onRefreshParent!(); // Trigger refresh on parent
        }
      }, // Removed async as it's not needed here
      child: Container(
        width: 280,
        margin: const EdgeInsets.symmetric(horizontal: 4.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8.0),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Hero(
                      tag: widget.heroTag,
                      // Added httpHeaders to CachedNetworkImage
                      child: CachedNetworkImage(
                        imageUrl: imageUrl,
                        fit: BoxFit.cover,
                        placeholder: (context, url) =>
                            Container(color: Colors.black26),
                        errorWidget: (context, url, error) => Container(
                          color: Colors.black26,
                          child: const Icon(
                            Icons.broken_image,
                            color: Colors.white24,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {
                      // Calculate mock resume position
                      final String safeMediaId =
                          (media['id'] ?? '').toString();
                      final int rTime =
                          (media['runtime'] as num?)?.toInt() ??
                          (isTv ? 45 : 120);
                      final int resumeSeconds =
                          (media['position'] as num?)?.toInt() ??
                          (rTime * 60 * progress).toInt();
                      final String videoUrl = isTv
                          ? Uri.https(
                              'player.videasy.net',
                              'tv/$safeMediaId/${season ?? 1}/${episode ?? 1}',
                              {
                                'color': '1ce783',
                                'autoPlay': 'true',
                                'nextEpisode': 'true',
                                'overlay': 'true',
                                'progress': resumeSeconds.toString(),
                              },
                            ).toString()
                          : Uri.https(
                              'player.videasy.net',
                              'movie/$safeMediaId',
                              {
                                'color': '1ce783',
                                'autoPlay': 'true',
                                'overlay': 'true',
                                'progress': resumeSeconds.toString(),
                              },
                            ).toString();

                      final Map<String, dynamic> cleanMedia = {
                        'id': safeMediaId,
                        'title': (media['title'] ?? media['name'] ?? 'Unknown')
                            .toString(),
                        'media_type':
                            (media['media_type']?.toString() ??
                                    (isTv ? 'tv' : 'movie'))
                                .toString(),
                        'poster_path': media['poster_path']?.toString(),
                        'backdrop_path': media['backdrop_path']?.toString(),
                      };

                      Navigator.push<bool?>(
                        // Specify return type
                        context,
                        MaterialPageRoute(
                          builder: (context) => VideoPlayerPage(
                            videoUrl: videoUrl,
                            media: cleanMedia.isNotEmpty ? cleanMedia : null,
                            season: season,
                            episode: episode,
                          ),
                        ),
                      ).then((bool? videoPlayerChanged) {
                        if (videoPlayerChanged == true &&
                            widget.onRefreshParent != null) {
                          widget.onRefreshParent!(); // Trigger refresh on parent
                        }
                      });
                    },
                    child: Center(
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: const Icon(
                          Icons.play_arrow,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 4,
                    decoration: const BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.only(
                        bottomLeft: Radius.circular(8),
                        bottomRight: Radius.circular(8),
                      ),
                    ),
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: progress,
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Color.fromARGB(255, 255, 255, 255),
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    Icons.more_vert,
                    color: Colors.white54,
                    size: 20,
                  ),
                  onSelected: (value) async {
                    if (value == 'remove') {
                      await ProgressManager.deleteProgress(
                        media['id'],
                        mediaType,
                        season: season,
                        episode: episode,
                      );
                      if (widget.onRefreshParent != null) {
                        widget.onRefreshParent!();
                      }
                      if (widget.onRemove != null) widget.onRemove!();
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove from watch history'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class HorizontalMediaList extends StatefulWidget {
  final String categoryTitle;
  final List<dynamic> items;
  final bool showTitle;
  final EdgeInsetsGeometry? listPadding;
  final VoidCallback? onRefresh;
  final String? apiUrl;
  final String? defaultMediaType;

  final Function()? onChildRefresh; // New callback for child item actions
  const HorizontalMediaList({
    super.key,
    required this.categoryTitle,
    required this.items,
    this.apiUrl,
    this.defaultMediaType,
    this.showTitle = true,
    this.listPadding,
    this.onRefresh,
    this.onChildRefresh, // Initialize new parameter
  });

  @override
  State<HorizontalMediaList> createState() => _HorizontalMediaListState();
}

class _HorizontalMediaListState extends State<HorizontalMediaList> {
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
        if (widget.showTitle && widget.categoryTitle.isNotEmpty)
          GestureDetector(
            onTap: widget.categoryTitle == 'Continue Watching'
                ? null
                : () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => FullListPage(
                          title: widget.categoryTitle,
                          items: widget.items,
                          apiUrl: widget.apiUrl,
                          defaultMediaType: widget.defaultMediaType,
                        ),
                      ),
                    ).then((changed) {
                      if (changed == true && widget.onChildRefresh != null) {
                        widget.onChildRefresh!();
                      }
                    });
                  },
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 8.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.categoryTitle,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  if (widget.categoryTitle != 'Continue Watching')
                    const Icon(Icons.chevron_right, color: Colors.white70),
                ],
              ),
            ),
          ),
        MouseRegion(
          onEnter: isMobile ? null : (_) => setState(() => _isHovering = true),
          onExit: isMobile ? null : (_) => setState(() => _isHovering = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: widget.categoryTitle == 'Continue Watching' ? 220 : 200,
            child: Stack(
              children: [
                ListView.builder(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  padding:
                      widget.listPadding ??
                      EdgeInsets.only(
                        left: 12.0,
                        right: widget.categoryTitle == 'Continue Watching'
                            ? 12.0
                            : 212.0,
                      ),
                  itemCount: widget.items.length,
                  itemBuilder: (context, index) {
                    final media = widget.items[index];
                    final heroTag =
                        '${widget.categoryTitle}_${media['media_type']}_${media['id']}_$index';
                    final mediaType =
                        media['media_type'] ??
                        (media['first_air_date'] != null ? 'tv' : 'movie');
                    final posterPath = media['poster_path'];
                    final imageUrl = posterPath != null
                        ? 'https://image.tmdb.org/t/p/w500$posterPath'
                        : 'https://via.placeholder.com/500x750?text=No+Image';

                    if (widget.categoryTitle == 'Continue Watching') {
                      return ContinueWatchingMediaItem(
                        media: media,
                        heroTag: heroTag,
                        onRemove: widget.onRefresh,
                        onRefreshParent: widget.onChildRefresh,
                      );
                    } else if (mediaType == 'movie' || mediaType == 'tv') {
                      // Pass onChildRefresh to HoverableMediaItem
                      return HoverableMediaItem(
                        media: media,
                        heroTag: heroTag,
                        imageUrl: imageUrl,
                        onRefreshParent:
                            widget.onChildRefresh, // Pass the callback
                      );
                    }
                    return const SizedBox.shrink(); // Fallback for unexpected item types
                  },
                ),
                if (!isMobile)
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
                            onPressed: _canScrollLeft
                                ? () => _scroll(-800)
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!isMobile)
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
                            onPressed: _canScrollRight
                                ? () => _scroll(800)
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class MediaCategoryBody extends StatefulWidget {
  final String mediaType;
  final bool isMuted;
  const MediaCategoryBody({
    super.key,
    required this.mediaType,
    required this.isMuted,
  });

  @override
  State<MediaCategoryBody> createState() => _MediaCategoryBodyState();
}

class _MediaCategoryBodyState extends State<MediaCategoryBody>
    with AutomaticKeepAliveClientMixin {
  List<dynamic> trendingList = [];
  List<dynamic> continueWatching = [];
  List<dynamic> allGenres = [];
  List<dynamic> recommendations = [];
  List<dynamic> topRatedList = [];
  List<dynamic> onTheAirList = [];
  int displayedGenresCount = 0;
  bool isLoading = true;
  bool isPaginating = false;
  final ScrollController _scrollController = ScrollController();
  final Set<int> seenMediaIds = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _initialFetch();
  }

  Future<void> _initialFetch() async {
    final trendingUrl = 'https://api.themoviedb.org/3/trending/${widget.mediaType}/day?api_key=$tmdbApiKey';
    bool wasCached = _apiCache.containsKey(trendingUrl);
    
    // Step 1: Immediate load from cache (fast)
    await fetchData(background: false);
    
    // Step 2: Background refresh from network if we started with cached data
    if (mounted && wasCached) {
      await Future.delayed(const Duration(seconds: 1));
      fetchData(background: true);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMoreGenres();
    }
  }

  void _loadMoreGenres() {
    if (isPaginating || displayedGenresCount >= allGenres.length) return;
    setState(() => isPaginating = true);

    // Load the next 5 genres in the background
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          displayedGenresCount = (displayedGenresCount + 5).clamp(
            0,
            allGenres.length,
          );
          isPaginating = false;
        });
      }
    });
  }

  Future<void> fetchData({bool background = false}) async {
    try {
      final trendingUrl =
          'https://api.themoviedb.org/3/trending/${widget.mediaType}/day?api_key=$tmdbApiKey';
      final genreUrl =
          'https://api.themoviedb.org/3/genre/${widget.mediaType}/list?api_key=$tmdbApiKey';
      final topRatedUrl =
          'https://api.themoviedb.org/3/${widget.mediaType}/top_rated?api_key=$tmdbApiKey';
      final onTheAirUrl =
          'https://api.themoviedb.org/3/tv/on_the_air?api_key=$tmdbApiKey';

      if (!background && trendingList.isEmpty) {
        setState(() => isLoading = true);
      }

      final apiResults = await Future.wait([
        fetchWithCache(trendingUrl, forceRefresh: background).catchError((_) => {'results': []}),
        fetchWithCache(genreUrl, forceRefresh: background).catchError((_) => {'genres': []}),
        fetchWithCache(topRatedUrl, forceRefresh: background).catchError((_) => {'results': []}),
        widget.mediaType == 'tv'
            ? fetchWithCache(onTheAirUrl, forceRefresh: background).catchError((_) => {'results': []})
            : Future.value({'results': []}),
      ]);

      final trendingData = apiResults[0];
      final genreData = apiResults[1];
      final topRatedData = apiResults[2];
      final onTheAirData = apiResults[3];

      if (mounted) {
        setState(() {
          final rawTrending = trendingData['results'] as List? ?? [];
          for (var item in rawTrending) {
            if (item is Map) item['media_type'] = widget.mediaType;
          }

          final filtered = rawTrending
              .where((item) => _isReleased(item, strictFilter: true))
              .toList();
          final basicFiltered = rawTrending
              .where((item) => _isReleased(item))
              .toList();

          // Fallback if strict filter is too aggressive for this category
          trendingList = filtered.isNotEmpty
              ? filtered
              : (basicFiltered.isNotEmpty ? basicFiltered : rawTrending);

          final rawTopRated = topRatedData['results'] as List? ?? [];
          for (var item in rawTopRated) {
            if (item is Map) item['media_type'] = widget.mediaType;
          }

          topRatedList = rawTopRated
              .where((item) => _isReleased(item, strictFilter: true))
              .toList();

          if (onTheAirData != null) {
            final rawOnTheAir = onTheAirData['results'] as List? ?? [];
            for (var item in rawOnTheAir) {
              if (item is Map) item['media_type'] = 'tv';
            }

            onTheAirList = rawOnTheAir
                .where((item) => _isReleased(item, strictFilter: true))
                .toList();
          }

          // Mark trending items as seen so they don't repeat in genre lists
          for (var item in trendingList) {
            if (item['id'] != null) seenMediaIds.add(item['id']);
          }
          for (var item in topRatedList) {
            if (item['id'] != null) seenMediaIds.add(item['id']);
          }
          allGenres = genreData['genres'] ?? [];

          ProgressManager.getContinueWatching().then((cw) {
            if (mounted) {
              final filtered = cw
                  .where((i) => i['media_type']?.toString() == widget.mediaType)
                  .toList();
              setState(() => continueWatching = filtered);
              if (filtered.isNotEmpty && (recommendations.isEmpty || background)) {
                _fetchCategoryRecommendations(filtered.first, background: background);
              } else {
                setState(() => recommendations = []);
              }
            }
          });
          if (!background) {
            displayedGenresCount = allGenres.length > 5 ? 5 : allGenres.length;
          isLoading = false;
        }});
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
      debugPrint('Error: $e');
    }
  }

  Future<void> _fetchCategoryRecommendations(Map<String, dynamic> item,
      {bool background = false}) async {
    final id = item['id'];
    try {
      final url =
          'https://api.themoviedb.org/3/${widget.mediaType}/$id/recommendations?api_key=$tmdbApiKey';
      final data = await fetchWithCache(url, forceRefresh: background);
      final List recs = data['results'] as List? ?? [];
      if (mounted) {
        setState(() {
          var filtered = recs
              .where((item) => _isReleased(item, strictFilter: true))
              .toList();
          if (filtered.isEmpty) {
            filtered = recs.where((item) => _isReleased(item)).toList();
          }

          recommendations = filtered.map((item) {
            if (item is Map) item['media_type'] = widget.mediaType;
            return item;
          }).toList();
        });
      }
    } catch (e) {
      debugPrint('Error fetching category recommendations: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color.fromARGB(255, 255, 255, 255),
        ),
      );
    }
    return SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (trendingList.isNotEmpty)
            FeaturedMediaItem(
              mediaList: trendingList.take(5).toList(),
              isMuted: widget.isMuted,
              onRefresh: fetchData,
            ),
          const SizedBox(height: 20),
          HorizontalMediaList(
            categoryTitle: 'Trending Now',
            items: trendingList.length > 5
                ? trendingList.skip(5).toList()
                : trendingList,
            apiUrl:
                'https://api.themoviedb.org/3/trending/${widget.mediaType}/day?api_key=$tmdbApiKey',
              onChildRefresh: () => fetchData(background: true),
          ),
          const SizedBox(height: 16),
          if (continueWatching.isNotEmpty)
            HorizontalMediaList(
              categoryTitle: 'Continue Watching',
              items: continueWatching,
              onRefresh: () => fetchData(),
              onChildRefresh: () => fetchData(background: true),
            ),
          const SizedBox(height: 16),
          if (recommendations.isNotEmpty && continueWatching.isNotEmpty)
            HorizontalMediaList(
              categoryTitle: 'For You',
              items: recommendations,
              apiUrl:
                  'https://api.themoviedb.org/3/${widget.mediaType}/${continueWatching.first['id']}/recommendations?api_key=$tmdbApiKey',
              onChildRefresh: fetchData,
              defaultMediaType: widget.mediaType,
            ),
          const SizedBox(height: 16),
          if (topRatedList.isNotEmpty)
            HorizontalMediaList(
              categoryTitle: 'Top Rated',
              items: topRatedList,
              apiUrl:
                  'https://api.themoviedb.org/3/${widget.mediaType}/top_rated?api_key=$tmdbApiKey',
              onChildRefresh: () => fetchData(background: true),
              defaultMediaType: widget.mediaType,
            ),
          if (widget.mediaType == 'tv' && onTheAirList.isNotEmpty) ...[
            const SizedBox(height: 16),
            HorizontalMediaList(
              categoryTitle: 'On The Air',
              items: onTheAirList,
              apiUrl:
                  'https://api.themoviedb.org/3/tv/on_the_air?api_key=$tmdbApiKey',
              onChildRefresh: () => fetchData(background: true),
              defaultMediaType: 'tv',
            ),
          ],
          const SizedBox(height: 16),
          ...allGenres
              .take(displayedGenresCount)
              .toList()
              .asMap()
              .entries
              .map(
                (entry) => GenreRow(
                  title: entry.value['name'],
                  genreId: entry.value['id'],
                  mediaType: widget.mediaType,
                  index: entry.key,
                  seenMediaIds: seenMediaIds,
                ),
              ),
          if (isPaginating)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32.0),
              child: Center(
                child: CircularProgressIndicator(
                  color: Color.fromARGB(255, 255, 255, 255),
                ),
              ),
            ),
          const SizedBox(height: 32),
          const SizedBox(height: 80), // Padding for bottom nav bar
        ],
      ),
    );
  }
}

class GenreRow extends StatefulWidget {
  final String title;
  final int genreId;
  final String mediaType;
  final int index;
  final Set<int> seenMediaIds;

  const GenreRow({
    super.key,
    required this.title,
    required this.genreId,
    required this.mediaType,
    required this.index,
    required this.seenMediaIds,
  });

  @override
  State<GenreRow> createState() => _GenreRowState();
}

class _GenreRowState extends State<GenreRow> {
  List<dynamic> items = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _initialFetch();
  }

  Future<void> _initialFetch() async {
    final String url = 'https://api.themoviedb.org/3/discover/${widget.mediaType}?api_key=$tmdbApiKey&with_genres=${widget.genreId}';
    bool wasCached = _apiCache.containsKey(url);
    
    await fetchGenreItems(background: false);
    if (mounted && wasCached) {
      fetchGenreItems(background: true);
    }
  }

  Future<void> fetchGenreItems({bool background = false}) async {
    // Stagger API calls based on index to enforce deduplication priority
    // and strictly manage rate-limits to a safe trickle.
    if (!background) {
      await Future.delayed(Duration(milliseconds: (widget.index % 5) * 200));
    }

    try {
      int currentPage = 1;
      int maxPages = 1;
      List<dynamic> deduplicatedItems = [];
      const int minItemsPerRow = 15; // Threshold to ensure the row looks full

      while (deduplicatedItems.length < minItemsPerRow &&
          currentPage <= maxPages) {
        String url =
            'https://api.themoviedb.org/3/discover/${widget.mediaType}?api_key=$tmdbApiKey&with_genres=${widget.genreId}&page=$currentPage';
        if (widget.mediaType == 'movie') {
          url += '&with_runtime.gte=20';
        }

        final data = await fetchWithCache(url, forceRefresh: background);
        maxPages = (data['total_pages'] as num?)?.toInt() ?? 1;

        final List results = data['results'] as List? ?? [];
        if (results.isEmpty) break;

        for (var item in results) {
          if (item is Map) item['media_type'] = widget.mediaType;
          if (!_isReleased(item, strictFilter: true)) continue;
          final int? id = item['id'];
          if (id != null && !widget.seenMediaIds.contains(id)) {
            deduplicatedItems.add(item);
            widget.seenMediaIds.add(id);
          }
          if (deduplicatedItems.length >= 20) {
            break; // Don't over-fetch if we have enough
          }
        }

        currentPage++;
        // Safety break to prevent excessive API calls/bandwidth usage
        if (currentPage > 5) break;
      }

      if (mounted) {
        setState(() {
          items = deduplicatedItems;
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const SizedBox(
        height: 200,
        child: Center(
          child: CircularProgressIndicator(
            color: Color.fromARGB(255, 255, 255, 255),
          ),
        ),
      );
    }
    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: HorizontalMediaList(
        categoryTitle: widget.title,
        items: items,
        apiUrl:
            'https://api.themoviedb.org/3/discover/${widget.mediaType}?api_key=$tmdbApiKey&with_genres=${widget.genreId}${widget.mediaType == 'movie' ? '&with_runtime.gte=20' : ''}',
        defaultMediaType: widget.mediaType,
        onChildRefresh: () => fetchGenreItems(background: true),
      ),
    );
  }
}

class DownloadProgressPainter extends CustomPainter {
  final DownloadStatus status;
  final double progress;
  final Animation<double> rotationAnimation;
  final Color? color;

  DownloadProgressPainter({
    required this.status,
    required this.progress,
    required this.rotationAnimation,
    this.color,
  }) : super(repaint: rotationAnimation);

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final Rect rect = Rect.fromLTWH(0, 0, size.width, size.height);

    if (status == DownloadStatus.requesting) {
      paint.color = color ?? const Color.fromARGB(255, 255, 255, 255);
      final startAngle = rotationAnimation.value * 2 * pi;
      const sweepAngle = pi * 1.5; // 270 degrees
      canvas.drawArc(rect.deflate(1.5), startAngle, sweepAngle, false, paint);
    } else if (status == DownloadStatus.downloading) {
      paint.color = Colors.white.withOpacity(0.2);
      canvas.drawCircle(size.center(Offset.zero), size.width / 2 - 1.5, paint);

      paint.color = color ?? const Color.fromARGB(255, 255, 255, 255);
      final sweepAngle = 2 * pi * progress;
      canvas.drawArc(rect.deflate(1.5), -pi / 2, sweepAngle, false, paint);
    } else if (status == DownloadStatus.done) {
      paint.color = const Color(0xFF1CE783);
      canvas.drawCircle(size.center(Offset.zero), size.width / 2 - 1.5, paint);
    } else if (status == DownloadStatus.failed) {
      paint.color = Colors.redAccent;
      canvas.drawCircle(size.center(Offset.zero), size.width / 2 - 1.5, paint);
    }
  }

  @override
  bool shouldRepaint(covariant DownloadProgressPainter oldDelegate) => true;
}

// --- Custom Notification System ---
class AppNotification {
  static void show(BuildContext context, String message, {Color? color}) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _AppNotificationWidget(
        message: message,
        color: color,
        onDismiss: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
  }
}

class _AppNotificationWidget extends StatefulWidget {
  final String message;
  final Color? color;
  final VoidCallback onDismiss;

  const _AppNotificationWidget({
    required this.message,
    this.color,
    required this.onDismiss,
  });

  @override
  State<_AppNotificationWidget> createState() => _AppNotificationWidgetState();
}

class _AppNotificationWidgetState extends State<_AppNotificationWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    _controller.forward();
    _dismissTimer = Timer(const Duration(seconds: 3), () => _hide());
  }

  void _hide() {
    if (mounted) {
      _controller.reverse().then((_) => widget.onDismiss());
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 60,
      left: 20,
      right: 20,
      child: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: SlideTransition(
            position: _slideAnimation,
            child: Dismissible(
              key: UniqueKey(),
              direction: DismissDirection.down,
              onDismissed: (_) => widget.onDismiss(),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Material(
                  color: Colors.transparent,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(40.0),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 40.0, sigmaY: 40.0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withOpacity(0.15),
                              Colors.white.withOpacity(0.03),
                              Colors.white.withOpacity(0.03),
                              Colors.white.withOpacity(0.1),
                            ],
                            stops: const [0.0, 0.2, 0.8, 1.0],
                          ),
                          borderRadius: BorderRadius.circular(40.0),
                          border: Border.all(
                            color:
                                widget.color?.withOpacity(0.3) ??
                                Colors.white.withOpacity(0.15),
                            width: 1.0,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              widget.color == Colors.red
                                  ? Icons.error_outline
                                  : Icons.info_outline,
                              color: widget.color ?? Colors.white,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Text(
                                widget.message,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MediaDetailsPage extends StatefulWidget {
  final dynamic media;
  final String heroTag;

  const MediaDetailsPage({
    super.key,
    required this.media,
    required this.heroTag,
  });

  @override
  State<MediaDetailsPage> createState() => _MediaDetailsPageState();
}

class _MediaDetailsPageState extends State<MediaDetailsPage>
    with TickerProviderStateMixin {
  bool isLoadingDetails = true;
  Map<dynamic, dynamic>? detailedMedia;
  String? _trailerKey;
  int _selectedSeason = 1;
  int _selectedEpisode = 1;
  int? _visualSelectedEpisode;
  Color? _dominantColor;
  bool _isColorExtracted = false;
  bool _hasMadeChanges = false;
  bool _showContent = false;
  String? _logoPath;
  String _contentRating = '';
  bool _isCamRelease = false;

  bool _isMovieCompleted = false; // New: For movie completion status
  bool _isSeriesCompleted = false; // New: For TV series completion status
  bool _isDownloadActive = false; // State for download button expansion
  String? _selectedResolution;
  bool _isOnWatchlist = false;
  int _refreshKey = 0;

  final Map<int, List<dynamic>> _seasonEpisodesData =
      {}; // Cache for season episodes
  double _movieProgress = 0.0;
  // ignore: prefer_final_fields
  Map<int, Map<int, double>> _tvProgress = {};

  DownloadTask? _task;
  late AnimationController _spinnerController;

  @override
  void initState() {
    super.initState();
    _spinnerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _updateTask();
    _initializePage();
  }

  void _initializePage() async {
    fetchDetails();
    _checkWatchlistStatus();
  }

  @override
  void dispose() {
    _task?.removeListener(_onDownloadUpdate);
    _spinnerController.dispose();
    super.dispose();
  }

  // This method is called when the download task updates.
  void _updateTask() {
    final mediaId = widget.media['id']?.toString();
    if (mediaId == null) return;
    final newTask = DownloadManager().getTask(mediaId);
    if (newTask != _task) {
      _task?.removeListener(_onDownloadUpdate);
      _task = newTask;
      _task?.addListener(_onDownloadUpdate);
    }
  }

  void _onDownloadUpdate() {
    if (mounted) {
      // If a download completes or fails, we might want to refresh the UI.
      if (_task?.status == DownloadStatus.done) {}
      setState(() {});
    }
  }

  void _checkIfReady() {
    if (!isLoadingDetails && _isColorExtracted && !_showContent) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) {
          setState(() {
            _showContent = true;
          });
        }
      });
    }
  }

  Future<void> _checkWatchlistStatus() async {
    final String mediaId = (widget.media['id'] ?? '').toString();
    if (mediaId.isEmpty) return;
    final isOn = await WatchlistManager.isOnWatchlist(mediaId);
    if (mounted) {
      setState(() {
        _isOnWatchlist = isOn;
      });
    }
  }

  // ignore: unused_element
  Future<void> _toggleWatchlist() async {
    final String mediaId = (widget.media['id'] ?? '').toString();
    if (mediaId.isEmpty) return;
    if (_isOnWatchlist) {
      await WatchlistManager.removeFromWatchlist(mediaId);
    } else {
      await WatchlistManager.addToWatchlist(detailedMedia ?? widget.media);
    }
    _checkWatchlistStatus();
  }

  Future<void> _handleDelete() async {
    final mediaId = widget.media['id']?.toString();
    if (mediaId == null) return;

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1F24),
        title: const Text(
          'Delete Download',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Are you sure you want to delete this download?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      // Reconstruct file path to delete it
      final title =
          widget.media['title']?.toString() ??
          widget.media['name']?.toString() ??
          'Unknown';
      final docsDir = await getApplicationDocumentsDirectory();
      final finalFileName = '$mediaId+$title.mp4'
          .replaceAll(RegExp(r'[^\w\s\.-]+'), '')
          .replaceAll(' ', '_');
      final finalPath = '${docsDir.path}/LunarDrift/Movies/$finalFileName';
      final file = File(finalPath);

      if (await file.exists()) {
        await file.delete();
      }
      await DownloadManager().removeDownloadFromCache(mediaId);
      _updateTask(); // This will refresh the state
      if (mounted) {
        // No need to pop here, as this is a local action.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Download deleted.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  Future<void> fetchDetails() async {
    final mediaType =
        widget.media['media_type']?.toString() ??
        (widget.media['first_air_date'] != null ? 'tv' : 'movie');
    final String mediaId = (widget.media['id'] ?? '').toString();
    if (mediaId.isEmpty) {
      if (mounted) {
        setState(() {
          isLoadingDetails = false;
          _isColorExtracted = true;
        });
        _checkIfReady();
      }
      return;
    }

    final url = Uri.parse(
      'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey&append_to_response=credits,reviews,videos,release_dates,images,content_ratings,recommendations&include_image_language=en,null',
    );
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        data['media_type'] = mediaType;
        if (mounted) {
         
          if (mediaType == 'tv') {
            final showProgress = await ProgressManager.getShowProgress(mediaId);
            if (mounted) {
              setState(() {
                _refreshKey++;
                _tvProgress = {}; // Reset for a clean refresh
                for (var prog in showProgress) {
                  final s = prog['season'] as int?;
                  final e = prog['episode'] as int?;
                  if (s != null && e != null) {
                    _tvProgress.putIfAbsent(s, () => <int, double>{})[e] =
                        (prog['progress'] as num?)?.toDouble() ?? 0.0;
                  }
                }

                // Determine if the entire series is completed
                bool allEpisodesCompleted = true;
                final seasonsList = data['seasons'] as List?;
                if (seasonsList != null) {
                  for (var s in seasonsList) {
                    if (s is Map) {
                      final seasonNumber = (s['season_number'] ?? 0) as int;
                      if (seasonNumber == 0) continue; 

                      // Calculate count directly from seasons metadata if available
                      final int airedEpisodeCount = s['episode_count'] ?? 0;
                      if (airedEpisodeCount == 0) {
                        continue;
                      }

                      for (int i = 1; i <= airedEpisodeCount; i++) {
                        final episodeProgress =
                            _tvProgress[seasonNumber]?[i] ?? 0.0;
                        if (episodeProgress < 0.9) {
                          // Using 0.9 as threshold for completed
                          allEpisodesCompleted = false;
                          break;
                        }
                      }
                    }
                    if (!allEpisodesCompleted) {
                      break; // If any season is not complete, break outer loop
                    }
                  }
                }
                _isSeriesCompleted = allEpisodesCompleted;
              });
            }
          } else {
            // Fetch single movie progress
            final savedProgress = await ProgressManager.getProgress(mediaId);
            if (mounted) {
              setState(() {
                _movieProgress =
                    (savedProgress?['progress'] as num?)?.toDouble() ?? 0.0;
                _isMovieCompleted =
                    _movieProgress >= 0.9; 
              });
            }
          }
        }

        String cert = '';
        if (mediaType == 'movie' &&
            data['release_dates'] != null &&
            data['release_dates']['results'] is List) {
          final results = data['release_dates']['results'] as List;
          for (var r in results) {
            if (r is Map &&
                r['iso_3166_1'] == 'US' &&
                r['release_dates'] is List) {
              for (var d in r['release_dates']) {
                if (d is Map &&
                    d['certification'] != null &&
                    d['certification'].toString().isNotEmpty) {
                  cert = d['certification'].toString();
                  break;
                }
              }
              break;
            }
          }
        } else if (mediaType == 'tv' &&
            data['content_ratings'] != null &&
            data['content_ratings']['results'] is List) {
          final results = data['content_ratings']['results'] as List;
          for (var r in results) {
            if (r is Map && r['iso_3166_1'] == 'US' && r['rating'] != null) {
              cert = r['rating'].toString();
              break;
            }
          }
        }

        bool isCam = false;
        // Parse the US release dates to determine if the latest current release is strictly Theatrical (Types 2 or 3)
        if (mediaType == 'movie' &&
            data['release_dates'] != null &&
            data['release_dates']['results'] is List) {
          bool isOlderThanOneYear = false;
          if (data['release_date'] != null &&
              data['release_date'].toString().isNotEmpty) {
            try {
              final mainRelease = DateTime.parse(
                data['release_date'].toString(),
              );
              if (DateTime.now().difference(mainRelease).inDays > 365) {
                isOlderThanOneYear = true;
              }
            } catch (_) {}
          }

          if (!isOlderThanOneYear) {
            final results = data['release_dates']['results'] as List;
            for (var r in results) {
              if (r is Map && r['iso_3166_1'] == 'US') {
                if (r['release_dates'] is List) {
                  final dates = r['release_dates'] as List;
                  final now = DateTime.now();
                  List<Map<String, dynamic>> pastReleases = [];

                  for (var d in dates) {
                    if (d is Map && d['release_date'] != null) {
                      final date = DateTime.tryParse(d['release_date']);
                      // Only consider release dates that have already occurred
                      if (date != null && date.isBefore(now)) {
                        pastReleases.add({
                          'date': date,
                          'type': d['type'] as int? ?? 0,
                        });
                      }
                    }
                  }

                  if (pastReleases.isNotEmpty) {
                    // Sort chronologically by date
                    pastReleases.sort(
                      (a, b) => (a['date'] as DateTime).compareTo(
                        b['date'] as DateTime,
                      ),
                    );
                    final latestType = pastReleases.last['type'] as int;

                    if (latestType == 2 || latestType == 3) {
                      if (pastReleases.length == 1) {
                        isCam = true;
                      } else {
                        final previousType =
                            pastReleases[pastReleases.length - 2]['type']
                                as int;
                        // Type 1 is Premiere. Types 2 and 3 are Limited/Theatrical.
                        if (previousType == 1 ||
                            previousType == 2 ||
                            previousType == 3) {
                          isCam = true;
                        }
                      }
                    }
                  }
                }
                break;
              }
            }
          }
        }

        String? extractedLogo;
        if (data['images'] != null && data['images']['logos'] is List) {
          final logos = data['images']['logos'] as List;
          final validLogos = logos
              .where(
                (l) =>
                    l is Map &&
                    !(l['file_path']?.toString().toLowerCase().endsWith(
                          '.svg',
                        ) ??
                        false),
              )
              .toList();
          if (validLogos.isNotEmpty) {
            validLogos.sort((a, b) {
              final double voteA =
                  double.tryParse(a['vote_average']?.toString() ?? '0') ?? 0.0;
              final double voteB =
                  double.tryParse(b['vote_average']?.toString() ?? '0') ?? 0.0;
              return voteB.compareTo(voteA);
            });
            final enLogo = validLogos.firstWhere(
              (l) => l['iso_639_1'] == 'en',
              orElse: () => validLogos.first,
            );
            extractedLogo = enLogo['file_path'];
          }
        }

        if (mounted) {
          setState(() {
            detailedMedia = data;
            isLoadingDetails = false;
            _isCamRelease = isCam;
            _logoPath = extractedLogo;
            _contentRating = cert;

            // Auto-select the most recent or next episode for TV Shows
            if (mediaType == 'tv' && _tvProgress.isNotEmpty) {
              int maxS = _tvProgress.keys.reduce((a, b) => a > b ? a : b);
              if (_tvProgress[maxS]!.isNotEmpty) {
                int maxE = _tvProgress[maxS]!.keys.reduce(
                  (a, b) => a > b ? a : b,
                );
                _selectedSeason = maxS;
                _selectedEpisode = maxE;

                if (_tvProgress[maxS]![maxE]! >= 1.0) {
                  int epCount = _getEpisodeCountForSeason(maxS);
                  if (maxE < epCount) {
                    _selectedEpisode = maxE + 1;
                  } else {
                    final availableSeasons =
                        (data['seasons'] as List?)
                            ?.whereType<Map>()
                            .map((s) => (s['season_number'] ?? 0) as int)
                            .where((n) => n > 0)
                            .toList() ??
                        [];
                    if (availableSeasons.contains(maxS + 1)) {
                      _selectedSeason = maxS + 1;
                      _selectedEpisode = 1;
                    }
                  }
                }
              }
            }
          });

          _checkIfReady();

          if (extractedLogo != null) {
            _extractDominantColor(
              'https://image.tmdb.org/t/p/w500$extractedLogo',
            );
          } else {
            final posterPath = data['poster_path']?.toString();
            if (posterPath != null) {
              _extractDominantColor(
                'https://image.tmdb.org/t/p/w300$posterPath',
              );
            } else {
              if (mounted) {
                setState(() => _isColorExtracted = true);
                _checkIfReady();
              }
            }
          }

          if (mediaType == 'tv') {
            fetchSeasonDetails(_selectedSeason);
          }

          final videosData = data['videos'] is Map
              ? data['videos'] as Map
              : null;
          final videosList = videosData != null && videosData['results'] is List
              ? videosData['results'] as List
              : [];
          for (var v in videosList) {
            if (v is Map && v['type'] == 'Trailer' && v['site'] == 'YouTube') {
              _trailerKey = v['key'];
              break;
            }
          }
        }
      } else {
        if (mounted) {
          setState(() {
            isLoadingDetails = false;
            _isColorExtracted = true;
          });
          _checkIfReady();
        }
      }
    } catch (e) {
      debugPrint('Error fetching details: $e');
      if (mounted) {
        setState(() {
          isLoadingDetails = false;
          _isColorExtracted = true;
        });
        _checkIfReady();
      }
    }
  }

  Future<void> _extractDominantColor(String imageUrl) async {
    try {
      final colorScheme = await ColorScheme.fromImageProvider(
        provider: CachedNetworkImageProvider(imageUrl),
        brightness: Brightness.dark,
      );

      if (mounted) {
        setState(() {
          _dominantColor = colorScheme.primary;
          _isColorExtracted = true;
        });
        _checkIfReady();
      }
    } catch (e) {
      debugPrint('Error extracting color: $e');
      if (mounted) {
        setState(() => _isColorExtracted = true);
        _checkIfReady();
      }
    }
  }

  Future<void> fetchSeasonDetails(int seasonNumber) async {
    if (_seasonEpisodesData.containsKey(seasonNumber)) return;
    final mediaId = widget.media['id'];
    final url =
        'https://api.themoviedb.org/3/tv/$mediaId/season/$seasonNumber?api_key=$tmdbApiKey';
    try {
      final data = await fetchWithCache(url);
      if (mounted) {
        setState(() {
          _seasonEpisodesData[seasonNumber] = data['episodes'] ?? [];
        });
      }
    } catch (e) {
      debugPrint('Error fetching season details: $e');
    }
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '';
    try {
      final DateTime d = DateTime.parse(dateStr);
      const months = [
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December',
      ];
      return '${months[d.month - 1]} ${d.day}, ${d.year}';
    } catch (e) {
      return dateStr;
    }
  }

  String _formatCurrency(num? amount) {
    if (amount == null || amount <= 0) return '';
    String s = amount.toStringAsFixed(0);
    String result = '';
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) result += ',';
      result += s[i];
    }
    return '\$$result';
  }

  int _getEpisodeCountForSeason(int season) {
    if (_seasonEpisodesData.containsKey(season)) {
      final epList = _seasonEpisodesData[season]!;
      int airedCount = 0;
      for (var epData in epList) {
        if (epData is! Map) continue;
        final airDateStr = epData['air_date']?.toString();
        if (airDateStr != null && airDateStr.trim().isNotEmpty) {
          try {
            final airDate = DateTime.parse(airDateStr);
            if (!airDate.isAfter(DateTime.now())) airedCount++;
          } catch (_) {
            airedCount++;
          }
        } else {
          final overview = epData['overview']?.toString();
          if (overview != null && overview.trim().isNotEmpty) airedCount++;
        }
      }
      if (airedCount > 0) return airedCount;
    }

    if (detailedMedia == null || detailedMedia!['seasons'] is! List) return 1;
    final seasonsList = detailedMedia!['seasons'] as List;
    final currentSeasonMap = seasonsList.whereType<Map>().firstWhere(
      (s) => s['season_number'] == season,
      orElse: () => <dynamic, dynamic>{},
    );
    return (currentSeasonMap.isNotEmpty &&
            currentSeasonMap['episode_count'] != null)
        ? (currentSeasonMap['episode_count'] as int)
        : 1;
  }

  double _getEpisodeProgress(int season, int episode) {
    return _tvProgress[season]?[episode] ?? 0.0;
  }

  double _getSeasonProgress(int season, int totalEpisodes) {
    if (!_tvProgress.containsKey(season) || totalEpisodes == 0) return 0.0;
    double totalProgress = 0.0;
    for (int i = 1; i <= totalEpisodes; i++) {
      totalProgress += _getEpisodeProgress(season, i);
    }
    return totalProgress / totalEpisodes;
  }

  // ignore: unused_element
  Widget _buildProgressIndicator(double progress) {
    if (progress >= 1.0) {
      return const Icon(
        Icons.check_circle,
        color: Color.fromARGB(255, 255, 255, 255),
        size: 16,
      );
    } else if (progress > 0.0) {
      return SizedBox(
        width: 24,
        height: 4,
        child: LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.white24,
          valueColor: const AlwaysStoppedAnimation<Color>(
            Color.fromARGB(255, 255, 255, 255),
          ),
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildCastMemberItem(dynamic actor) {
    if (actor == null || actor is! Map) return const SizedBox.shrink();
    bool isHovered = false;
    final isWeb = kIsWeb;
    final size = isWeb ? 80.0 : 70.0;

    final profilePath = actor['profile_path']?.toString();
    final actorImageUrl = profilePath != null
        ? 'https://image.tmdb.org/t/p/w200$profilePath'
        : 'https://via.placeholder.com/200x300?text=No+Image';
    final actorName = actor['name']?.toString() ?? 'Unknown';
    final characterName = actor['character']?.toString() ?? '';
    final actorId = actor['id'];

    return StatefulBuilder(
      builder: (context, setItemState) {
        return MouseRegion(
          onEnter: (_) => setItemState(() => isHovered = true),
          onExit: (_) => setItemState(() => isHovered = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () {
              if (actorId != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ActorDetailsPage(
                      actorId: actorId,
                      actorName: actorName,
                    ),
                  ),
                );
              }
            },
            child: Container(
              width: isWeb ? 100 : 90,
              margin: isWeb
                  ? EdgeInsets.zero
                  : const EdgeInsets.only(right: 12.0),
              padding: const EdgeInsets.only(
                top: 10.0,
              ), // Padding to accommodate the scale-up effect
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  AnimatedScale(
                    scale: isHovered ? 1.1 : 1.0,
                    duration: const Duration(milliseconds: 200),
                    child: ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: actorImageUrl,
                        httpHeaders: _cachedImageHttpHeaders,
                        width: size,
                        height: size,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          width: size,
                          height: size,
                          color: Colors.white24,
                        ),
                        errorWidget: (context, url, error) => Container(
                          width: size,
                          height: size,
                          color: Colors.white24,
                          child: const Icon(
                            Icons.person,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    actorName,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isWeb ? 13 : 12,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (characterName.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      characterName,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(String label, String value) {
    if (value.isEmpty || value == 'N/A') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white54,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayButton(int mainResumeSeconds) {
    final isTvShow = widget.media['media_type'] == 'tv';
    final sourceMedia = detailedMedia ?? widget.media;
    final details = detailedMedia ?? {};
    final epRunTimeList = details['episode_run_time'] is List
        ? details['episode_run_time'] as List
        : null;
    final epRunTimeNum = details['episode_run_time'] is num
        ? details['episode_run_time'] as num
        : null;
    final runtimeRaw =
        details['runtime'] ??
        (epRunTimeList != null && epRunTimeList.isNotEmpty
            ? epRunTimeList.first
            : epRunTimeNum);
    int? runtimeInt = runtimeRaw is num ? runtimeRaw.toInt() : null;

    double currentProgress = isTvShow
        ? _getEpisodeProgress(_selectedSeason, _selectedEpisode)
        : _movieProgress;

    final String colorHex = _dominantColor != null
        ? (_dominantColor!.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')
        : '1ce783';
    final Color? playBtnColor = (!isTvShow && _isCamRelease)
        ? Colors.red
        : _dominantColor;
    final String smId = (widget.media['id']?.toString() ?? '').trim();

    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: (playBtnColor ?? Colors.white).withOpacity(0.05),
        border: Border.all(
          color: (playBtnColor ?? Colors.white).withOpacity(0.15),
        ),
        borderRadius: BorderRadius.circular(28),
      ),
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: playBtnColor ?? Colors.white,
          minimumSize: const Size.fromHeight(56),
          padding: const EdgeInsets.symmetric(horizontal: 24),
        ),
        onPressed: () {
          final String placeholderLink = isTvShow
              ? Uri.https(
                  'player.videasy.net',
                  'tv/$smId/$_selectedSeason/$_selectedEpisode',
                  {
                    'color': colorHex,
                    'autoPlay': 'true',
                    'nextEpisode': 'true',
                    'overlay': 'true',
                    'progress': mainResumeSeconds.toString(),
                  },
                ).toString()
              : Uri.https(
                  'player.videasy.net',
                  'movie/$smId',
                  {
                    'color': colorHex,
                    'autoPlay': 'true',
                    'overlay': 'true',
                    'progress': mainResumeSeconds.toString(),
                  },
                ).toString();

          final Map<String, dynamic> cleanMedia = {
            'id': smId,
            'title': (sourceMedia['title'] ?? sourceMedia['name'] ?? 'Unknown')
                .toString(),
            'media_type':
                (sourceMedia['media_type']?.toString() ??
                        (isTvShow ? 'tv' : 'movie'))
                    .toString(),
            'poster_path': sourceMedia['poster_path']?.toString(),
            'backdrop_path': sourceMedia['backdrop_path']?.toString(),
                'vote_average': sourceMedia['vote_average'],
                'overview': sourceMedia['overview']?.toString(),
          };

          // Save initial progress when clicking play
          ProgressManager.saveProgress(
            media: cleanMedia,
            progress: currentProgress == 0 ? 0.05 : currentProgress,
            season: isTvShow ? _selectedSeason : null,
            episode: isTvShow ? _selectedEpisode : null,
            position: mainResumeSeconds,
            runtime: runtimeInt,
            isStart: true,
          );

          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => VideoPlayerPage(
                videoUrl: placeholderLink,
                media: cleanMedia,
                season: isTvShow ? _selectedSeason : null,
                episode: isTvShow ? _selectedEpisode : null,
              ),
            ),
          ).then((videoPlayerChanged) {
            if (mounted) {
              if (videoPlayerChanged == true) {
                setState(() => _hasMadeChanges = true);
              }
              fetchDetails();
            }
          });
        },
        icon: const Icon(Icons.play_arrow, size: 24),
        label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            isTvShow
                ? ((currentProgress > 0 && currentProgress < 1.0)
                      ? 'Resume S$_selectedSeason E$_selectedEpisode'
                      : 'Play S$_selectedSeason E$_selectedEpisode')
                : ((currentProgress > 0 && currentProgress < 1.0)
                      ? (_isCamRelease ? 'Resume (Cam)' : 'Resume')
                      : (_isCamRelease ? 'Play (Cam)' : 'Play')),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Widget _buildResolutionButton(
    String resolution,
    String label,
    String? posterPath,
    String? logoPath,
    String? backdropPath,
    String? overview,
  ) {
    final isSelected = _selectedResolution == resolution;
    return InkWell(
      onTap: () {
        // Set state to give visual feedback of selection
        setState(() => _selectedResolution = resolution);
        final releaseDateRaw =
            widget.media['release_date'] ?? widget.media['first_air_date'];
        final releaseYear = (releaseDateRaw?.toString() ?? '').length >= 4
            ? releaseDateRaw.toString().substring(0, 4)
            : '';
        // Initiate the download via the manager
        DownloadManager().startDownload(
          mediaId: widget.media['id'].toString(),
          title:
              widget.media['title']?.toString() ??
              widget.media['name']?.toString() ??
              'Unknown',
          year: releaseYear,
          resolution: resolution,
          mediaType: widget.media['media_type']?.toString() ?? 'movie',
          posterPath: posterPath,
        );
        // After starting, update the task listener and collapse the UI.
        setState(() {
          _isDownloadActive = false;
          _updateTask();
        });
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isSelected ? Colors.white : Colors.white38),
        ),
        child: Text(
          resolution,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadCollapsed() {
    final status = _task?.status ?? DownloadStatus.none;
    final progress = _task?.progress ?? 0.0;
    final isDownloaded = status == DownloadStatus.done;

    Widget iconChild;

    if (isDownloaded) {
      iconChild = const Icon(
        Icons.delete_outline,
        color: Colors.white,
        size: 24,
      );
    } else {
      switch (status) {
        case DownloadStatus.requesting:
          iconChild = const SizedBox.shrink(); // Spinner is painted outside
          break;
        case DownloadStatus.downloading:
          iconChild = Text(
            '${(progress * 100).floor()}%',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          );
          break;
        case DownloadStatus.done:
          // This case is handled by isDownloaded, but kept for safety.
          iconChild = const Icon(
            Icons.check,
            color: Color.fromARGB(255, 255, 255, 255),
            size: 24,
          );
          break;
        case DownloadStatus.failed:
          iconChild = const Icon(
            Icons.close,
            color: Colors.redAccent,
            size: 28,
          );
          break;
        case DownloadStatus.none:
        // ignore: unreachable_switch_default
        default:
          iconChild = const Icon(Icons.download, size: 24);
          break;
      }
    }

    return SizedBox(
      key: const ValueKey('download_collapsed'),
      width: 56,
      height: 56,
      child: CustomPaint(
        painter: DownloadProgressPainter(
          status: status,
          progress: progress,
          rotationAnimation: _spinnerController,
          color: _dominantColor,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            border: Border.all(color: Colors.white.withOpacity(0.15)),
            shape: BoxShape.circle,
          ),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              padding: EdgeInsets.zero,
              side: BorderSide.none,
              shape: const CircleBorder(),
            ),
            onPressed: () {
              if (isDownloaded) {
                _handleDelete();
              } else if (status == DownloadStatus.none ||
                  status == DownloadStatus.failed) {
                setState(() => _isDownloadActive = true);
              } else if (status == DownloadStatus.downloading ||
                  status == DownloadStatus.requesting) {
                DownloadManager().cancelDownload(widget.media['id'].toString());
              }
            },
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Align(
                key: ValueKey(status),
                alignment: Alignment.center,
                child: iconChild,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadExpanded(
    String? posterPath,
    String? logoPath,
    String? backdropPath,
    String? overview,
  ) {
    return Container(
      key: const ValueKey('download_expanded'),
      height: 56,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withOpacity(0.15)),
      ),
      child: OverflowBox(
        maxWidth: double.infinity,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4.0),
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => setState(() {
                    _isDownloadActive = false;
                    _selectedResolution = null;
                  }),
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(Icons.close, color: Colors.white70),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildResolutionButton(
                    '480p',
                    'SD',
                    posterPath,
                    logoPath,
                    backdropPath,
                    overview,
                  ),
                  const SizedBox(width: 8),
                  _buildResolutionButton(
                    '720p',
                    'HD',
                    posterPath,
                    logoPath,
                    backdropPath,
                    overview,
                  ),
                  const SizedBox(width: 8),
                  _buildResolutionButton(
                    '1080p',
                    'FHD',
                    posterPath,
                    logoPath,
                    backdropPath,
                    overview,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShareButton() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: Colors.white.withOpacity(0.15)),
        shape: BoxShape.circle,
      ),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          padding: EdgeInsets.zero,
          side: BorderSide.none,
          shape: const CircleBorder(),
        ),
        onPressed: () {
          final mediaId = widget.media['id'];
          final isTv = widget.media['media_type'] == 'tv' || widget.media['first_air_date'] != null;
          final shareUrl = 'https://www.themoviedb.org/${isTv ? "tv" : "movie"}/$mediaId';
          Clipboard.setData(ClipboardData(text: shareUrl));
          AppNotification.show(context, 'Link copied to clipboard!', color: Colors.green);
        },
        child: const Icon(Icons.share_outlined, size: 24),
      ),
    );
  }

  Widget _buildTrailerButton() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        border: Border.all(color: Colors.white.withOpacity(0.15)),
        shape: BoxShape.circle,
      ),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          padding: EdgeInsets.zero,
          side: BorderSide.none,
          shape: const CircleBorder(),
        ),
        onPressed: () {
          if (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.iOS ||
                  defaultTargetPlatform == TargetPlatform.android)) {
            Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    FullscreenTrailerPage(trailerKey: _trailerKey!),
                transitionsBuilder:
                    (context, animation, secondaryAnimation, child) {
                      return FadeTransition(opacity: animation, child: child);
                    },
              ),
            );
          } else {
            showDialog(
              context: context,
              builder: (context) =>
                  TrailerPlayerDialog(trailerKey: _trailerKey!),
            );
          }
        },
        child: const Icon(Icons.movie_creation_outlined, size: 24),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isDesktopOrWeb = kIsWeb || 
        defaultTargetPlatform == TargetPlatform.windows || 
        defaultTargetPlatform == TargetPlatform.linux || 
        defaultTargetPlatform == TargetPlatform.macOS;

    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final sourceMedia = detailedMedia ?? widget.media;

    final title =
        sourceMedia['title']?.toString() ??
        sourceMedia['name']?.toString() ??
        'Unknown';

    // Basic details from passed search/trending context
    final overview =
        sourceMedia['overview']?.toString() ?? 'No overview available.';
    final backdropPath = sourceMedia['backdrop_path']?.toString();
    final posterPath = sourceMedia['poster_path']?.toString();
    final releaseDateRaw =
        sourceMedia['release_date'] ?? sourceMedia['first_air_date'];
    final releaseDate = releaseDateRaw?.toString() ?? '';
    final releaseYear = releaseDate.length >= 4
        ? releaseDate.substring(0, 4)
        : 'N/A';
    final voteAverageRaw = sourceMedia['vote_average'];
    final voteAverage = voteAverageRaw != null
        ? double.tryParse(voteAverageRaw.toString())?.toStringAsFixed(1) ??
              'N/A'
        : 'N/A';

    final bool isTvShow =
        sourceMedia['media_type'] == 'tv' ||
        sourceMedia['first_air_date'] != null;
    // Deep details from detailed fetch
    final details = detailedMedia ?? {};
    final numSeasons = details['number_of_seasons'];
    final numEpisodes = details['number_of_episodes'];
    final seasonsStr = numSeasons != null
        ? '$numSeasons Season${numSeasons != 1 ? 's' : ''}'
        : '';
    final episodesStr = numEpisodes != null
        ? '$numEpisodes Episode${numEpisodes != 1 ? 's' : ''}'
        : '';

    List<int> availableSeasons = [1];
    int currentSeasonEpisodeCount = 1;
    if (isTvShow && details['seasons'] is List) {
      final seasonsList = details['seasons'] as List;
      availableSeasons = seasonsList
          .whereType<Map>()
          .map((s) => (s['season_number'] ?? 0) as int)
          .where((n) => n > 0)
          .toList();
      if (availableSeasons.isEmpty) availableSeasons = [1];

      currentSeasonEpisodeCount = _getEpisodeCountForSeason(_selectedSeason);
      if (currentSeasonEpisodeCount < 1) currentSeasonEpisodeCount = 1;
    }

    if (!availableSeasons.contains(_selectedSeason) &&
        availableSeasons.isNotEmpty) {
      _selectedSeason = availableSeasons.first;
    }

    List<int> availableEpisodes = List.generate(
      currentSeasonEpisodeCount,
      (i) => i + 1,
    );
    if (isTvShow && _seasonEpisodesData.containsKey(_selectedSeason)) {
      final epList = _seasonEpisodesData[_selectedSeason]!
          .whereType<Map>()
          .toList();
      availableEpisodes = epList
          .map<int>(
            (e) => int.tryParse(e['episode_number']?.toString() ?? '') ?? 0,
          )
          .where((n) => n > 0)
          .toList();

      // Filter out episodes that haven't aired yet (future dates or missing dates)
      availableEpisodes.removeWhere((epNum) {
        final epData = epList.firstWhere(
          (e) =>
              (int.tryParse(e['episode_number']?.toString() ?? '') ?? 0) ==
              epNum,
          orElse: () => <dynamic, dynamic>{},
        );
        if (epData.isNotEmpty) {
          final airDateStr = epData['air_date']?.toString();
          if (airDateStr != null && airDateStr.isNotEmpty) {
            try {
              final airDate = DateTime.parse(airDateStr);
              if (airDate.isAfter(DateTime.now())) return true;
            } catch (_) {}
          } else {
            // TMDB returns null for air_date if the episode hasn't been scheduled yet.
            // If it also lacks an overview, it is definitely a dummy placeholder.
            final overview = epData['overview']?.toString();
            if (overview == null || overview.trim().isEmpty) {
              return true;
            }
          }
        }
        return false;
      });
    }

    if (!availableEpisodes.contains(_selectedEpisode) &&
        availableEpisodes.isNotEmpty) {
      _selectedEpisode = availableEpisodes.first;
    }

    final credits = details['credits'] is Map
        ? details['credits'] as Map
        : null;
    final castList = credits != null && credits['cast'] is List
        ? credits['cast'] as List
        : [];
    final crewList = credits != null && credits['crew'] is List
        ? credits['crew'] as List
        : [];

    final directors = crewList
        .whereType<Map>()
        .where((c) => c['job'] == 'Director')
        .map((c) => c['name'])
        .join(', ');
    final screenplay = crewList
        .whereType<Map>()
        .where(
          (c) =>
              c['job'] == 'Screenplay' ||
              c['job'] == 'Writer' ||
              c['job'] == 'Teleplay',
        )
        .map((c) => c['name'])
        .join(', ');
    final authors = crewList
        .whereType<Map>()
        .where(
          (c) =>
              c['job'] == 'Novel' ||
              c['job'] == 'Author' ||
              c['job'] == 'Story' ||
              c['job'] == 'Book',
        )
        .map((c) => c['name'])
        .join(', ');

    final genresList = details['genres'] is List
        ? details['genres'] as List
        : [];
    final genres = genresList.whereType<Map>().map((g) => g['name']).join(', ');

    final epRunTimeList = details['episode_run_time'] is List
        ? details['episode_run_time'] as List
        : null;
    final epRunTimeNum = details['episode_run_time'] is num
        ? details['episode_run_time'] as num
        : null;
    final runtimeRaw =
        details['runtime'] ??
        (epRunTimeList != null && epRunTimeList.isNotEmpty
            ? epRunTimeList.first
            : epRunTimeNum);
    int? runtimeInt = runtimeRaw is num ? runtimeRaw.toInt() : null;

    String runtimeStr = '';
    if (runtimeInt != null && runtimeInt > 0) {
      final int hrs = runtimeInt ~/ 60;
      final int mins = runtimeInt % 60;
      runtimeStr = hrs > 0 ? '${hrs}h ${mins}m' : '${mins}m';
    }

    double currentProgress = isTvShow
        ? _getEpisodeProgress(_selectedSeason, _selectedEpisode)
        : _movieProgress;
    String mediaResumeStr = '';
    int mainResumeSeconds = 0;
    if (currentProgress > 0) {
      if (currentProgress >= 1.0) {
        mediaResumeStr = 'Watched';
      } else {
        int rTime = runtimeInt ?? (isTvShow ? 45 : 120); // Fallbacks

        if (isTvShow && _seasonEpisodesData.containsKey(_selectedSeason)) {
          final epList = _seasonEpisodesData[_selectedSeason]!
              .whereType<Map>()
              .toList();
          final epData = epList.firstWhere(
            (e) =>
                (int.tryParse(e['episode_number']?.toString() ?? '') ?? 0) ==
                _selectedEpisode,
            orElse: () => <dynamic, dynamic>{},
          );
          if (epData.isNotEmpty && epData['runtime'] != null) {
            rTime = epData['runtime'];
          }
        }
        final int resumeMinutes = (rTime * currentProgress).toInt();
        mainResumeSeconds = (rTime * 60 * currentProgress).toInt();
        final int rHr = resumeMinutes ~/ 60;
        final int rMin = resumeMinutes % 60;
        mediaResumeStr = 'Resuming from ${rHr > 0 ? '${rHr}h ' : ''}${rMin}m';
      }
    }

    final status = details['status']?.toString() ?? '';
    final language =
        details['original_language']?.toString().toUpperCase() ?? '';

    final budgetRaw = details['budget'];
    final budget = _formatCurrency(budgetRaw is num ? budgetRaw : null);
    final revenueRaw = details['revenue'];
    final revenue = _formatCurrency(revenueRaw is num ? revenueRaw : null);

    final networksList = details['networks'] is List
        ? details['networks'] as List
        : [];
    final networks = networksList
        .whereType<Map>()
        .map((n) => n['name'])
        .join(', ');
    final type = details['type']?.toString() ?? '';
    final firstAirDate = _formatDate(details['first_air_date']?.toString());
    final lastAirDate = _formatDate(details['last_air_date']?.toString());
    final inProductionRaw = details['in_production'];
    final inProduction = inProductionRaw != null
        ? (inProductionRaw ? 'Yes' : 'No')
        : '';

    final reviewsData = details['reviews'] is Map
        ? details['reviews'] as Map
        : null;
    final reviews =
        (reviewsData != null && reviewsData['results'] is List
                ? reviewsData['results'] as List
                : [])
            .take(10)
            .toList();

    final recommendationsData = details['recommendations'] is Map
        ? details['recommendations'] as Map
        : null;
    final recommendationsListRaw =
        recommendationsData != null && recommendationsData['results'] is List
        ? recommendationsData['results'] as List
        : [];
    final recommendationsList = recommendationsListRaw
        .map((item) {
          if (item is Map && item['media_type'] == null) {
            item['media_type'] = isTvShow ? 'tv' : 'movie';
          }
          return item;
        })
        .where((item) => _isReleased(item, strictFilter: true))
        .take(15)
        .toList();

    final backgroundImageUrl = backdropPath != null
        ? 'https://image.tmdb.org/t/p/original$backdropPath'
        : (posterPath != null
              ? 'https://image.tmdb.org/t/p/original$posterPath'
              : 'https://via.placeholder.com/1280x720?text=No+Image');

    final String colorHex = _dominantColor != null
        ? (_dominantColor!.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')
        : '1ce783';

    return Scaffold(
      backgroundColor: const Color(0xFF0F1014),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        // Ensure the surface tint color is transparent for a consistent look
        surfaceTintColor: Colors.transparent,
        leading: BackButton(onPressed: () => Navigator.pop(context, _hasMadeChanges)),
        iconTheme: const IconThemeData(color: Colors.white, size: 28),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Center(
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  border: Border.all(color: Colors.white.withOpacity(0.15)),
                  shape: BoxShape.circle,
                ),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    side: BorderSide.none,
                    shape: const CircleBorder(),
                  ),
                  onPressed: _toggleWatchlist,
                  child: Icon(
                    _isOnWatchlist ? Icons.check : Icons.add,
                    size: 26,
                  ),
                ),
              ),
            ),
          ),
        ], // Watchlist button
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background image and gradient
          Opacity(
            opacity: 0.2,
            child: CachedNetworkImage(
              imageUrl: backgroundImageUrl,
              fit: BoxFit.cover,
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, Color(0xFF0F1014)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter, // Gradient from top to bottom
                stops: [0.2, 1.0],
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: _showContent ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 800),
            child: SafeArea(
              // Ensures content is not obscured by system UI
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  isMobile ? 20.0 : 40.0,
                  100.0,
                  isMobile ? 20.0 : 40.0,
                  40.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      padding:
                          isMobile // Conditional padding for mobile vs desktop
                          ? const EdgeInsets.all(16.0)
                          : EdgeInsets.zero,
                      decoration: const BoxDecoration(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (_logoPath != null)
                            CachedNetworkImage(
                              imageUrl:
                                  'https://image.tmdb.org/t/p/w500$_logoPath',
                              width: 250, // Fixed width for logo
                              height: 100,
                              fit: BoxFit.contain,
                              alignment: Alignment.center,
                            )
                          else
                            Text(
                              title,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme // Use theme for text styles
                                  .headlineLarge
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    height: 1.1,
                                    fontSize: isMobile ? 28 : 34,
                                  ),
                            ),
                          const SizedBox(height: 16),
                          ...[
                            Wrap(
                              // For responsive layout of details
                              spacing: 16,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (_contentRating.isNotEmpty)
                                  Container(
                                    // Content rating badge
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border.all(color: Colors.white54),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      _contentRating,
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: isMobile ? 12 : 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                Text(
                                  releaseYear,
                                  style: TextStyle(
                                    // Release year
                                    color: Colors.white70,
                                    fontSize: isMobile ? 14 : 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Star rating
                                    const Icon(
                                      Icons.star,
                                      color: Color.fromARGB(255, 255, 255, 255),
                                      size: 18,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '$voteAverage / 10',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: isMobile ? 14 : 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                if (runtimeStr.isNotEmpty && !isTvShow)
                                  Text(
                                    // Runtime for movies
                                    runtimeStr,
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: isMobile ? 14 : 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                if (isTvShow && seasonsStr.isNotEmpty)
                                  Text(
                                    seasonsStr, // Seasons for TV shows
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: isMobile ? 14 : 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                if (isTvShow && episodesStr.isNotEmpty)
                                  Text(
                                    episodesStr,
                                    style: TextStyle(
                                      // Episodes for TV shows
                                      color: Colors.white70,
                                      fontSize: isMobile ? 14 : 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                              ],
                            ),
                            if (genres.isNotEmpty) ...[
                              const SizedBox(height: 8), // Spacing
                              Text(
                                genres,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: isMobile ? 12 : 14,
                                ),
                              ),
                            ],
                          ],
                          const SizedBox(height: 16), // Spacing
                          if ((!isTvShow && _isMovieCompleted) ||
                              (isTvShow && _isSeriesCompleted))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    'Watched',
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: isMobile ? 13 : 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.check_circle,
                                    color: const Color.fromARGB(
                                      255,
                                      255,
                                      255,
                                      255,
                                    ),
                                    size: isMobile ? 16 : 18,
                                  ),
                                ],
                              ),
                            ),
                          Row(
                            // Play and Download buttons
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final containerWidth = constraints.maxWidth;
                                    const btnSize = 56.0;
                                    const playWidth = 240.0;
                                    const spacing = 12.0;

                                    final trailerLeft = playWidth + spacing;
                                    final shareLeft = _trailerKey != null 
                                        ? (trailerLeft + btnSize + spacing) 
                                        : trailerLeft;
                                    final downloadLeft = isDesktopOrWeb 
                                        ? (shareLeft + btnSize + spacing) 
                                        : (_trailerKey != null ? trailerLeft + btnSize + spacing : trailerLeft);

                                    double totalWidth = playWidth;
                                    if (_trailerKey != null) totalWidth += (spacing + btnSize);
                                    if (isDesktopOrWeb) totalWidth += (spacing + btnSize);
                                    if (!isTvShow) totalWidth += (spacing + btnSize);

                                    final startX = !_isDownloadActive
                                        ? (containerWidth - totalWidth) / 2
                                        : 0.0;

                                    return SizedBox(
                                      height: 56, // Fixed height for button row
                                      child: Stack(
                                        children: [
                                          // Play Button
                                          AnimatedPositioned(
                                            duration: const Duration(
                                              milliseconds: 400,
                                            ),
                                            curve: Curves.easeInOut,
                                            left: startX,
                                            width: _isDownloadActive
                                                ? 0.0
                                                : playWidth,
                                            height: 56,
                                            child: ClipRect(
                                              child: AnimatedOpacity(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                opacity: _isDownloadActive
                                                    ? 0.0
                                                    : 1.0,
                                                child: _buildPlayButton(
                                                  mainResumeSeconds,
                                                ),
                                              ),
                                            ),
                                          ),

                                          // Trailer Button
                                          if (_trailerKey != null)
                                            AnimatedPositioned(
                                              duration: const Duration(
                                                milliseconds: 400,
                                              ), // Animation duration
                                              curve: Curves.easeInOut,
                                              left: _isDownloadActive
                                                  ? -btnSize - spacing
                                                  : startX + trailerLeft,
                                              width: btnSize,
                                              height: 56,
                                              child: AnimatedOpacity(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                opacity: _isDownloadActive
                                                    ? 0.0
                                                    : 1.0,
                                                child: _buildTrailerButton(),
                                              ),
                                            ),

                                          // Share Button (Desktop/Web only)
                                          if (isDesktopOrWeb)
                                            AnimatedPositioned(
                                              duration: const Duration(milliseconds: 400),
                                              curve: Curves.easeInOut,
                                              left: _isDownloadActive
                                                  ? -btnSize - spacing
                                                  : startX + shareLeft,
                                              width: btnSize,
                                              height: 56,
                                              child: AnimatedOpacity(
                                                duration: const Duration(milliseconds: 200),
                                                opacity: _isDownloadActive
                                                    ? 0.0
                                                    : 1.0,
                                                child: _buildShareButton(),
                                              ),
                                            ),

                                          if (!isTvShow)
                                            // Download Button/UI
                                            AnimatedPositioned(
                                              duration: const Duration(
                                                milliseconds: 400,
                                              ),
                                              curve: Curves
                                                  .easeInOut, // Animation curve
                                              width: _isDownloadActive
                                                  ? containerWidth
                                                  : btnSize,
                                              left: _isDownloadActive
                                                  ? 0.0
                                                  : startX + downloadLeft,
                                              height: 56,
                                              child: AnimatedSwitcher(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                layoutBuilder:
                                                    (
                                                      currentChild,
                                                      previousChildren,
                                                    ) {
                                                      return Stack(
                                                        alignment:
                                                            Alignment.center,
                                                        children: <Widget>[
                                                          ...previousChildren, // Keep previous children during transition

                                                          if (currentChild !=
                                                              null)
                                                            currentChild,
                                                        ],
                                                      );
                                                    },
                                                child: _isDownloadActive
                                                    ? _buildDownloadExpanded(
                                                        posterPath,
                                                        _logoPath,
                                                        backdropPath,
                                                        overview,
                                                      )
                                                    : _buildDownloadCollapsed(),
                                              ),
                                            ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ), // Progress indicator for continue watching
                          if (currentProgress > 0 && currentProgress < 1.0)
                            Padding(
                              padding: const EdgeInsets.only(top: 12.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    mediaResumeStr,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 100,
                                    height: 4,
                                    child: LinearProgressIndicator(
                                      value: currentProgress,
                                      backgroundColor: Colors.white24,
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                            Color.fromARGB(255, 255, 255, 255),
                                          ),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Center(
                      child: Container(
                        constraints: BoxConstraints(
                          maxWidth: kIsWeb
                              ? MediaQuery.sizeOf(context).width * 0.7
                              : double.infinity,
                        ),
                        child: Text(
                          overview,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: isMobile ? 14 : 16,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 40),
                    ...[
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          castList
                                  .isEmpty // Conditional display for cast list
                              ? const Text(
                                  'Cast information is unavailable.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.white70),
                                )
                              : kIsWeb
                              ? Center(
                                  child: Container(
                                    constraints: BoxConstraints(
                                      maxWidth:
                                          MediaQuery.sizeOf(context).width *
                                          0.8,
                                    ),
                                    child: ClipRect(
                                      child: SizedBox(
                                        height:
                                            165.0, // Increased height for scale animation room
                                        child: Wrap(
                                          alignment: WrapAlignment.center,
                                          spacing: 12,
                                          runSpacing: 24,
                                          children: castList
                                              .take(24)
                                              .map(
                                                (actor) =>
                                                    _buildCastMemberItem(actor),
                                              )
                                              .toList(),
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : SizedBox(
                                  height: 190,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: castList.length,
                                    itemBuilder: (context, index) =>
                                        _buildCastMemberItem(castList[index]),
                                  ),
                                ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (isTvShow) ...[
                        const SizedBox(height: 16), // Spacing
                        SizedBox(
                          height: 38,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: availableSeasons.length,
                            itemBuilder: (context, index) {
                              final s = availableSeasons[index];
                              final isSelected = s == _selectedSeason;
                              double progress = _getSeasonProgress(
                                s,
                                _getEpisodeCountForSeason(s),
                              );
                              return GestureDetector(
                                // Season selection button
                                onTap: () {
                                  if (s != _selectedSeason) {
                                    setState(() {
                                      _selectedSeason = s;
                                      _selectedEpisode = 1;
                                      _visualSelectedEpisode = null;
                                    });
                                    fetchSeasonDetails(s);
                                  }
                                },
                                child: Container(
                                  margin: const EdgeInsets.only(
                                    right: 12,
                                  ), // Spacing between season buttons
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? (_dominantColor ??
                                              const Color(0xFF1CE783))
                                        : Colors.white.withOpacity(0.05),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: isSelected
                                          ? Colors.transparent
                                          : Colors.white10,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Row(
                                    // Season text and progress indicator
                                    children: [
                                      Text(
                                        'Season $s',
                                        style: TextStyle(
                                          color: isSelected
                                              ? ((_dominantColor?.computeLuminance() ??
                                                            1.0) <
                                                        0.5
                                                    ? Colors.white
                                                    : Colors.black)
                                              : Colors.white70,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                      ),
                                      if (progress >= 1.0) ...[
                                        const SizedBox(width: 8), // Spacing
                                        Icon(
                                          Icons.check_circle,
                                          size: 16,
                                          color: isSelected
                                              ? ((_dominantColor?.computeLuminance() ??
                                                            1.0) <
                                                        0.5
                                                    ? Colors.white
                                                    : Colors.black)
                                              : Colors.white70,
                                        ),
                                      ] else if (progress > 0.0) ...[
                                        const SizedBox(width: 8), // Spacing
                                        Icon(
                                          Icons.brightness_medium,
                                          size: 16,
                                          color: isSelected
                                              ? ((_dominantColor?.computeLuminance() ??
                                                            1.0) <
                                                        0.5
                                                    ? Colors.white
                                                    : Colors.black)
                                              : Colors.white70,
                                        ), // Half-filled circle for in-progress
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ), // Episode list
                        const SizedBox(height: 16),
                        ListView.builder(
                          padding: EdgeInsets.zero,
                          key: ValueKey('ep_list_$_refreshKey'), // Force solid rebuild with counter
                          physics: const NeverScrollableScrollPhysics(),
                          shrinkWrap: true,
                          itemCount: availableEpisodes.length,
                          itemBuilder: (context, index) {
                            final int val = availableEpisodes[index];
                            final double progress = _getEpisodeProgress(
                              _selectedSeason,
                              val,
                            );
                            final bool isSelected =
                                val == _visualSelectedEpisode;

                            String titleText = 'Ep. $val';
                            int? epRuntime;
                            String? epOverview;
                            String? epAirDate;
                            String? epStillPath;

                            if (_seasonEpisodesData.containsKey(
                              _selectedSeason,
                            )) {
                              final epList =
                                  _seasonEpisodesData[_selectedSeason]!
                                      .whereType<Map>()
                                      .toList();
                              final epData = epList.firstWhere(
                                (e) =>
                                    (int.tryParse(
                                          e['episode_number']?.toString() ?? '',
                                        ) ??
                                        0) ==
                                    val,
                                orElse: () => <dynamic, dynamic>{},
                              );
                              if (epData.isNotEmpty) {
                                final name = epData['name']?.toString() ?? '';
                                if (name.isNotEmpty) {
                                  titleText = 'Ep. $val - $name';
                                }
                                epRuntime = epData['runtime'];
                                epOverview = epData['overview']?.toString();
                                epAirDate = epData['air_date']?.toString();
                                epStillPath = epData['still_path']?.toString();
                              }
                            }

                            List<Widget> subtitleChildren = [];
                            if (epRuntime != null && epRuntime > 0) {
                              final int hrs = epRuntime ~/ 60;
                              final int mins = epRuntime % 60;
                              final String durationStr = hrs > 0
                                  ? '${hrs}h ${mins}m'
                                  : '${mins}m';
                              subtitleChildren.add(
                                Text(
                                  durationStr,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              );
                            }
                            if (epOverview != null && epOverview.isNotEmpty) {
                              if (subtitleChildren.isNotEmpty) {
                                subtitleChildren.add(const SizedBox(height: 4));
                              }
                              subtitleChildren.add(
                                Text(
                                  epOverview,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }
                            if (epAirDate != null && epAirDate.isNotEmpty) {
                              if (subtitleChildren.isNotEmpty) {
                                subtitleChildren.add(const SizedBox(height: 4));
                              }
                              subtitleChildren.add(
                                Text(
                                  'Aired: ${_formatDate(epAirDate)}',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              );
                            }

                            int epResumeSeconds = 0;
                            if (progress > 0 && progress < 1.0) {
                              epResumeSeconds =
                                  ((epRuntime ?? 45) * 60 * progress).toInt();
                              if (!isMobile) {
                                if (subtitleChildren.isNotEmpty) {
                                  // Add spacing if other subtitles exist
                                  subtitleChildren.add(
                                    const SizedBox(height: 6),
                                  );
                                }
                                final int resumeMins =
                                    ((epRuntime ?? 45) * progress).toInt();
                                final int rHr = resumeMins ~/ 60;
                                final int rMin = resumeMins % 60;
                                subtitleChildren.add(
                                  Text(
                                    'Resuming from ${rHr > 0 ? '${rHr}h ' : ''}${rMin}m',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                );
                              }
                            }

                            Widget? subtitleWidget = subtitleChildren.isNotEmpty
                                ? Padding(
                                    // Subtitle widget for episode details
                                    padding: const EdgeInsets.only(top: 4.0),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: subtitleChildren,
                                    ),
                                  )
                                : null;

                            bool isInteractionActive = false;

                            return StatefulBuilder(
                              builder: (context, setItemState) {
                                return MouseRegion(
                                  onEnter: (_) => setItemState(
                                    () => isInteractionActive = true,
                                  ),
                                  onExit: (_) => setItemState(
                                    () => isInteractionActive = false,
                                  ),
                                  child: Align(
                                    alignment: Alignment.center,
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: isDesktopOrWeb 
                                          ? MediaQuery.sizeOf(context).width * 0.6 
                                          : double.infinity,
                                      ),
                                      child: Stack(
                                        children: [
                                          Container(
                                    margin: const EdgeInsets.only(bottom: 12.0),
                                    clipBehavior: Clip.hardEdge,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(
                                        // Rounded corners for episode card
                                        8.0,
                                      ),
                                      color: isSelected
                                          ? Colors.white.withOpacity(0.05)
                                          : const Color(0xFF1E1F24),
                                      border: isSelected
                                          ? Border.all(
                                              color: const Color(
                                                0xFF1CE783,
                                              ).withOpacity(0.5),
                                            )
                                          : Border.all(color: Colors.white12),
                                    ), // InkWell for tap feedback
                                    child: InkWell(
                                      onTap: () => setState(() {
                                        _visualSelectedEpisode = val;
                                        _selectedEpisode = val;
                                      }),
                                      onHighlightChanged: (highlighted) {
                                        setItemState(
                                          () =>
                                              isInteractionActive = highlighted,
                                        );
                                      },
                                      child: IntrinsicHeight(
                                        // Ensures children take up full height
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Expanded(
                                              flex:
                                                  4, // Extended width to the right
                                              child: GestureDetector(
                                                onTap: () {
                                                  setState(() {
                                                    // Update selected episode
                                                    _visualSelectedEpisode =
                                                        val;
                                                    _selectedEpisode = val;
                                                  });
                                                  final String smId =
                                                      (widget.media['id'] ??
                                                              sourceMedia['id'] ??
                                                              '')
                                                          .toString();
                                                  final Map<String, dynamic>
                                                  cleanMedia = {
                                                    'id': smId,
                                                    'title':
                                                        (sourceMedia['title'] ??
                                                                sourceMedia['name'] ??
                                                                'Unknown')
                                                            .toString(),
                                                    'media_type':
                                                        (sourceMedia['media_type']
                                                                    ?.toString() ??
                                                                'tv')
                                                            .toString(),
                                                    'poster_path':
                                                        sourceMedia['poster_path']
                                                            ?.toString(),
                                                    'backdrop_path':
                                                        sourceMedia['backdrop_path']
                                                            ?.toString(),
                                                  };
                                                  final String sNum =
                                                      _selectedSeason
                                                          .toString();
                                                  final String eNum = val
                                                      .toString();
                                                  final String pLink = Uri.https(
                                                    'player.videasy.net',
                                                    'tv/$smId/$sNum/$eNum',
                                                    {
                                                      'color': colorHex,
                                                      'autoPlay': 'true',
                                                      'nextEpisode': 'true',
                                                      'overlay': 'true',
                                                      'progress': epResumeSeconds.toString(),
                                                    },
                                                  ).toString();
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (context) =>
                                                          VideoPlayerPage(
                                                            videoUrl: pLink,
                                                            media: cleanMedia,
                                                            season:
                                                                _selectedSeason,
                                                            episode: val,
                                                          ),
                                                    ),
                                                  ).then((videoPlayerChanged) {
                                                    if (mounted) {
                                                      if (videoPlayerChanged == true) {
                                                        setState(() => _hasMadeChanges = true);
                                                      }
                                                      fetchDetails();
                                                    }
                                                  });
                                                  ProgressManager.saveProgress(
                                                    media: cleanMedia,
                                                    progress: progress == 0
                                                        ? 0.05
                                                        : progress,
                                                    season: _selectedSeason,
                                                    episode: val,
                                                    position: epResumeSeconds,
                                                    runtime: epRuntime,
                                                  );
                                                },
                                                child: Container(
                                                  clipBehavior: Clip.hardEdge,
                                                  decoration: const BoxDecoration(
                                                    borderRadius: BorderRadius.only(
                                                      // Rounded corners for episode image
                                                      topLeft: Radius.circular(
                                                        8.0,
                                                      ),
                                                      bottomLeft:
                                                          Radius.circular(8.0),
                                                    ),
                                                  ),
                                                  child: Stack(
                                                    alignment: Alignment.center,
                                                    children: [
                                                      Positioned.fill(
                                                        // Dark overlay for image
                                                        child: Container(
                                                          color: Colors.black
                                                              .withOpacity(
                                                                0.3,
                                                              ), // Dark overlay
                                                        ),
                                                      ),
                                                      Positioned.fill(
                                                        child:
                                                            epStillPath != null
                                                            ? CachedNetworkImage(
                                                                httpHeaders: _cachedImageHttpHeaders,
                                                                imageUrl:
                                                                    'https://image.tmdb.org/t/p/w500$epStillPath', // Episode still image
                                                                fit: BoxFit
                                                                    .cover,
                                                                placeholder:
                                                                    (
                                                                      context,
                                                                      url,
                                                                    ) => Container(
                                                                      color: Colors
                                                                          .black26,
                                                                    ),
                                                                errorWidget:
                                                                    (
                                                                      context,
                                                                      url,
                                                                      error,
                                                                    ) => Container(
                                                                      color: Colors
                                                                          .black26,
                                                                      child: const Icon(
                                                                        Icons
                                                                            .broken_image,
                                                                        color: Colors
                                                                            .white54,
                                                                      ),
                                                                    ),
                                                              )
                                                            : Container(
                                                                color: Colors
                                                                    .black26,
                                                                child: const Icon(
                                                                  Icons.tv,
                                                                  color: Colors
                                                                      .white54,
                                                                  size: 60,
                                                                ),
                                                              ),
                                                      ), // Gradient overlay for text
                                                      Positioned.fill(
                                                        child: Container(
                                                          decoration: BoxDecoration(
                                                            gradient: LinearGradient(
                                                              begin: Alignment
                                                                  .centerLeft,
                                                              end: Alignment
                                                                  .centerRight,
                                                              colors: [
                                                                Colors
                                                                    .transparent,
                                                                Colors
                                                                    .transparent,
                                                                const Color(
                                                                  0xFF1E1F24,
                                                                ).withOpacity(
                                                                  0.8,
                                                                ),
                                                                const Color(
                                                                  0xFF1E1F24,
                                                                ),
                                                              ],
                                                              stops: const [
                                                                0.0,
                                                                0.7,
                                                                0.9,
                                                                1.0,
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      ), // Play button and progress indicator
                                                      CustomPaint(
                                                        painter: DownloadProgressPainter(
                                                          status:
                                                              progress >= 0.9
                                                              ? DownloadStatus
                                                                    .done
                                                              : (progress > 0
                                                                    ? DownloadStatus
                                                                          .downloading
                                                                    : DownloadStatus
                                                                          .none),
                                                          progress: progress,
                                                          rotationAnimation:
                                                              _spinnerController,
                                                          color:
                                                              _dominantColor ??
                                                              const Color(
                                                                0xFF1CE783,
                                                              ),
                                                        ),
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets.all(
                                                                2.0,
                                                              ),
                                                          child: Icon(
                                                            Icons
                                                                .play_circle_fill,
                                                            color:
                                                                (isMobile ||
                                                                    isInteractionActive)
                                                                ? Colors.white
                                                                : Colors
                                                                      .white54,
                                                            size: 48,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              flex: 6,
                                              child: Padding(
                                                padding: const EdgeInsets.only(
                                                  left: 4.0,
                                                  right: 16.0,
                                                  top: 12.0,
                                                  bottom: 12.0,
                                                ), // Padding for episode text
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .spaceBetween,
                                                      children: [
                                                        Expanded(
                                                          child: Text(
                                                            // Episode title
                                                            titleText,
                                                            style: TextStyle(
                                                              color: isSelected
                                                                  ? const Color(
                                                                      0xFF1CE783,
                                                                    )
                                                                  : Colors
                                                                        .white,
                                                              fontWeight:
                                                                  isSelected
                                                                  ? FontWeight
                                                                        .bold
                                                                  : FontWeight
                                                                        .normal,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    if (subtitleWidget != null)
                                                      subtitleWidget,
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                          if (isDesktopOrWeb)
                                            Positioned(
                                              top: 8,
                                              right: 8,
                                              child: PopupMenuButton<String>(
                                                icon: const Icon(Icons.more_vert, color: Colors.white54, size: 22),
                                                onSelected: (action) async {
                                                  if (action == 'watched') {
                                                    await ProgressManager.saveProgress(
                                                      media: sourceMedia,
                                                      progress: 1.0,
                                                      season: _selectedSeason,
                                                      episode: val,
                                                    );
                                                    setState(() => _hasMadeChanges = true);
                                                  } else if (action == 'watched_up_to') {
                                                    final seasons = (detailedMedia?['seasons'] as List?) ?? [];
                                                    for (var s in seasons) {
                                                      final int sNum = (s['season_number'] ?? 0) as int;
                                                      if (sNum == 0) continue; // Skip Specials
                                                      if (sNum < _selectedSeason) {
                                                        final int count = _getEpisodeCountForSeason(sNum);
                                                        for (int i = 1; i <= count; i++) {
                                                          await ProgressManager.saveProgress(
                                                            media: sourceMedia,
                                                            progress: 1.0,
                                                            season: sNum,
                                                            episode: i,
                                                          );
                                                        }
                                                      } else if (sNum == _selectedSeason) {
                                                        for (int i = 1; i <= val; i++) {
                                                          await ProgressManager.saveProgress(
                                                            media: sourceMedia,
                                                            progress: 1.0,
                                                            season: sNum,
                                                            episode: i,
                                                          );
                                                        }
                                                        break; // Current season reached, don't mark future seasons
                                                      }
                                                    }
                                                    setState(() => _hasMadeChanges = true);
                                                  } else if (action == 'remove') {
                                                    await ProgressManager.deleteProgress(
                                                      sourceMedia['id'],
                                                      'tv',
                                                      season: _selectedSeason,
                                                      episode: val,
                                                    );
                                                    setState(() => _hasMadeChanges = true);
                                                  }
                                                  if (mounted) fetchDetails();
                                                },
                                                itemBuilder: (context) => [
                                                  const PopupMenuItem(value: 'watched', child: Text('Already watched')),
                                                  const PopupMenuItem(value: 'watched_up_to', child: Text('Watched up to here')),
                                                  const PopupMenuItem(value: 'remove', child: Text('Remove from history')),
                                                ],
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ],

                      if (recommendationsList.isNotEmpty) ...[
                        const SizedBox(height: 40),
                        HorizontalMediaList(
                          // Recommendations section
                          categoryTitle: 'Recommendations',
                          items: recommendationsList,
                          showTitle: true,
                          listPadding: const EdgeInsets.only(right: 212.0),
                        ),
                      ],
                      const SizedBox(height: 40),
                      Text(
                        // Details section title
                        'DETAILS',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                      ),
                      const SizedBox(height: 16),
                      if (isTvShow) ...[
                        // TV show specific details
                        _buildDetailRow('Network', networks),
                        _buildDetailRow('Type', type),
                        _buildDetailRow('Status', status),
                        _buildDetailRow('First Aired', firstAirDate),
                        _buildDetailRow('Last Aired', lastAirDate),
                        _buildDetailRow('In Production', inProduction),
                      ] else ...[
                        _buildDetailRow(
                          'Status',
                          status,
                        ), // Movie specific details
                        _buildDetailRow('Budget', budget),
                        _buildDetailRow('Revenue', revenue),
                      ],
                      _buildDetailRow('Director', directors),
                      _buildDetailRow('Screenplay', screenplay),
                      _buildDetailRow('Based on', authors),
                      _buildDetailRow('Language', language),

                      if (reviews.isNotEmpty) ...[
                        const SizedBox(height: 40), // Spacing
                        Text(
                          'TOP REVIEWS',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                        ),
                        const SizedBox(height: 16),
                        ListView.builder(
                          // Reviews list
                          padding: EdgeInsets.zero,
                          physics: const NeverScrollableScrollPhysics(),
                          shrinkWrap: true,
                          itemCount: reviews.length,
                          itemBuilder: (context, index) {
                            final review = reviews[index];
                            if (review is! Map) {
                              return const SizedBox.shrink();
                            }

                            final author =
                                review['author']?.toString() ?? 'Unknown';
                            final content = review['content']?.toString() ?? '';
                            final authorDetails =
                                review['author_details'] is Map
                                ? review['author_details'] as Map
                                : null;
                            final rating = authorDetails != null
                                ? authorDetails['rating']?.toString()
                                : null;

                            return Container(
                              margin: const EdgeInsets.only(bottom: 16.0),
                              padding: const EdgeInsets.all(
                                16.0,
                              ), // Padding for review card
                              decoration: BoxDecoration(
                                color: const Color(
                                  0x0DFFFFFF,
                                ), // 5% opacity white
                                borderRadius: BorderRadius.circular(8.0),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        // Author name
                                        author,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const Spacer(),
                                      if (rating != null) ...[
                                        const Icon(
                                          // Star icon for rating
                                          Icons.star,
                                          color: Color.fromARGB(
                                            255,
                                            255,
                                            255,
                                            255,
                                          ),
                                          size: 16,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          rating,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    // Review content
                                    content,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      height: 1.4,
                                    ),
                                    maxLines: 5,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),
          ),
          if (!_showContent) // Loading indicator
            const Center(
              child: CircularProgressIndicator(
                color: Color.fromARGB(255, 255, 255, 255),
              ),
            ),
        ],
      ),
    );
  }
}

class DownloadedMediaDetailsPage extends StatefulWidget {
  final CachedDownloadItem item; 
  final String heroTag;

  const DownloadedMediaDetailsPage({
    super.key,
    required this.item,
    required this.heroTag,
  });

  @override
  State<DownloadedMediaDetailsPage> createState() =>
      _DownloadedMediaDetailsPageState();
}

class _DownloadedMediaDetailsPageState
    extends State<DownloadedMediaDetailsPage> {
  late File _videoFile;
  Map<String, dynamic>? _mediaDetails;
  String? _logoPath;
  Color? _dominantColor;
  bool _hasMadeChanges = false;
  bool _isLoading = true;
  String _fileSize = '';
  bool _isOnWatchlist = false;

  @override
  void initState() {
    super.initState();
    _videoFile = File(widget.item.filePath);
    _loadDetails();
    _checkWatchlistStatus();
    _calculateFileSize();
  }

  Future<void> _calculateFileSize() async {
    try {
      if (await _videoFile.exists()) {
        final bytes = await _videoFile.length();
        if (mounted) {
          setState(() {
            _fileSize = _formatBytes(bytes);
          });
        }
      }
    } catch (e) {
      debugPrint(
        'Could not calculate file size for ${widget.item.filePath}: $e',
      );
    }
  }

  String _formatBytes(int bytes, [int decimals = 1]) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = (log(bytes) / log(1024)).floor();
    if (i == 0) decimals = 0;
    return '${(bytes / pow(1024, i)).toStringAsFixed(decimals)} ${suffixes[i]}';
  }

  Future<void> _loadDetails() async {
    if (!await _videoFile.exists()) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error: Downloaded file not found.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    try {
      final mediaType = widget.item.mediaType;
      final mediaId = widget.item.mediaId;
      final url =
          'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey&append_to_response=images,content_ratings,release_dates';
      final data = await fetchWithCache(url);

      String? extractedLogo;
      if (data['images'] != null && data['images']['logos'] is List) {
        final logos = data['images']['logos'] as List;
        final validLogos = logos
            .where(
              (l) =>
                  l is Map &&
                  !(l['file_path']?.toString().toLowerCase().endsWith('.svg') ??
                      false),
            )
            .toList();
        if (validLogos.isNotEmpty) {
          validLogos.sort(
            (a, b) =>
                (double.tryParse(b['vote_average']?.toString() ?? '0') ?? 0.0)
                    .compareTo(
                      double.tryParse(a['vote_average']?.toString() ?? '0') ??
                          0.0,
                    ),
          );
          final enLogo = validLogos.firstWhere(
            (l) => l['iso_639_1'] == 'en',
            orElse: () => validLogos.first,
          );
          extractedLogo = enLogo['file_path'];
        }
      }

      if (extractedLogo != null) {
        _extractDominantColor('https://image.tmdb.org/t/p/w500$extractedLogo');
      }

      if (mounted) {
        setState(() {
          _mediaDetails = data;
          _logoPath = extractedLogo;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _extractDominantColor(String imageUrl) async {
    try {
      final colorScheme = await ColorScheme.fromImageProvider(
        provider: CachedNetworkImageProvider(imageUrl, headers: _cachedImageHttpHeaders),
        brightness: Brightness.dark,
      );
      if (mounted) {
        setState(() {
          _dominantColor = colorScheme.primary;
        });
      }
    } catch (e) {
      debugPrint('Error extracting color: $e');
    }
  }

  Future<void> _checkWatchlistStatus() async {
    final String mediaId = widget.item.mediaId;
    if (mediaId.isEmpty) return;
    final isOn = await WatchlistManager.isOnWatchlist(mediaId);
    if (mounted) {
      setState(() {
        _isOnWatchlist = isOn;
      });
    }
  }

  Future<void> _toggleWatchlist() async {
    final String mediaId = widget.item.mediaId;
    if (mediaId.isEmpty) return;
    if (_isOnWatchlist) {
      await WatchlistManager.removeFromWatchlist(mediaId);
    } else {
      await WatchlistManager.addToWatchlist(
        _mediaDetails ??
            {
              'id': mediaId,
              'title': widget.item.title,
              'poster_path': widget.item.posterPath,
              'media_type': widget.item.mediaType,
            },
      );
    }
    _checkWatchlistStatus();
  }

  Future<void> _handleDelete() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1F24),
        title: const Text(
          'Delete Download',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Are you sure you want to delete this download?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _videoFile.delete();
      await DownloadManager().removeDownloadFromCache(widget.item.mediaId);
      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Download deleted.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  Widget _buildDownloadedButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 240,
          height: 56,
          decoration: BoxDecoration(
            color: (_dominantColor ?? Colors.white).withOpacity(0.05),
            border: Border.all(
              color: (_dominantColor ?? Colors.white).withOpacity(0.15),
            ),
            borderRadius: BorderRadius.circular(28),
          ),
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              foregroundColor: _dominantColor ?? Colors.white,
              minimumSize: const Size.fromHeight(56),
              padding: const EdgeInsets.symmetric(horizontal: 24),
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => LocalVideoPlayerPage(
                    videoFile: _videoFile,
                    title: widget.item.title,
                  ),
                ),
              ).then((changed) {
                if (changed == true && mounted) {
                  setState(() => _hasMadeChanges = true);
                }
              });
            },
            icon: const Icon(Icons.play_arrow, size: 24),
            label: const Text(
              'Play Offline',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            border: Border.all(color: Colors.white.withOpacity(0.15)),
            shape: BoxShape.circle,
          ),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              padding: EdgeInsets.zero,
              side: BorderSide.none,
              shape: const CircleBorder(),
            ),
            onPressed: _handleDelete,
            child: const Icon(Icons.delete_outline, size: 24),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sourceMedia =
        _mediaDetails ??
        {'title': widget.item.title, 'name': widget.item.title};
    final title =
        sourceMedia['title']?.toString() ??
        sourceMedia['name']?.toString() ??
        'Unknown';
    final backdropPath = sourceMedia['backdrop_path']?.toString();
    final backgroundImageUrl = backdropPath != null
        ? 'https://image.tmdb.org/t/p/original$backdropPath'
        : 'https://via.placeholder.com/1280x720?text=No+Image';

    final details = _mediaDetails ?? {};
    final isTvShow = widget.item.mediaType == 'tv';

    String contentRating = '';
    if (_mediaDetails != null) {
      if (isTvShow) {
        final results =
            (details['content_ratings']?['results'] as List?)
                ?.whereType<Map>()
                .toList() ??
            [];
        for (var r in results) {
          if (r['iso_3166_1'] == 'US' && r['rating'] != null) {
            contentRating = r['rating'].toString();
            break;
          }
        }
      } else {
        final results =
            (details['release_dates']?['results'] as List?)
                ?.whereType<Map>()
                .toList() ??
            [];
        for (var r in results) {
          if (r['iso_3166_1'] == 'US' && r['release_dates'] is List) {
            for (var d in r['release_dates']) {
              if (d is Map &&
                  d['certification'] != null &&
                  d['certification'].toString().isNotEmpty) {
                contentRating = d['certification'].toString();
                break;
              }
            }
            if (contentRating.isNotEmpty) break;
          }
        }
      }
    }

    final releaseDateRaw = details['release_date'] ?? details['first_air_date'];
    final year = (releaseDateRaw?.toString() ?? '').length >= 4
        ? releaseDateRaw.toString().substring(0, 4)
        : '';

    final voteAverageRaw = details['vote_average'];
    final voteAverage = voteAverageRaw != null
        ? double.tryParse(voteAverageRaw.toString())?.toStringAsFixed(1)
        : null;

    final runtimeRaw =
        details['runtime'] ??
        (details['episode_run_time'] is List &&
                (details['episode_run_time'] as List).isNotEmpty
            ? (details['episode_run_time'] as List)[0]
            : null);
    String runtimeStr = '';
    if (runtimeRaw is num && runtimeRaw > 0) {
      final int hrs = runtimeRaw.toInt() ~/ 60;
      final int mins = runtimeRaw.toInt() % 60;
      runtimeStr = hrs > 0 ? '${hrs}h ${mins}m' : '${mins}m';
    }

    final genresList =
        (details['genres'] as List?)?.whereType<Map>().toList() ?? [];
    final genres = genresList.map((g) => g['name']).join(', ');

    final overview = details['overview']?.toString();

    return Scaffold(
      backgroundColor: const Color(0xFF0F1014),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: BackButton(onPressed: () => Navigator.pop(context, _hasMadeChanges)),
        surfaceTintColor:
            Colors.transparent, // Ensure transparent for consistent look
        iconTheme: const IconThemeData(
          color: Colors.white,
          size: 28,
        ), // Back button icon
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Center(
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  border: Border.all(color: Colors.white.withOpacity(0.15)),
                  shape: BoxShape.circle,
                ),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    side: BorderSide.none,
                    shape: const CircleBorder(),
                  ),
                  onPressed: _toggleWatchlist,
                  child: Icon(
                    _isOnWatchlist ? Icons.check : Icons.add,
                    size: 26,
                  ),
                ),
              ),
            ),
          ),
        ],
      ), // Main content
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (!_isLoading && backdropPath != null)
            Opacity(
              opacity: 0.2,
              // Added httpHeaders to CachedNetworkImage
              child: CachedNetworkImage(
                imageUrl: backgroundImageUrl,
                fit: BoxFit.cover,
              ),
            ),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, Color(0xFF0F1014)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.2, 1.0],
              ),
            ),
          ),
          if (_isLoading) // Loading indicator
            const Center(
              child: CircularProgressIndicator(
                color: Color.fromARGB(255, 255, 255, 255),
              ),
            )
          else
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 40.0,
                  vertical: 20.0,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Spacer(flex: 2), // Spacing
                    if (_logoPath != null)
                      CachedNetworkImage(
                        imageUrl: 'https://image.tmdb.org/t/p/w500$_logoPath',
                        httpHeaders: _cachedImageHttpHeaders,
                        width: 300,
                        height: 150,
                        fit: BoxFit.contain,
                      )
                    else
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              height: 1.1,
                            ),
                      ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (contentRating.isNotEmpty) // Content rating badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white54),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              contentRating,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        if (year.isNotEmpty)
                          Text(
                            // Release year
                            year,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        if (voteAverage != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.star,
                                color: Color.fromARGB(255, 255, 255, 255),
                                size: 18,
                              ), // Star icon for rating
                              const SizedBox(width: 4),
                              Text(
                                '$voteAverage / 10',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        if (runtimeStr.isNotEmpty)
                          Text(
                            // Runtime
                            runtimeStr,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                      ],
                    ),
                    if (genres.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        genres,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                        ),
                      ),
                    ], // Genres
                    const Spacer(flex: 1),
                    _buildDownloadedButtons(),
                    if (overview != null && overview.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      Center(
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: kIsWeb
                                ? MediaQuery.sizeOf(context).width * 0.7
                                : double.infinity,
                          ),
                          child: Text(
                            overview,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                              height: 1.5,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                    if (_fileSize.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'File Size: $_fileSize',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const Spacer(flex: 3), // Spacing
                  ],
                ),
              ),
            ),
          if (_isLoading)
            Container(
              color: Colors.black,
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

class ActorDetailsPage extends StatefulWidget {
  final int actorId;
  final String actorName;
  const ActorDetailsPage({
    super.key,
    required this.actorId,
    required this.actorName,
  });

  @override
  State<ActorDetailsPage> createState() => _ActorDetailsPageState();
}

class _ActorDetailsPageState extends State<ActorDetailsPage> {
  bool isLoading = true;
  Map<String, dynamic>? actorDetails;
  List<dynamic> knownFor = [];

  @override
  void initState() {
    super.initState();
    _fetchActorDetails();
  }

  Future<void> _fetchActorDetails() async {
    try {
      final url =
          'https://api.themoviedb.org/3/person/${widget.actorId}?api_key=$tmdbApiKey&append_to_response=combined_credits';
      final data = await fetchWithCache(url);
      if (mounted) {
        setState(() {
          actorDetails = data;
          final cast = data['combined_credits']?['cast'] as List? ?? [];
          // Sort by vote count to show the most popular works first
          cast.sort((a, b) {
            final double popA =
                double.tryParse(a['vote_count']?.toString() ?? '0') ?? 0.0;
            final double popB =
                double.tryParse(b['vote_count']?.toString() ?? '0') ?? 0.0;
            return popB.compareTo(popA);
          });
          // Filter out unreleased titles and grab the top 20
          knownFor = cast
              .where((item) => _isReleased(item, strictFilter: true))
              .take(20)
              .toList();
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    if (isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F1014),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: const Center(
          child: CircularProgressIndicator(
            color: Color.fromARGB(255, 255, 255, 255),
          ),
        ),
      );
    }

    if (actorDetails == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F1014),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: const Center(
          child: Text(
            'Failed to load actor details.',
            style: TextStyle(color: Colors.white),
          ),
        ),
      );
    }

    final details = actorDetails!;
    final profilePath = details['profile_path']?.toString();
    final imageUrl = profilePath != null
        ? 'https://image.tmdb.org/t/p/w500$profilePath'
        : 'https://via.placeholder.com/500x750?text=No+Image';
    final biography =
        details['biography']?.toString() ?? 'No biography available.';
    final birthday = details['birthday']?.toString() ?? '';
    final deathday = details['deathday']?.toString() ?? '';
    final placeOfBirth = details['place_of_birth']?.toString() ?? '';
    final knownForDepartment =
        details['known_for_department']?.toString() ?? '';

    String ageStr = '';
    if (birthday.isNotEmpty) {
      try {
        final bDate = DateTime.parse(birthday);
        final eDate = deathday.isNotEmpty
            ? DateTime.parse(deathday)
            : DateTime.now();
        int age = eDate.year - bDate.year;
        if (eDate.month < bDate.month ||
            (eDate.month == bDate.month && eDate.day < bDate.day)) {
          age--;
        }
        ageStr = ' (Age $age)';
      } catch (_) {}
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F1014),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.actorName,
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12.0),
                  // Added httpHeaders to CachedNetworkImage
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    width: isMobile ? 120 : 200,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => Container(
                      width: isMobile ? 120 : 200,
                      height: isMobile ? 180 : 300,
                      color: Colors.white24,
                    ),
                    errorWidget: (context, url, error) => Container(
                      width: isMobile ? 120 : 200,
                      height: isMobile ? 180 : 300,
                      color: Colors.white24,
                      child: const Icon(
                        Icons.person,
                        color: Colors.white54,
                        size: 50,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.actorName,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: isMobile ? 24 : 32,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (knownForDepartment.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            'Known For: $knownForDepartment',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      if (birthday.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            'Born: $birthday${deathday.isEmpty ? ageStr : ''}',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      if (deathday.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            'Died: $deathday$ageStr',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      if (placeOfBirth.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            'Place of Birth: $placeOfBirth',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            const Text(
              'Biography',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              biography,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 40),
            if (knownFor.isNotEmpty)
              HorizontalMediaList(categoryTitle: 'Known For', items: knownFor),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class TrailerPlayerDialog extends StatefulWidget {
  final String trailerKey;
  const TrailerPlayerDialog({super.key, required this.trailerKey});

  @override
  State<TrailerPlayerDialog> createState() => _TrailerPlayerDialogState();
}

class _TrailerPlayerDialogState extends State<TrailerPlayerDialog> {
  YoutubePlayerController? _ytController;
  WebViewController? _webController;
  bool _isLoading = true;
  bool _hasFailed = false;
  bool _triedFallbackProxy = false;

  @override
  void initState() {
    super.initState();
    final useWebView =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    if (useWebView) {
      late final PlatformWebViewControllerCreationParams params;
      if (defaultTargetPlatform == TargetPlatform.windows) {
        params = WindowsWebViewControllerCreationParams();
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        params = WebKitWebViewControllerCreationParams(
          allowsInlineMediaPlayback: true,
          mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        );
      } else {
        params = const PlatformWebViewControllerCreationParams();
      }

      _webController = WebViewController.fromPlatformCreationParams(params)
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..setUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        );

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          (_webController!.platform as dynamic)
              .setMediaPlaybackRequiresUserGesture(false);
        } catch (_) {}
      }

      _webController!.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
            _webController!.runJavaScript('''
                setTimeout(function() {
                try {
                  var doc = document.querySelector('iframe') ? document.querySelector('iframe').contentWindow.document : document;
                  var playBtn = doc.querySelector('.ytp-large-play-button');
                  if (playBtn) playBtn.click();
                  var video = doc.querySelector('video');
                  if (video && video.paused) video.play();
                } catch(e) {}
                }, 800);
              ''');
          },
          onWebResourceError: (error) {
            debugPrint('Webview Resource Error: \${error.description}');
            if (!_triedFallbackProxy &&
                (error.description.toLowerCase().contains('refused') ||
                    error.description.toLowerCase().contains('connection') ||
                    error.description.toLowerCase().contains('failed'))) {
              setState(() => _triedFallbackProxy = true);
              _loadHtml();
              return;
            }
            if (error.isForMainFrame == true) {
              _fallbackToExternal();
            }
          },
          onHttpError: (error) {
            debugPrint('Webview HTTP Error: \${error.response?.statusCode}');
            if (!_triedFallbackProxy &&
                (error.response?.statusCode == 502 ||
                    error.response?.statusCode == 503 ||
                    error.response?.statusCode == 403)) {
              setState(() => _triedFallbackProxy = true);
              _loadHtml();
            }
          },
        ),
      );
      _loadHtml();
    } else {
      _ytController = YoutubePlayerController.fromVideoId(
        videoId: widget.trailerKey,
        autoPlay: true,
        params: const YoutubePlayerParams(
          showControls: true,
          showFullscreenButton: true,
          mute: false,
          showVideoAnnotations: false,
        ),
      );
      _isLoading = false;
    }
  }

  void _loadHtml() {
    final youtubeUrl =
        'https://www.youtube.com/embed/${widget.trailerKey}?autoplay=1&playsinline=1&origin=http://localhost';
    final proxyUrl = _triedFallbackProxy
        ? 'https://cors-anywhere.com/$youtubeUrl'
        : 'https://corsproxy.io/?${Uri.encodeComponent(youtubeUrl)}';

    _webController!.loadHtmlString('''
      <!DOCTYPE html>
      <html>
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>
          body { margin: 0; padding: 0; background-color: black; overflow: hidden; }
          iframe { width: 100vw; height: 100vh; border: none; }
        </style>
      </head>
      <body>
        <iframe 
          src="$proxyUrl" 
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" 
          allowfullscreen>
        </iframe>
      </body>
      </html>
    ''', baseUrl: 'https://localhost:5000');
  }

  Future<void> _fallbackToExternal() async {
    if (!mounted || _hasFailed) return;
    _hasFailed = true;
    setState(() => _isLoading = false);
    final url = Uri.parse(
      'https://www.youtube.com/watch?v=${widget.trailerKey}',
    );
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _ytController?.close();
    if (_webController != null) {
      _webController!.loadRequest(Uri.parse('about:blank'));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final useWebView =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    return Dialog(
      backgroundColor: isMobile
          ? Colors.black.withOpacity(0.95)
          : Colors.transparent,
      insetPadding: isMobile
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Container(
        width: isMobile ? double.infinity : null,
        height: isMobile ? double.infinity : null,
        constraints: const BoxConstraints(maxWidth: 800),
        child: Column(
          mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            SafeArea(
              bottom: false,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (useWebView && !isMobile)
                    TextButton.icon(
                      onPressed: () async {
                        final url = Uri.parse(
                          'https://www.youtube.com/watch?v=${widget.trailerKey}',
                        );
                        if (await canLaunchUrl(url)) {
                          await launchUrl(
                            url,
                            mode: LaunchMode.externalApplication,
                          );
                        }
                      },
                      icon: const Icon(
                        Icons.open_in_browser,
                        color: Colors.white,
                      ),
                      label: const Text(
                        'Watch Externally',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 30,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            if (isMobile) const Spacer(),
            ClipRRect(
              borderRadius: BorderRadius.circular(isMobile ? 0 : 12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: useWebView
                    ? Stack(
                        children: [
                          WebViewWidget(controller: _webController!),
                          if (_isLoading)
                            const Center(
                              child: CircularProgressIndicator(
                                color: Color.fromARGB(255, 255, 255, 255),
                              ),
                            ),
                        ],
                      )
                    : (_ytController != null
                          ? YoutubePlayer(controller: _ytController!)
                          : const SizedBox.shrink()),
              ),
            ),
            if (isMobile) const Spacer(flex: 2),
          ],
        ),
      ),
    );
  }
}

class FullscreenTrailerPage extends StatefulWidget {
  final String trailerKey;
  const FullscreenTrailerPage({super.key, required this.trailerKey});

  @override
  State<FullscreenTrailerPage> createState() => _FullscreenTrailerPageState();
}

class _FullscreenTrailerPageState extends State<FullscreenTrailerPage> {
  WebViewController? _webController;
  YoutubePlayerController? _ytController;
  bool _isLoading = true;
  Timer? _fallbackTimer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _fallbackTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _isLoading) setState(() => _isLoading = false);
    });

    final useWebView =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    if (useWebView) {
      late final PlatformWebViewControllerCreationParams params;
      if (defaultTargetPlatform == TargetPlatform.windows) {
        params = WindowsWebViewControllerCreationParams();
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        params = WebKitWebViewControllerCreationParams(
          allowsInlineMediaPlayback: true,
          mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
        );
      } else {
        params = const PlatformWebViewControllerCreationParams();
      }

      _webController = WebViewController.fromPlatformCreationParams(params)
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.black)
        ..addJavaScriptChannel(
          'FlutterVideo',
          onMessageReceived: (message) {
            if (message.message == 'playing' && mounted) {
              setState(() => _isLoading = false);
            } else if (message.message == 'ended' && mounted) {
              Navigator.of(context).pop();
            }
          },
        );

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          (_webController!.platform as dynamic)
              .setMediaPlaybackRequiresUserGesture(false);
        } catch (_) {}
      }

      final html =
          '''
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
          <style>
            body { margin: 0; background: black; overflow: hidden; }
            iframe { border: none; width: 100vw; height: 100vh; }
          </style>
        </head>
        <body>
          <div id="player"></div>
          <script>
            var tag = document.createElement('script');
            tag.src = "https://www.youtube.com/iframe_api";
            var firstScriptTag = document.getElementsByTagName('script')[0];
            firstScriptTag.parentNode.insertBefore(tag, firstScriptTag);
            
            var player;
            function onYouTubeIframeAPIReady() {
              player = new YT.Player('player', {
                height: '100%',
                width: '100%',
                videoId: '${widget.trailerKey}',
                playerVars: {
                  'autoplay': 1,
                  'controls': 1,
                  'disablekb': 0,
                  'fs': 0,
                  'modestbranding': 1,
                  'playsinline': 1,
                  'rel': 0,
                  'showinfo': 0,
                  'iv_load_policy': 3
                },
                events: {
                  'onReady': function(event) {
                    event.target.playVideo();
                  },
                  'onStateChange': function(event) {
                    if (event.data == YT.PlayerState.PLAYING) {
                      if (typeof FlutterVideo !== 'undefined') FlutterVideo.postMessage('playing');
                      else if (window.FlutterVideo) window.FlutterVideo.postMessage('playing');
                    } else if (event.data == YT.PlayerState.ENDED) {
                      if (typeof FlutterVideo !== 'undefined') FlutterVideo.postMessage('ended');
                      else if (window.FlutterVideo) window.FlutterVideo.postMessage('ended');
                    }
                  }
                }
              });
            }
          </script>
        </body>
        </html>
      ''';
      _webController!.loadHtmlString(html, baseUrl: 'http://localhost:5000');
    } else {
      _ytController = YoutubePlayerController.fromVideoId(
        videoId: widget.trailerKey,
        autoPlay: true,
        params: const YoutubePlayerParams(
          showControls: true,
          showFullscreenButton: true,
          mute: false,
          pointerEvents: PointerEvents.auto,
        ),
      );
      _ytController!.listen((event) {
        if (event.playerState == PlayerState.playing && mounted && _isLoading) {
          setState(() => _isLoading = false);
        } else if (event.playerState == PlayerState.ended && mounted) {
          Navigator.of(context).pop();
        }
      });
    }
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    _ytController?.close();
    if (_webController != null) {
      _webController!.loadRequest(Uri.parse('about:blank'));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final useWebView =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (useWebView && _webController != null)
            Positioned.fill(child: WebViewWidget(controller: _webController!))
          else if (!useWebView && _ytController != null)
            Positioned.fill(child: YoutubePlayer(controller: _ytController!)),

          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(
                color: Color.fromARGB(255, 255, 255, 255),
              ),
            ),

          Positioned(
            top: 20,
            left: 20,
            child: SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 24),
                  onPressed: () => Navigator.of(context).pop(),
                ), // Back button
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class VideoPlayerPage extends StatefulWidget {
  final String videoUrl; // Used for direct links (Live TV)
  final List<Map<String, String>>? sources;
  final String? matchTitle;
  final dynamic media;
  final int? season;
  final int? episode;
  final Map<String, String>? customHeaders;

  const VideoPlayerPage({
    super.key,
    required this.videoUrl,
    this.sources,
    this.matchTitle,
    this.media,
    this.season,
    this.episode,
    this.customHeaders,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> with TickerProviderStateMixin {
  late final Player _player = Player();
  late final VideoController _videoController = VideoController(_player);
  Timer? _controlsTimer;
  bool _isControlsVisible = true;
  PlayerMenu _activeMenu = PlayerMenu.none;
  bool _isLoading = true;
  late AnimationController _loadingProgressController;
  String? _errorMessage;

  List<dynamic> _qualities = [];
  String? _selectedQuality;
  List<dynamic> _subtitles = [];
  Duration? _pendingSeek;

  // ignore: unused_field
  String? _selectedSubtitle;

  bool _isHoveringSeekBar = false;
  bool _isHoveringVolume = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _bufferSub;
  StreamSubscription? _trackSub;

  @override
  void initState() {
    super.initState();
    _loadingProgressController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..animateTo(0.9, curve: Curves.easeOut);

    _setOrientation();
    _resetControlsTimer();

    _posSub = _player.stream.position.listen((p) {
        if (mounted) {
          setState(() => _position = p);
        }
      });
      _durSub = _player.stream.duration.listen((d) {
      setState(() {
        _duration = d;
      });
    });
    _bufferSub = _player.stream.buffer.listen((b) {
      if (mounted) setState(() => _buffer = b);
    });
    _player.stream.volume.listen((_) {
      if (mounted) setState(() {});
    });
    _trackSub = _player.stream.tracks.listen((_) {
      if (mounted) setState(() {});
    });

    _resolveStream();
  }

  void _saveProgressToDb({Duration? customPosition}) {
    if (widget.media != null && _duration.inSeconds > 0) {
      final Duration pos = customPosition ?? _player.state.position;
      ProgressManager.saveProgress(
        media: widget.media!,
        progress: (pos.inSeconds / _duration.inSeconds).clamp(0.0, 1.0),
        season: widget.season,
        episode: widget.episode,
        position: pos.inSeconds,
        runtime: _duration.inMinutes,
      );
    }
  }

  Future<void> _resolveStream() async {
    if (widget.media == null) {
      // Direct playback for Live TV
      await _setupNativePlayer(widget.videoUrl);
      if (mounted) {
        _loadingProgressController.animateTo(1.0, duration: const Duration(milliseconds: 400)).then((_) {
          if (mounted) setState(() => _isLoading = false);
        });
      }
      return;
    }

    final String tmdbId = (widget.media['id'] ?? '').toString();
    final String mediaType = (widget.media['media_type'] ?? 'movie').toString();
    final bool isTv = mediaType == 'tv';
    final int s = widget.season ?? 1;
    final int ep = widget.episode ?? 1;

    try {
      String provider = mediaType == 'movie' ? 'cdn' : 'mb-flix';
      String sourcesUrl = 'https://api.videasy.net/$provider/sources-with-title?mediaType=$mediaType&episodeId=$ep&seasonId=$s&tmdbId=$tmdbId';
      var sourcesRes = await http.get(Uri.parse(sourcesUrl)).timeout(const Duration(seconds: 10));

      // Fallback logic for movies: if 'cdn' fails, try 'mb-flix'
      if (mediaType == 'movie' && provider == 'cdn' && sourcesRes.statusCode != 200) {
        provider = 'mb-flix';
        sourcesUrl = 'https://api.videasy.net/$provider/sources-with-title?mediaType=$mediaType&episodeId=$ep&seasonId=$s&tmdbId=$tmdbId';
        sourcesRes = await http.get(Uri.parse(sourcesUrl)).timeout(const Duration(seconds: 10));
      }

      if (sourcesRes.statusCode != 200) throw "Failed to reach Source API.";
      
      String encryptedText = sourcesRes.body.trim();
      try {
        final decodedBody = jsonDecode(encryptedText);
        if (decodedBody is String) encryptedText = decodedBody;
      } catch (_) {}

      // 2. Decode encrypted text via POST
      final decRes = await http.post(
        Uri.parse('https://enc-dec.app/api/dec-videasy'),
        headers: {
          'Accept': '*/*',
          'Accept-Encoding': 'deflate, gzip',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:150.0) Gecko/20100101 Firefox/150.0',
          'Host': 'enc-dec.app',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({"text": encryptedText, "id": tmdbId}),
      ).timeout(const Duration(seconds: 10));

      if (decRes.statusCode != 200) throw "Decryption failed.";
      
      final decoded = jsonDecode(decRes.body);
      final List<dynamic> result;
      List<dynamic> subs = [];
      
      if (decoded is Map && decoded['result'] is Map && decoded['result']['sources'] is List) {
        result = decoded['result']['sources'];
        subs = decoded['result']['subtitles'] as List? ?? [];
      } else if (decoded is List) {
        result = decoded;
      } else if (decoded is Map && decoded['sources'] is List) {
        result = decoded['sources'];
        subs = decoded['subtitles'] as List? ?? [];
      } else if (decoded is Map && decoded['data'] is List) {
        result = decoded['data'];
      } else if (decoded is Map && decoded['links'] is List) {
        result = decoded['links'];
      } else if (decoded is Map && decoded['result'] is List) {
        result = decoded['result']; 
      } else if (decoded is Map && decoded.containsKey('file')) {
        result = [decoded];
        subs = decoded['subtitles'] as List? ?? [];
      } else {
        debugPrint("Decryption API Response: ${decRes.body}");
        throw "Could not find a valid list of streams. Check the debug console.";
      }

      if (result.isEmpty) throw "No stream links found.";

      final prefs = await SharedPreferences.getInstance();
      final preferredQuality = prefs.getString('preferred_video_quality');
      final dataSaver = prefs.getBool('data_saver_enabled') ?? false;

      if (mounted) {
        setState(() {
          _qualities = result;
          _subtitles = subs;
          _qualities.sort((a, b) {
            int getVal(dynamic q) {
              final String s = q['quality']?.toString().toLowerCase() ?? '';
              if (s.contains('4k') || s.contains('2160')) return 4000;
              if (s.contains('2k') || s.contains('1440')) return 2000;
              return int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
            }
            return getVal(b).compareTo(getVal(a));
          });

          dynamic matchedQuality;
          if (dataSaver) {
            matchedQuality = _qualities.firstWhere(
              (q) => q['quality']?.toString().toLowerCase().contains('480') ?? false,
              orElse: () => null,
            );
            matchedQuality ??= _qualities.last; // Fallback to lowest resolution if 480p not found
          } else if (preferredQuality != null) {
            matchedQuality = _qualities.firstWhere(
              (q) => q['quality']?.toString() == preferredQuality,
              orElse: () => null,
            );
          }
          _selectedQuality = matchedQuality != null ? (matchedQuality['url'] ?? matchedQuality['file']) : (_qualities.first['url'] ?? _qualities.first['file']);
        });

        final progressData = await ProgressManager.getProgress(tmdbId, season: isTv ? s : null, episode: isTv ? ep : null);
        if (progressData != null && progressData['position'] != null) {
          _pendingSeek = Duration(seconds: (progressData['position'] as num).toInt());
        }

        await _setupNativePlayer(_selectedQuality!);
        _loadingProgressController.animateTo(1.0, duration: const Duration(milliseconds: 400)).then((_) {
          if (mounted) setState(() => _isLoading = false);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _setupNativePlayer(String url) async {
    final Map<String, String> headers = widget.customHeaders ?? {
          "Referer": "https://player.videasy.net/",
          "Origin": "https://player.videasy.net",
          "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        };

    if (!kIsWeb && _player.platform is NativePlayer) {
      final dynamic nativePlayer = _player.platform;
      try {
        await nativePlayer.setProperty('referrer', headers['Referer'] ?? 'https://player.videasy.net/');
        await nativePlayer.setProperty('user-agent', headers['User-Agent'] ?? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36');
        
        final headerFields = headers.entries.map((e) => "${e.key}: ${e.value}").join(',');
        await nativePlayer.setProperty('http-header-fields', headerFields);
      } catch (e) {
        debugPrint("Failed to set native player headers: $e");
      }
    }

    await _player.open(
      Media(
        url,
        httpHeaders: headers,
      ),
      play: false,
    );
    if (_pendingSeek != null) {
      // On Windows/Desktop, libmpv often reports zero duration briefly while 
      // parsing stream headers. We must wait for a valid duration before seeking.
      int attempts = 0;
      while (_player.state.duration == Duration.zero && attempts < 100) {
        await Future.delayed(const Duration(milliseconds: 50));
        attempts++;
      }

      await _player.seek(_pendingSeek!);
      _pendingSeek = null;
    }
    _player.play();
  }

  void _setOrientation() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _resetControlsTimer() {
    _controlsTimer?.cancel();
    setState(() => _isControlsVisible = true);
    if (!_isControlsVisible) _activeMenu = PlayerMenu.none;
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() {
          _isControlsVisible = false;
          _activeMenu = PlayerMenu.none;
        });
      }
    });
      
  }

  @override
  void dispose() {
    
    _controlsTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _bufferSub?.cancel();
    _trackSub?.cancel();
     _player.dispose();
    _loadingProgressController.dispose();
    if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.macOS)) {
      windowManager.setFullScreen(false);
    }
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

   String _formatDuration(Duration d) {
    final String mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) return "${d.inHours}:$mm:$ss";
    return "${d.inMinutes}:$ss";
  }

  @override
  Widget build(BuildContext context) {
    final int subCount = _subtitles.length + _player.state.tracks.subtitle.length;
    final double subHeight = (subCount * 48.0 + 16.0).clamp(0.0, 300.0);
    final double qualHeight = (_qualities.length * 48.0 + 16.0).clamp(0.0, 300.0);

    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onHover: (_) => _resetControlsTimer(),
        child: GestureDetector(
          onTap: () {
            if (_activeMenu != PlayerMenu.none) setState(() => _activeMenu = PlayerMenu.none);
            _resetControlsTimer();
          },
          child: Stack(
            alignment: Alignment.center,
            children: [
              Video(
                controller: _videoController,
                fill: Colors.black,
                controls: NoVideoControls,
              ),
              
              if (_isLoading && _errorMessage == null)
                Positioned(
                  top: 0, left: 0, right: 0,
                  child: SafeArea(
                    child: AnimatedBuilder(
                      animation: _loadingProgressController,
                      builder: (context, child) => LinearProgressIndicator(
                        value: _loadingProgressController.value,
                        backgroundColor: Colors.white10,
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF1CE783)),
                        minHeight: 2,
                      ),
                    ),
                  ),
                ),
              if (_isLoading && _errorMessage == null)
                const Center(child: CircularProgressIndicator(color: Colors.white24, strokeWidth: 2)),

              if (_errorMessage != null)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 48),
                      const SizedBox(height: 16),
                      Text(_errorMessage!, style: const TextStyle(color: Colors.white70)),
                      const SizedBox(height: 16),
                      ElevatedButton(onPressed: _resolveStream, child: const Text("Retry"))
                    ],
                  ),
                ),

              // Native Custom Controls UI
              AnimatedOpacity(
                opacity: _isControlsVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: IgnorePointer(
                  ignoring: !_isControlsVisible,
                  child: Stack(
                    children: [
                      // Gradient Overlays
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.black54, Colors.transparent, Colors.transparent, Colors.black87],
                              stops: const [0.0, 0.2, 0.7, 1.0],
                            ),
                          ),
                        ),
                      ),
                      
                      // Top Bar
                      Positioned(
                        top: 20,
                        left: 20,
                        right: 20,
                        child: SafeArea(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_back, color: Colors.white, size: 30),
                                onPressed: () {
                                  _saveProgressToDb();
                                  Navigator.pop(context, true);
                                },
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Seek Bar
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: SafeArea(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.media != null)
                                MouseRegion(
                                  onEnter: (_) => setState(() => _isHoveringSeekBar = true),
                                  onExit: (_) => setState(() => _isHoveringSeekBar = false),
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      return GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onHorizontalDragUpdate: (details) {
                                          final box = context.findRenderObject() as RenderBox;
                                          final dx = details.localPosition.dx;
                                          final pct = (dx / box.size.width).clamp(0.0, 1.0);
                                          final target = _duration * pct;
                                          _player.seek(target);
                                          _resetControlsTimer();
                                        },
                                        onHorizontalDragEnd: (_) => _saveProgressToDb(),
                                        onTapDown: (details) {
                                          final box = context.findRenderObject() as RenderBox;
                                          final dx = details.localPosition.dx;
                                          final pct = (dx / box.size.width).clamp(0.0, 1.0);
                                          final target = _duration * pct;
                                          _player.seek(target);
                                          _resetControlsTimer();
                                          _saveProgressToDb(customPosition: target);
                                        },
                                        child: Container(
                                          height: 20, // Touch target
                                          alignment: Alignment.center,
                                          child: Stack(
                                            children: [
                                              // Background
                                              Container(
                                                height: _isHoveringSeekBar ? 6 : 4,
                                                width: double.infinity,
                                                color: Colors.white10,
                                              ),
                                              // Buffer
                                              FractionallySizedBox(
                                                widthFactor: _duration.inSeconds > 0 
                                                    ? (_buffer.inSeconds / _duration.inSeconds).clamp(0.0, 1.0) 
                                                    : 0.0,
                                                child: Container(
                                                  height: _isHoveringSeekBar ? 6 : 4,
                                                  color: Colors.white24,
                                                ),
                                              ),
                                              // Progress
                                              FractionallySizedBox(
                                                widthFactor: _duration.inSeconds > 0 
                                                    ? (_position.inSeconds / _duration.inSeconds).clamp(0.0, 1.0) 
                                                    : 0.0,
                                                child: Container(
                                                  height: _isHoveringSeekBar ? 6 : 4,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                child: Row(
                                  children: [
                                    // Left Side
                                    IconButton(
                                      icon: Icon(_player.state.playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
                                      onPressed: () { 
                                        _player.playOrPause(); 
                                        _resetControlsTimer(); 
                                        _saveProgressToDb();
                                      },
                                    ),
                                    if (widget.media != null) ...[
                                      IconButton(
                                        icon: const Icon(Icons.replay_10, color: Colors.white),
                                        onPressed: () {
                                          final target = _player.state.position - const Duration(seconds: 10);
                                          _player.seek(target);
                                          _resetControlsTimer();
                                          _saveProgressToDb(customPosition: target);
                                        },
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.forward_10, color: Colors.white),
                                        onPressed: () {
                                          final target = _player.state.position + const Duration(seconds: 10);
                                          _player.seek(target);
                                          _resetControlsTimer();
                                          _saveProgressToDb(customPosition: target);
                                        },
                                      ),
                                    ],
                                    const SizedBox(width: 8),
                                    MouseRegion(
                                      onEnter: (_) => setState(() => _isHoveringVolume = true),
                                      onExit: (_) => setState(() => _isHoveringVolume = false),
                                      child: Row(
                                        children: [
                                          IconButton(
                                            icon: Icon(_player.state.volume == 0 ? Icons.volume_off : Icons.volume_up, color: Colors.white),
                                            onPressed: () { _player.setVolume(_player.state.volume == 0 ? 100 : 0); _resetControlsTimer(); },
                                          ),
                                          AnimatedContainer(
                                            duration: const Duration(milliseconds: 200),
                                            width: _isHoveringVolume ? 50 : 0,
                                            child: _isHoveringVolume 
                                              ? SliderTheme(
                                                  data: SliderTheme.of(context).copyWith(
                                                    trackHeight: 2,
                                                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                                                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                                                  ),
                                                  child: Slider(
                                                    value: _player.state.volume / 100.0,
                                                    activeColor: Colors.white,
                                                    inactiveColor: Colors.white24,
                                                    onChanged: (v) {
                                                      _player.setVolume(v * 100);
                                                      _resetControlsTimer();
                                                    },
                                                  ),
                                                )
                                              : const SizedBox.shrink(),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    if (widget.media == null)
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.circle, color: Colors.red, size: 8),
                                          const SizedBox(width: 8),
                                          const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                                        ],
                                      )
                                    else ...[
                                      Text(_formatDuration(_position), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                      const Text(' / ', style: TextStyle(color: Colors.white24, fontSize: 12)),
                                      Text(_formatDuration(_duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                    ],
                                    
                                    const Spacer(),
                                    
                                    // Right Side
                                    if (_subtitles.isNotEmpty || _player.state.tracks.subtitle.length > 1)
                                      IconButton(
                                        icon: const Icon(Icons.subtitles, color: Colors.white),
                                        onPressed: () => _toggleMenu(PlayerMenu.subtitles),
                                      ),
                                    if (_qualities.isNotEmpty)
                                      IconButton(
                                        icon: const Icon(Icons.settings, color: Colors.white),
                                        onPressed: () => _toggleMenu(PlayerMenu.quality),
                                      ),
                                    IconButton(
                                      icon: const Icon(Icons.fullscreen, color: Colors.white),
                                      onPressed: () async {
                                        if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.macOS)) {
                                          bool isFull = await windowManager.isFullScreen();
                                          await windowManager.setFullScreen(!isFull);
                                        } else if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
                                          bool isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
                                          SystemChrome.setPreferredOrientations(isPortrait ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : [DeviceOrientation.portraitUp]);
                                          SystemChrome.setEnabledSystemUIMode(isPortrait ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              
              // Custom Menu Overlays
              if (_isControlsVisible) ...[
                _buildSubtitlesMenu(subHeight),
                _buildQualityMenu(qualHeight),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _toggleMenu(PlayerMenu menu) {
    _resetControlsTimer();
    setState(() {
      _activeMenu = _activeMenu == menu ? PlayerMenu.none : menu;
    });
  }

  Widget _buildMenuContainer({required bool visible, required double height, required double right, required Widget child}) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      bottom: visible ? 80 : 40,
      right: right,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: visible ? 1.0 : 0.0,
        child: IgnorePointer(
          ignoring: !visible,
          child: Container(
            width: 220,
            height: height,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1F24),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
              boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
            ),
            child: Material(
              color: Colors.transparent,
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubtitlesMenu(double height) {
    return _buildMenuContainer(
      visible: _activeMenu == PlayerMenu.subtitles,
      height: height,
      right: 112,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ..._subtitles.map((s) {
            final url = s['file'] ?? s['url'];
            final String l = (s['language'] ?? 'Unknown').toString().split(' - ').first;
            final display = l.isEmpty ? 'Unknown' : l[0].toUpperCase() + l.substring(1).toLowerCase();
            
            return ListTile(
              dense: true,
              title: Text(display, style: const TextStyle(color: Colors.white)),
              onTap: () {
                _player.setSubtitleTrack(SubtitleTrack.uri(url));
                _toggleMenu(PlayerMenu.none);
              },
            );
          }),
          ..._player.state.tracks.subtitle.map((t) {
            final String l = (t.language ?? t.title ?? t.id).split(' - ').first;
            final display = l.isEmpty ? 'Unknown' : l[0].toUpperCase() + l.substring(1).toLowerCase();
            final isSelected = _player.state.track.subtitle == t;
            
            return ListTile(
              dense: true,
              title: Text(display, style: TextStyle(color: isSelected ? const Color(0xFF1CE783) : Colors.white, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
              trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF1CE783), size: 16) : null,
              onTap: () {
                _player.setSubtitleTrack(t);
                _toggleMenu(PlayerMenu.none);
              },
            );
          }),
        ],
      ),
    );
  }

  Widget _buildQualityMenu(double height) {
    return _buildMenuContainer(
      visible: _activeMenu == PlayerMenu.quality,
      height: height,
      right: 64,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _qualities.length,
        itemBuilder: (context, i) {
          final q = _qualities[i];
          final url = q['url'] ?? q['file'];
          final isSelected = url == _selectedQuality;
          
          return ListTile(
            dense: true,
            title: Text(q['quality'].toString(), style: TextStyle(color: isSelected ? const Color(0xFF1CE783) : Colors.white, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
            trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF1CE783), size: 16) : null,
            onTap: () async {
              final qualityStr = q['quality'].toString();
              _pendingSeek = _player.state.position;
              setState(() => _selectedQuality = url);
              await _setupNativePlayer(url);
              _toggleMenu(PlayerMenu.none);

              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('preferred_video_quality', qualityStr);
            },
          );
        },
      ),
    );
  }
}