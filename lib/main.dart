// ignore_for_file: use_null_aware_elements, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:video_player/video_player.dart';
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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
import 'firebase_options.dart';
import 'live_tv_page.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'schedule_guide_page.dart';
import 'web_player_stub.dart' if (dart.library.html) 'web_player.dart';
// ignore: unused_import
import 'web_button_stub.dart' if (dart.library.html) 'web_button.dart';
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
        final snapshot = await _db.collection('users').doc(user.uid).collection('watchlist').orderBy('added_at', descending: true).get();
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
      return items.map((item) => json.decode(item) as Map<String, dynamic>).toList();
    } catch (e) {
      await prefs.remove(_key);
      return [];
    }
  }

  static Future<bool> isOnWatchlist(int mediaId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final doc = await _db.collection('users').doc(user.uid).collection('watchlist').doc(mediaId.toString()).get();
      return doc.exists;
    }
    final watchlist = await getWatchlist();
    return watchlist.any((item) => item['id'] == mediaId);
  }

  static Future<void> addToWatchlist(Map<String, dynamic> media) async {
    final Map<String, dynamic> itemToCache = {
      'id': media['id'],
      'title': media['title'] ?? media['name'],
      'poster_path': media['poster_path'],
      'media_type': media['media_type'] ?? (media.containsKey('first_air_date') ? 'tv' : 'movie'),
      'added_at': DateTime.now().toIso8601String(),
    };

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await _db.collection('users').doc(user.uid).collection('watchlist').doc(media['id'].toString()).set(itemToCache);
    }

    final watchlist = await getWatchlist();
    if (watchlist.any((item) => item['id'] == media['id'])) return; // Already exists

    watchlist.insert(0, itemToCache);
    await _saveWatchlist(watchlist);
  }

  static Future<void> removeFromWatchlist(int mediaId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await _db.collection('users').doc(user.uid).collection('watchlist').doc(mediaId.toString()).delete();
    }

    final watchlist = await getWatchlist();
    watchlist.removeWhere((item) => item['id'] == mediaId);
    await _saveWatchlist(watchlist);
  }

  static Future<void> _saveWatchlist(List<Map<String, dynamic>> watchlist) async {
    final prefs = await SharedPreferences.getInstance();
    final items = watchlist.map((item) => json.encode(item)).toList();
    await prefs.setStringList(_key, items);
  }
}

class ProgressManager {
  static final _db = FirebaseFirestore.instance;

  static Future<void> saveProgress({
    required Map<String, dynamic> media,
    required double progress,
    int? season,
    int? episode,
    int? position,
    int? runtime,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final mediaId = media['id'].toString();
    final mediaType = media['media_type'] ?? (media.containsKey('first_air_date') ? 'tv' : 'movie');
    final isTv = mediaType == 'tv';
    
    // Unique ID for episodes, shared ID for movies
    // ignore: unnecessary_brace_in_string_interps
    final docId = isTv ? '${mediaId}_s${season}_e${episode}' : mediaId;

    final data = {
      'id': media['id'],
      'media_type': mediaType,
      'title': media['title'] ?? media['name'],
      'poster_path': media['poster_path'],
      'backdrop_path': media['backdrop_path'],
      'progress': progress,
      'is_completed': progress >= 0.9, // Mark as completed if > 90%
      'last_watched_at': FieldValue.serverTimestamp(),
   
      if (isTv) 'show_id': media['id'], // Reference for grouping
      if (season != null) 'season': season,
      if (episode != null) 'episode': episode,
      if (position != null) 'position': position,
      if (runtime != null) 'runtime': runtime,
    };

    await _db.collection('users').doc(user.uid).collection('progress').doc(docId).set(data, SetOptions(merge: true));
  }

  static Future<Map<String, dynamic>?> getProgress(int mediaId, {int? season, int? episode}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    final isTv = season != null && episode != null;
    // ignore: unnecessary_brace_in_string_interps
    final docId = isTv ? '${mediaId}_s${season}_e${episode}' : mediaId.toString();

    final doc = await _db.collection('users').doc(user.uid).collection('progress').doc(docId).get(); 
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

  static Future<List<Map<String, dynamic>>> getShowProgress(int showId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return [];

    final snapshot = await _db
        .collection('users')
        .doc(user.uid)
        .collection('progress')
        .where('show_id', isEqualTo: showId)
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
        .limit(60) // Fetch a larger pool to allow for filtering and deduplication
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
      // Note: Using collectionGroup requires creating an index in the Firebase Console.
      // This query looks at all 'progress' subcollections across all users.
      final snapshot = await _db
          .collectionGroup('progress')
          .orderBy('last_watched_at', descending: true)
          .limit(50)
          .get();

      final List<Map<String, dynamic>> results = [];
      final Set<String> seenIds = {};

      for (var doc in snapshot.docs) {
        final data = doc.data();
        final id = data['id']?.toString();
        if (id != null && !seenIds.contains(id)) {
          seenIds.add(id);
          results.add(data);
        }
        if (results.length >= 20) break;
      }
      return results;
    } catch (e) {
      debugPrint('Error fetching global trending: $e');
      return [];
    }
  }

  static Future<void> deleteProgress(int mediaId, String mediaType, {int? season, int? episode}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (mediaType == 'tv') {
      // Delete all episodes for this show
      final snapshot = await _db
          .collection('users')
          .doc(user.uid)
          .collection('progress')
          .where('show_id', isEqualTo: mediaId)
          .get();

      final batch = _db.batch();
      for (var doc in snapshot.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    } else {
      final docId = mediaId.toString();
      await _db.collection('users').doc(user.uid).collection('progress').doc(docId).delete();
    }
  }
  static Future<void> clearWatchHistory() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final snapshot = await _db.collection('users').doc(user.uid).collection('progress').get();

    final batch = _db.batch();
    for (var doc in snapshot.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }
}

bool _isGoogleSignInInitialized = false;
bool _hasShownWebPopup = false;

dynamic _parseJson(String text) => json.decode(text);
const int _maxCacheSize = 100;

Future<dynamic> fetchWithCache(String url) async {
  if (_apiCache.containsKey(url)) {
    final val = _apiCache.remove(url);
    _apiCache[url] = val;
    return val;
  }
  try {
    final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
    if (response.statusCode == 200) {
      List<int> bytes = response.bodyBytes;

      // Manual Gzip check: Some network environments or proxies return compressed data 
      // without the correct 'Content-Encoding' header, causing utf8.decode to fail.
      // Gzip magic number is 0x1F 0x8B.
      if (!kIsWeb && bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
        bytes = gzip.decode(bytes);
      }

      final String decodedBody = utf8.decode(bytes);
      // PERFORMANCE: Offload JSON decoding to a separate isolate on native platforms
      // to keep the UI thread responsive during large data processing.
      final data = (kIsWeb || decodedBody.length < 10000) 
          ? json.decode(decodedBody) 
          : await compute(_parseJson, decodedBody);

      _apiCache[url] = data;
      if (_apiCache.length > _maxCacheSize) _apiCache.remove(_apiCache.keys.first);
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

  if (strictFilter) {
    // Hide documentaries (Genre ID 99) from general browsing/home pages
    if (item['genre_ids'] is List && (item['genre_ids'] as List).contains(99)) {
      return false;
    }

    final originalLanguage = item['original_language']?.toString();
    if (originalLanguage != null && originalLanguage != 'en') {
      final originCountry = item['origin_country'];
      bool isUS = false;
      if (originCountry is List) {
        isUS = originCountry.contains('US');
      } else if (originCountry is String) {
        isUS = originCountry == 'US';
      }
      if (!isUS) {
        final voteCount = (item['vote_count'] as num?)?.toInt() ?? 0;
        final popularity = (item['popularity'] as num?)?.toDouble() ?? 0.0;
        if (voteCount < 50 && popularity < 20.0) {
          return false;
        }
      }
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
          item.containsKey('title') &&
          item.containsKey('release_date'));

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

    // FVP is for desktop platforms. On mobile, we want to use the default native players
    // which have better support for features like subtitle track selection. UPDATE: The native
    // iOS player (AVPlayer) is too strict and fails with -12848 errors on our downloaded
    // files. FVP uses a more lenient mpv-based player. We will enable it for iOS to
    // ensure compatibility with our multipart downloads.
    final isDesktopOrIOS = !kIsWeb && (
        defaultTargetPlatform == TargetPlatform.windows || 
        defaultTargetPlatform == TargetPlatform.linux || 
        defaultTargetPlatform == TargetPlatform.macOS || 
        defaultTargetPlatform == TargetPlatform.iOS);


    if (isDesktopOrIOS) {
      fvp.registerWith();
    }
    // Set preferred orientation to portrait on app startup for mobile.
    // This ensures the app doesn't start in landscape if it was closed
    // while a video was playing.
    if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }

    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
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

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFF0F1014),
            body: Center(
              child: CircularProgressIndicator(color: Color.fromARGB(255, 252, 253, 253)),
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
      AppNotification.show(context, 'Please enter both email and password.', color: Colors.red);
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
            serverClientId: '651005734001-6034o9sft52au196976sqjidjqo8a9nv.apps.googleusercontent.com',
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
        AppNotification.show(context, 'Successfully linked account!', color: Colors.green);
      }
    } on FirebaseAuthException catch (authError) {
      if (mounted) {
        AppNotification.show(context, 'Failed to link: ${authError.message}', color: Colors.red);
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
                      borderSide: BorderSide(color: Color.fromARGB(255, 82, 82, 82)),
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
                    borderSide: BorderSide(color: Color.fromARGB(255, 88, 88, 88)),
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
                    borderSide: BorderSide(color: Color.fromARGB(255, 76, 76, 76)),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              if (_isLoading)
                const CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255))
              else ...[
                defaultTargetPlatform == TargetPlatform.iOS
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                          child: Container(
                            height: 50,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.2),
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                foregroundColor: const Color.fromARGB(255, 80, 80, 80),
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
                          ),
                        ),
                      )
                    : ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color.fromARGB(255, 156, 156, 156),
                          foregroundColor: Colors.black,
                          minimumSize: const Size.fromHeight(50),
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
                    style: TextStyle(color: Color.fromARGB(255, 255, 255, 255)),
                  ),
                ),
                const SizedBox(height: 24),
                const Row(
                  children: [
                    Expanded(child: Divider(color: Colors.white24)),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'OR',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                    Expanded(child: Divider(color: Colors.white24)),
                  ],
                ),
                const SizedBox(height: 24),
                defaultTargetPlatform == TargetPlatform.iOS
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                          child: Container(
                            height: 50,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.05),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.15),
                              ),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide.none,
                              ),
                              onPressed: _signInWithGoogle,
                              icon: Image.network(
                                'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/48px-Google_%22G%22_logo.svg.png',
                                height: 24,
                                errorBuilder: (context, error, stackTrace) =>
                                    const Icon(Icons.account_circle, size: 24),
                              ),
                              label: const Text(
                                'Sign in with Google',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                    : OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(50),
                          side: const BorderSide(color: Colors.white54),
                        ),
                        onPressed: _signInWithGoogle,
                        icon: Image.network(
                          'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/48px-Google_%22G%22_logo.svg.png',
                          height: 24,
                          errorBuilder: (context, error, stackTrace) =>
                              const Icon(Icons.account_circle, size: 24),
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
                  defaultTargetPlatform == TargetPlatform.iOS
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                            child: Container(
                              height: 50,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.05),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.15),
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: BorderSide.none,
                                ),
                                onPressed: _signInWithMicrosoft,
                                icon: Image.network(
                                  'https://upload.wikimedia.org/wikipedia/commons/thumb/4/44/Microsoft_logo.svg/48px-Microsoft_logo.svg.png',
                                  height: 24,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const Icon(Icons.window, size: 24),
                                ),
                                label: const Text(
                                  'Sign in with Microsoft',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      : OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(50),
                            side: const BorderSide(color: Colors.white54),
                          ),
                          onPressed: _signInWithMicrosoft,
                          icon: Image.network(
                            'https://upload.wikimedia.org/wikipedia/commons/thumb/4/44/Microsoft_logo.svg/48px-Microsoft_logo.svg.png',
                            height: 24,
                            errorBuilder: (context, error, stackTrace) =>
                                const Icon(Icons.window, size: 24),
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
    );
  }
}

class SearchBody extends StatelessWidget {
  final List<dynamic> results;
  final List<dynamic> recentSearches;
  final List<dynamic> watchHistory;
  final bool isLoading;
  final Function(dynamic) onResultTapped;
  final String searchQuery;

  const SearchBody({
    super.key,
    required this.results,
    required this.recentSearches,
    required this.watchHistory,
    required this.isLoading,
    required this.onResultTapped,
    required this.searchQuery,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary( // Isolate list repaints to prevent full-page redraws on scroll
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: kToolbarHeight + MediaQuery.of(context).padding.top),
        Expanded(
          child: isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255)),
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
    )
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
            ? 'https://image.tmdb.org/t/p/w342$posterPath'
            : 'https://via.placeholder.com/500x750?text=No+Image';
        final heroTag =
            'search_${media['media_type']}_${media['id']}_$index';
        return GestureDetector(
          onTap: () {
            onResultTapped(media);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => MediaDetailsPage(
                  media: media,
                  heroTag: heroTag,
                ),
              ),
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8.0),
            child: Hero(
              tag: heroTag,
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                memCacheWidth: 342,
                fit: BoxFit.cover,
                placeholder: (context, url) =>
                    Container(color: Colors.black26),
                errorWidget: (context, url, error) => Container(
                  color: Colors.black26,
                  child: const Icon(
                    Icons.broken_image,
                    color: Colors.white54,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class LocalVideoPlayerPage extends StatefulWidget {
  final File videoFile;
  final String title;
  const LocalVideoPlayerPage({super.key, required this.videoFile, required this.title});

  @override
  State<LocalVideoPlayerPage> createState() => _LocalVideoPlayerPageState();
}

class _LocalVideoPlayerPageState extends State<LocalVideoPlayerPage> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isControlsVisible = true;
  Timer? _controlsTimer;
  String? _initializationError;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeRight,
      DeviceOrientation.landscapeLeft,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _initializePlayer();
  }
  Future<void> _initializePlayer() async {
    debugPrint("[FVP_PLAYER_DEBUG] _initializePlayer: Starting.");
    debugPrint("[FVP_PLAYER_DEBUG] Video file path: ${widget.videoFile.path}");
    final fileExists = await widget.videoFile.exists();
    debugPrint("[FVP_PLAYER_DEBUG] File exists: $fileExists");

    if (!fileExists) {
      if (mounted) setState(() => _initializationError = "File not found: ${widget.videoFile.path}");
      return;
    }

    try {
      debugPrint("[FVP_PLAYER_DEBUG] Creating VideoPlayerController...");
      // Using networkUrl with a file URI can sometimes be more reliable across platforms
      _controller = VideoPlayerController.file(widget.videoFile);
      _controller!.addListener(() {
        if (!mounted) return;
        if (_controller!.value.hasError) {
          debugPrint("[FVP_PLAYER_DEBUG] ERROR: ${_controller!.value.errorDescription}");
        }
        setState(() {});
      });

      debugPrint("[FVP_PLAYER_DEBUG] Initializing controller...");
      await _controller!.initialize();
      debugPrint("[FVP_PLAYER_DEBUG] Controller initialized.");

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
        _controller!.play();
        _resetControlsTimer();
      }
      debugPrint("[FVP_PLAYER_DEBUG] _initializePlayer: Finished.");
    } catch (e, s) {
      debugPrint("[FVP_PLAYER_DEBUG] CRITICAL ERROR during controller creation/initialization: $e\n$s");
      String errorMessage = "Failed to create player: $e";
      if (e.toString().contains("Failed to load dynamic library 'fvp.framework/fvp'")) {
        errorMessage = "Failed to initialize the video player's native library (fvp.framework).\n\nPlease ensure your iOS project is correctly configured. This usually involves adding 'use_frameworks!' to your ios/Podfile and rebuilding the app.";
      }
      if (mounted) setState(() => _initializationError = errorMessage);
    }
  }

  void _resetControlsTimer() {
    _controlsTimer?.cancel();
    if (mounted) {
      setState(() => _isControlsVisible = true);
      _controlsTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _isControlsVisible = false);
      });
    }
  }

  @override
  void dispose() {
    debugPrint("[FVP_PLAYER_DEBUG] dispose: Starting.");
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _controlsTimer?.cancel();
    _controller?.dispose();
    debugPrint("[FVP_PLAYER_DEBUG] dispose: Finished.");
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
    final value = _controller!.value;
    final position = value.position;
    final duration = value.duration;
    double sliderValue = 0.0;
    if (duration.inMilliseconds > 0) {
      sliderValue = position.inMilliseconds / duration.inMilliseconds;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Slider(
            value: sliderValue.clamp(0.0, 1.0),
            onChanged: (value) {
              if (_controller!.value.isInitialized) {
                final newPosition = duration * value;
                _controller!.seekTo(newPosition);
                _resetControlsTimer();
              }
            },
            activeColor: const Color.fromARGB(255, 255, 255, 255),
            inactiveColor: Colors.white24,
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

    if (!_isInitialized || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255))),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _resetControlsTimer,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: <Widget>[
            Center(
              child: AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: VideoPlayer(_controller!),
              ),
            ),
            AnimatedOpacity(
              opacity: _isControlsVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: Container(
                color: Colors.black26,
                child: Stack(
                  children: [
                    Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            iconSize: 48,
                            color: Colors.white,
                            icon: const Icon(Icons.replay_10),
                            onPressed: () {
                              if (_controller!.value.isInitialized) {
                                _controller!.seekTo(_controller!.value.position - const Duration(seconds: 10));
                                _resetControlsTimer();
                              }
                            },
                          ),
                          const SizedBox(width: 40),
                          IconButton(
                            iconSize: 72,
                            color: Colors.white,
                            icon: Icon(
                              _controller!.value.isPlaying
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                            ),
                            onPressed: () {
                              if (_controller!.value.isInitialized) {
                                _controller!.value.isPlaying
                                    ? _controller!.pause()
                                    : _controller!.play();
                                _resetControlsTimer();
                              }
                            },
                          ),
                          const SizedBox(width: 40),
                          IconButton(
                            iconSize: 48,
                            color: Colors.white,
                            icon: const Icon(Icons.forward_10),
                            onPressed: () {
                              if (_controller!.value.isInitialized) {
                                _controller!.seekTo(_controller!.value.position + const Duration(seconds: 10));
                                _resetControlsTimer();
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
                                onPressed: () => Navigator.of(context).pop(),
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
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: SafeArea(
                        child: _buildProgressBar(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
            builder: (context) => DownloadedMediaDetailsPage(
              item: item,
              heroTag: heroTag,
            ),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: Hero(
          tag: heroTag,
          child: CachedNetworkImage(
            imageUrl: imageUrl,
            memCacheWidth: 342,
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
    _spinnerController =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..repeat();
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
            memCacheWidth: 135,
            fit: BoxFit.cover,
            placeholder: (context, url) => Container(color: Colors.black26),
            errorWidget: (context, url, error) => Container(
              color: Colors.black26,
              child: const Icon(Icons.broken_image, color: Colors.white54),
            ),
          ),
          Container(decoration: BoxDecoration(color: Colors.black.withOpacity(0.6))),
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
                      ? Text('${(progress * 100).floor()}%', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))
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
  final ScrollController _scrollController = ScrollController();
  final Set<String> _seenIds = {};

  @override
  void initState() {
    super.initState();
    if (widget.apiUrl != null) {
      _fetchPage(1);
      _scrollController.addListener(() {
        if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 600) {
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
    } else if (widget.title == 'Continue Watching' || widget.title == 'Watch History') {
      if (item is Map<String, dynamic>) {
        final mediaId = item['id'];
        final mediaType = item['media_type'];
        await ProgressManager.deleteProgress(mediaId, mediaType, season: item['season'], episode: item['episode']);
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
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: _currentItems.isEmpty
          ? const Center(
              child: Text('No items in this list.', style: TextStyle(color: Colors.white54, fontSize: 16)),
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

class GridMediaItem extends StatelessWidget {
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
  Widget build(BuildContext context) {
    if (itemData is DownloadTask) {
      return InProgressDownloadItemWidget(task: itemData as DownloadTask);
    }

    final String? posterPath;
    final String mediaId;

    if (itemData is CachedDownloadItem) {
      final item = itemData as CachedDownloadItem;
      posterPath = item.posterPath;
      mediaId = item.mediaId;
    } else if (itemData is Map<String, dynamic>) {
      final item = itemData as Map<String, dynamic>;
      posterPath = item['poster_path'];
      mediaId = item['id'].toString();
    } else {
      return const SizedBox.shrink();
    }

    final imageUrl = posterPath != null
        ? 'https://image.tmdb.org/t/p/w342$posterPath'
        : 'https://via.placeholder.com/500x750?text=No+Image';

    final heroTag = 'grid_list_${listType}_${mediaId}_$index';

    return GestureDetector(
      onTap: () {
        if (itemData is CachedDownloadItem) {
          Navigator.push(context, MaterialPageRoute(builder: (context) => DownloadedMediaDetailsPage(item: itemData as CachedDownloadItem, heroTag: heroTag)));
        } else {
          Navigator.push(context, MaterialPageRoute(builder: (context) => MediaDetailsPage(media: itemData as Map<String, dynamic>, heroTag: heroTag)));
        }
      },
      onLongPress: (listType == 'Downloads' || listType == 'Watchlist' || listType == 'Continue Watching')
          ? () async {
              final bool? confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: const Color(0xFF1E1F24),
                  title: const Text('Remove Item', style: TextStyle(color: Colors.white)),
                  content: Text('Are you sure you want to remove this from your ${listType.toLowerCase()}?', style: const TextStyle(color: Colors.white70)),
                  actions: [
                    TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
                    ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white), onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
                  ],
                ),
              );
              if (confirm == true) {
                onDelete();
              }
            }
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8.0),
        child: Hero(
          tag: heroTag,
          child: CachedNetworkImage(
            imageUrl: imageUrl,
            memCacheWidth: 135,
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
    if (widget.listType == 'Downloads' && widget.itemData is CachedDownloadItem) {
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
        final url = 'https://api.themoviedb.org/3/movie/$mediaId?api_key=$tmdbApiKey';
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200 && mounted) {
          setState(() {
            _mediaDetails = json.decode(response.body);
            _mediaDetails?['media_type'] = 'movie';
            _isLoading = false;
          });
          return;
        }
      } catch (e) { /* Ignore and try TV */ }
    }

    // If movie fails or type is TV, try fetching as a TV show
    if (mediaType == 'tv' || mediaType == null) {
      try {
        final url = 'https://api.themoviedb.org/3/tv/$mediaId?api_key=$tmdbApiKey';
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200 && mounted) {
          setState(() {
            _mediaDetails = json.decode(response.body);
            _mediaDetails?['media_type'] = 'tv';
            _isLoading = false;
          });
          return;
        }
      } catch (e) { /* Ignore, will show placeholder */ }
    }

    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemData is DownloadTask) {
      final task = widget.itemData as DownloadTask;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: SizedBox(height: 100, child: InProgressDownloadItemWidget(task: task)),
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
      posterPath = item['poster_path'];
      title = item['title'] ?? item['name'] ?? 'Unknown';
      mediaId = item['id'].toString();
    } else {
      return const SizedBox.shrink();
    }

    final imageUrl = posterPath != null
        ? 'https://image.tmdb.org/t/p/w342$posterPath'
        : 'https://via.placeholder.com/500x750?text=No+Image';

    String runtimeStr = '';
    if (_mediaDetails != null) {
      final runtimeRaw = _mediaDetails!['runtime'] ?? (_mediaDetails!['episode_run_time'] is List && (_mediaDetails!['episode_run_time'] as List).isNotEmpty ? (_mediaDetails!['episode_run_time'] as List)[0] : null);
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
            Navigator.push(context, MaterialPageRoute(builder: (context) => DownloadedMediaDetailsPage(item: widget.itemData, heroTag: 'list_item_$mediaId')));
          } else {
            final Map<String, dynamic> mediaData = widget.itemData;
            Navigator.push(context, MaterialPageRoute(builder: (context) => MediaDetailsPage(media: mediaData, heroTag: 'list_item_$mediaId')));
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
                    memCacheWidth: 150,
                    fit: BoxFit.cover,
                    placeholder: (context, url) => Container(color: Colors.black26),
                    errorWidget: (context, url, error) => Container(color: Colors.black26, child: const Icon(Icons.movie, color: Colors.white24)),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16), maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (_isLoading)
                          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54))
                        else if (runtimeStr.isNotEmpty)
                          Text(runtimeStr, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        
                        if (widget.listType == 'Downloads' && runtimeStr.isNotEmpty)
                          const Text(' • ', style: TextStyle(color: Colors.white70, fontSize: 12)),

                        if (widget.listType == 'Downloads')
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(border: Border.all(color: Colors.white38), borderRadius: BorderRadius.circular(4)),
                            child: const Text('HD', style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  if (_fileSize.isNotEmpty)
                    Text(_fileSize, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  if (widget.listType == 'Downloads' || 
                      widget.listType == 'Watchlist' || 
                      widget.listType == 'Continue Watching' || 
                      widget.listType == 'Watch History')
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.white54),
                    onPressed: () async {
                      final bool? confirm = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: const Color(0xFF1E1F24),
                          title: const Text('Remove Item', style: TextStyle(color: Colors.white)),
                          content: Text('Are you sure you want to remove this from your ${widget.listType.toLowerCase()}?', style: const TextStyle(color: Colors.white70)),
                          actions: [
                            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
                            ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white), onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
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
    _downloadMessageSubscription =
        DownloadManager().messages.listen(_onDownloadMessage);
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
    final cachedItems = cachedStrings.map((s) {
      try {
        return CachedDownloadItem.fromJson(json.decode(s));
      } catch (e) {
        return null;
      }
    }).whereType<CachedDownloadItem>().toList();

    cachedItems.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));

    final allTasks = DownloadManager().allTasks;
    final inProgressTasks = allTasks
        .where((task) =>
            task.status == DownloadStatus.requesting ||
            task.status == DownloadStatus.downloading)
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
      final cachedItems = cachedStrings.map((s) {
        try { return CachedDownloadItem.fromJson(json.decode(s)); } catch (e) { return null; }
      }).whereType<CachedDownloadItem>().toList();

      final docsDir = await getApplicationDocumentsDirectory();
      final cineStreamDir = Directory('${docsDir.path}/LunarDrift/Movies');

      List<File> onDiskFiles = [];
      if (await cineStreamDir.exists()) {
        onDiskFiles = await cineStreamDir.list()
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
      List<File> newFiles = onDiskFiles.where((file) => !cachedPaths.contains(file.path)).toList();

      if (newFiles.isNotEmpty) {
        cacheWasModified = true;
        for (final file in newFiles) {
          final filename = file.path.split('/').last;
          final parts = filename.split('+');
          if (parts.isEmpty) continue;
          final mediaId = parts.first;
          
          final mediaDetails = await _fetchMediaDetailsForSync(mediaId);
          if (mediaDetails != null) {
             cachedItems.add(CachedDownloadItem(mediaId: mediaId, title: mediaDetails['title'] ?? mediaDetails['name'] ?? 'Unknown', posterPath: mediaDetails['poster_path'], mediaType: mediaDetails['media_type'], filePath: file.path, downloadedAt: await file.lastModified()));
          }
        }
      }

      if (cacheWasModified) {
        final updatedCachedStrings = cachedItems.map((item) => json.encode(item.toJson())).toList();
        await prefs.setStringList('downloadedItemsCache', updatedCachedStrings);
        await _loadCachedDownloads();
      }
    } catch (e) {
      debugPrint("Error syncing downloads: $e");
    }
  }

  Future<Map<String, dynamic>?> _fetchMediaDetailsForSync(String mediaId) async {
    try {
      final movieUrl = 'https://api.themoviedb.org/3/movie/$mediaId?api_key=$tmdbApiKey';
      var response = await http.get(Uri.parse(movieUrl));
      if (response.statusCode == 200) {
        final details = json.decode(response.body) as Map<String, dynamic>;
        details['media_type'] = 'movie';
        return details;
      }
    } catch (_) {}

    try {
      final tvUrl = 'https://api.themoviedb.org/3/tv/$mediaId?api_key=$tmdbApiKey';
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

    final downloads =
        _downloads.where((e) => e is DownloadTask || e is CachedDownloadItem).toList();

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
                        final bool? settingsChanged = await Navigator.of(context).push(
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
                                  title: 'Downloads', items: downloads)));
                    }),
                    _buildHorizontalDownloadsList(downloads),
                    const SizedBox(height: 24), // Spacing between sections
                    _buildSectionHeader(context, 'Watchlist', () {
                       // Await result from FullListPage for Watchlist
                       Navigator.push<bool?>( // Specify return type
                          context,
                          MaterialPageRoute(
                              builder: (context) => FullListPage(
                                  title: 'Watchlist', items: _watchlistItems)));
                    }),
                    _buildHorizontalWatchlist(_watchlistItems),
                    const SizedBox(height: 40), // Internal padding for the sheet content
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
      BuildContext context, String title, VoidCallback onViewAll) {
    return GestureDetector(
      onTap: onViewAll,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
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
              child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255))));
    }
    if (items.isEmpty) {
      return const SizedBox(
          height: 100,
          child: Center(
              child: Text('No downloads yet.',
                  style: TextStyle(color: Colors.white54))));
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
              child: Text('Your watchlist is empty.',
                  style: TextStyle(color: Colors.white54))));
    }
    if (items.isEmpty && _isLoadingDownloads) {
       return const SizedBox(height: 180, child: Center(child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255))));
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
  bool _isMuted = true;
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
  double _maxKeyboardHeight = 0.0;

  late AnimationController _profileSpinnerController;

  @override
  void initState() {
    super.initState();
    fetchTrending();
    _fetchContinueWatching();
    _fetchGlobalTrending();
    _fetchWatchHistory();
    
    // Prefetch sports data in the background on app load
    LiveSportsApi().prefetch();
    
    _loadRecentSearches();
    _profileSpinnerController =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..repeat();
    // Listen for global download messages
    DownloadManager().messages.listen((message) {
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

  Future<void> _fetchRecommendations(List<Map<String, dynamic>> continueWatching) async {
    if (continueWatching.isEmpty) return;

    Map<String, dynamic>? latestMovie;
    Map<String, dynamic>? latestTv;

    for (var item in continueWatching) {
      if (item['media_type'] == 'movie' && latestMovie == null) latestMovie = item;
      if (item['media_type'] == 'tv' && latestTv == null) latestTv = item;
      if (latestMovie != null && latestTv != null) break;
    }

    if (latestMovie != null) {
      final title = latestMovie['title'] ?? latestMovie['name'];
      final recs = await _getRecommendations('movie', latestMovie['id']);
      if (mounted) setState(() { _latestMovieTitle = title; _latestMovieRecs = recs; });
    }

    if (latestTv != null) {
      final title = latestTv['title'] ?? latestTv['name'];
      final recs = await _getRecommendations('tv', latestTv['id']);
      if (mounted) setState(() { _latestTvTitle = title; _latestTvRecs = recs; });
    }
  }

  Future<List<dynamic>> _getRecommendations(String type, dynamic id) async {
    try {
      final url = 'https://api.themoviedb.org/3/$type/$id/recommendations?api_key=$tmdbApiKey';
      final data = await fetchWithCache(url);
      final List recs = data['results'] as List? ?? [];
      
      var filtered = recs.where((item) => _isReleased(item, strictFilter: true)).toList();
      if (filtered.isEmpty) {
        filtered = recs.where((item) => _isReleased(item)).toList();
      }

      return filtered.map((item) {
        item['media_type'] = item['media_type'] ?? (type == 'movie' ? 'movie' : 'tv');
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

  Future<void> fetchTrending() async {
    try {
      final url =
          'https://api.themoviedb.org/3/trending/all/day?api_key=$tmdbApiKey';
      final data = await fetchWithCache(url);
      if (mounted) {
        setState(() {
          final rawList = data['results'] as List? ?? [];
          final filtered = rawList
              .where((item) => _isReleased(item, strictFilter: true))
              .toList();
          final basicFiltered = rawList.where((item) => _isReleased(item)).toList();

          // Fallback if strict filter is too aggressive for the trending feed
          mediaList = filtered.isNotEmpty ? filtered : (basicFiltered.isNotEmpty ? basicFiltered : rawList);

          for (var item in mediaList) {
            if (item is Map && item['media_type'] == null) {
              item['media_type'] = item.containsKey('title') ? 'movie' : 'tv';
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
    setState(() {
      _recentSearches.removeWhere((item) => item['id'] == media['id']);
      _recentSearches.insert(0, media);
      if (_recentSearches.length > 20) {
        _recentSearches.removeLast();
      }
    });
    _saveRecentSearches();
  }

  // --- UI Builder Methods for Animated Bottom Bar ---

  Widget _buildNavBarContainer({required Widget child, bool isCircle = false}) {
    final borderRadius = isCircle ? 28.0 : 40.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 40.0, sigmaY: 40.0),
        child: Container(
          height: 56,
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
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withOpacity(0.15),
              width: 1.0,
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildSearchIcon() {
    return IconButton(
      key: const ValueKey('search_icon'),
      iconSize: 56,
      padding: EdgeInsets.zero,
      icon: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: const Icon(Icons.search, color: Colors.white, size: 28),
          ),
        ),
      ),
      onPressed: () {
        setState(() {
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

  Widget _buildCloseKeyboardIcon() {
    return IconButton(
      key: const ValueKey('close_keyboard_icon'),
      iconSize: 56,
      padding: EdgeInsets.zero,
      icon: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.2)),
            ),
            child: const Icon(Icons.close, color: Colors.white, size: 28),
          ),
        ),
      ),
      onPressed: () => FocusScope.of(context).unfocus(),
    );
  }

  Widget _buildLiveTvModeSwitcher() {
    final itemValues = ['live', 'schedule'];
    final selectedIndex = itemValues.indexOf(_liveTvMode);
    const double itemWidth = 75.0;
    const double switcherWidth = (itemWidth * 2) + 2.0; // Account for 1px borders on each side
    const double switcherHeight = 50.0; // Account for 1px borders on top and bottom

    return ClipRRect(
      borderRadius: BorderRadius.circular(40.0),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 40.0, sigmaY: 40.0),
        child: Container(
          width: switcherWidth,
          height: switcherHeight,
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
              color: Colors.white.withOpacity(0.15),
              width: 1.0,
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Sliding glass indicator
              AnimatedPositioned(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOutCubic,
                left: (selectedIndex * itemWidth),
                top: 0,
                width: itemWidth,
                height: switcherHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(switcherHeight / 2),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius:
                            BorderRadius.circular(switcherHeight / 2),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Icons
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildLiveTvSwitcherItem(Icons.live_tv, 'live', selectedIndex == 0),
                  _buildLiveTvSwitcherItem(
                      Icons.calendar_today, 'schedule', selectedIndex == 1),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveTvSwitcherItem(IconData icon, String value, bool isSelected) {
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
    final keyboardAnimationProgress =
        (_maxKeyboardHeight > 0 ? (keyboardHeight / _maxKeyboardHeight) : 0.0)
            .clamp(0.0, 1.0);
    ImageProvider? profileImage;
    if (user?.photoURL != null) {
      if (user!.photoURL!.startsWith('data:image')) {
        final base64String = user.photoURL!.split(',').last;
        profileImage = MemoryImage(base64Decode(base64String));
      } else {
        profileImage = CachedNetworkImageProvider(user.photoURL!);
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
            : ClipRRect(
                borderRadius: BorderRadius.circular(28.0),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12.0, sigmaY: 12.0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16.0, vertical: 8.0),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(28.0),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.2),
                      ),
                    ),
                    child: Text(
                      appBarTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
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
                        child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255)),
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
                              items: mediaList.length > 5 ? mediaList.skip(5).toList() : mediaList,
                              apiUrl: 'https://api.themoviedb.org/3/trending/all/day?api_key=$tmdbApiKey',
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
                                onRefresh: _fetchContinueWatching,
                              ),
                            const SizedBox(height: 16),
                            if (_latestTvRecs.isNotEmpty)
                              HorizontalMediaList(
                                categoryTitle: 'More Like $_latestTvTitle',
                                items: _latestTvRecs,
                                apiUrl: 'https://api.themoviedb.org/3/tv/${_continueWatching.firstWhere((i) => i['media_type'] == 'tv')['id']}/recommendations?api_key=$tmdbApiKey',
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
                                apiUrl: 'https://api.themoviedb.org/3/movie/${_continueWatching.firstWhere((i) => i['media_type'] == 'movie')['id']}/recommendations?api_key=$tmdbApiKey',
                                onChildRefresh: () {
                                  _fetchWatchHistory();
                                  _fetchContinueWatching();
                                },
                                defaultMediaType: 'movie',
                              ),
                            const SizedBox(height: 120),
                          ]
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
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: defaultTargetPlatform == TargetPlatform.iOS
            ? LayoutBuilder(builder: (context, constraints) {
                final safeAreaHorizontalPadding =
                    MediaQuery.of(context).padding.left +
                        MediaQuery.of(context).padding.right;
                final containerMargin = 16.0 * 2;
                final availableWidth =
                    constraints.maxWidth - safeAreaHorizontalPadding - containerMargin;

                final searchIconWidth = 56.0;
                final spacing = 12.0;
                final homeIconWidth = 56.0;
                final closeButtonWidth = 56.0;

                final expandedNavBarWidth = availableWidth - searchIconWidth - spacing;
                final collapsedNavBarWidth = homeIconWidth;

                final searchBarLeft = collapsedNavBarWidth + spacing;

                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16.0)
                      .copyWith(bottom: 16.0),
                  height: 56,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      // Main Nav Bar
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOutCubic,
                        left: 0,
                        width: _isSearchActive
                            ? collapsedNavBarWidth
                            : expandedNavBarWidth,
                        height: 56,
                        child: Transform.scale(
                          scale: 1.0 - keyboardAnimationProgress,
                          alignment: Alignment.centerLeft,
                          child: _buildNavBarContainer(
                            isCircle: _isSearchActive,
                            child: SlidingGlassBottomNavBar(
                              showIndicator: !_isSearchActive,
                              selectedIndex: _isSearchActive ? 0 : _selectedIndex,
                              onTap: (index) {
                                if (index == 0 && _isSearchActive) {
                                  setState(() {
                                    _isSearchActive = false;
                                    _selectedIndex = 0;
                                    _searchController.clear();
                                    _onSearchChanged('');
                                  });
                                } else {
                                  setState(() {
                                    _isSearchActive = false;
                                    _selectedIndex = index;
                                  });
                                }
                              },
                              isSearchActive: _isSearchActive,
                              expandedWidth: expandedNavBarWidth - 2.0,
                              collapsedWidth: collapsedNavBarWidth - 2.0,
                              itemValues: const [0, 1, 2, 4],
                              items: const [
                                BottomNavigationBarItem(
                                    icon: Icon(Icons.home), label: 'Home'),
                                BottomNavigationBarItem(
                                    icon: Icon(Icons.movie), label: 'Movies'),
                                BottomNavigationBarItem(
                                    icon: Icon(Icons.tv), label: 'TV Shows'),
                                BottomNavigationBarItem(icon: Icon(Icons.sports_basketball),
                                    label: 'Sports'),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Search component
                      TweenAnimationBuilder<double>(
                        tween: Tween<double>(
                            begin: 0.0, end: _isSearchActive ? 1.0 : 0.0),
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOutCubic,
                        builder: (context, searchAnimationValue, child) {
                          // Animate the search bar sliding in/out when search is activated/deactivated
                          final searchBarLeftOnSearch = lerpDouble(
                              expandedNavBarWidth + spacing,
                              searchBarLeft,
                              searchAnimationValue);

                          // Further animate the position based on the keyboard's visibility
                          final searchBarLeftCurrent = lerpDouble(
                              searchBarLeftOnSearch,
                              0,
                              keyboardAnimationProgress);
                          final searchBarRightCurrent = lerpDouble(0.0,
                              closeButtonWidth + spacing, keyboardAnimationProgress);

                          return Positioned(
                            left: searchBarLeftCurrent,
                            right: searchBarRightCurrent,
                            height: 56,
                            child: child!,
                          );
                        },
                        child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: _isSearchActive
                                ? _buildSearchBar()
                                : _buildSearchIcon()),
                      ),
                      // Close Keyboard Button
                      Positioned(
                        right: 0,
                        width: closeButtonWidth,
                        height: 56,
                        child: Transform.scale(
                          scale: keyboardAnimationProgress,
                          alignment: Alignment.centerRight,
                          child: _buildCloseKeyboardIcon(),
                        ),
                      ),
                    ],
                  ),
                );
              })
            : Container(
                color: const Color(0xFF0F1014),
                child: SafeArea(
                  top: false,
                  child: SizedBox(
                    height: 60,
                    child: LayoutBuilder(builder: (context, constraints) {
                      return SlidingGlassBottomNavBar(
                        selectedIndex: _selectedIndex,
                        onTap: (index) => setState(() => _selectedIndex = index),
                        expandedWidth: constraints.maxWidth,
                        collapsedWidth: constraints.maxWidth,
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
                      );
                    }),
                  ),
                ),
              ),
      ),
    );
  }

  // Helper to refresh all relevant data on the home page
  void _refreshAllHomePageData() {
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

    final expandedItemWidth =
        items.isNotEmpty ? expandedWidth / items.length : 0.0;
    final indicatorTargetWidth =
        isSearchActive ? collapsedWidth : expandedItemWidth;
    final indicatorTargetLeft =
        activeItemIndex != -1 ? activeItemIndex * expandedItemWidth : 0.0;

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
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(indicatorHeight / 2),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.2),
                  ),
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

            final homeItemTargetWidth =
                isSearchActive ? collapsedWidth : expandedItemWidth;
            final otherItemTargetWidth =
                isSearchActive ? 0.0 : expandedItemWidth;
            final targetWidth =
                isHomeButton ? homeItemTargetWidth : otherItemTargetWidth;

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
                opacity: (isHomeButton || !isSearchActive) ? 1.0 : 0.0,
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
      leading: Icon(icon, color: isDestructive ? Colors.redAccent : Colors.white70, size: 28),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Use a StatefulBuilder to manage a local state for changes
    return StatefulBuilder(builder: (context, setState) {

    final user = FirebaseAuth.instance.currentUser;

    ImageProvider? profileImage;
    if (user?.photoURL != null) {
      if (user!.photoURL!.startsWith('data:image')) {
        final base64String = user.photoURL!.split(',').last;
        profileImage = MemoryImage(base64Decode(base64String));
      } else {
        profileImage = CachedNetworkImageProvider(user.photoURL!);
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
                    child: Icon(Icons.person, size: 30, color: Colors.white),
                  ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (user?.displayName != null && user!.displayName!.isNotEmpty)
                            ? user.displayName!
                            : 'Account',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (user?.email != null && user!.email!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          user.email!,
                          style: const TextStyle(color: Colors.white54, fontSize: 14),
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
                  AppNotification.show(context, 'Search history cleared.', color: Colors.green);
                }
              }
            },
          ),
          const Divider(color: Colors.white24, indent: 24, endIndent: 24, height: 1),
          _buildSettingsItem(
            context,
            icon: Icons.history,
            title: 'Clear Watch History',
            subtitle: 'Removes your entire continue watching and watch history.',
            onTap: () async {
              final bool? confirm = await showDialog<bool>(
                context: context,
                builder: (context) {
                  return AlertDialog(
                    backgroundColor: const Color(0xFF1E1F24),
                    title: const Text('Clear Watch History', style: TextStyle(color: Colors.white)),
                    content: const Text('Are you sure you want to clear your entire watch history? This cannot be undone.', style: TextStyle(color: Colors.white70)),
                    actions: [
                      TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
                      ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white), onPressed: () => Navigator.of(context).pop(true), child: const Text('Clear')),
                    ],
                  );
                },
              );

              if (confirm == true) {
                await ProgressManager.clearWatchHistory();
                if (context.mounted) {
                  AppNotification.show(context, 'Watch history cleared.', color: Colors.green);
                }
              }
            },
          ),
          const Divider(color: Colors.white24, indent: 24, endIndent: 24, height: 1),
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
          const Divider(color: Colors.white24, indent: 24, endIndent: 24, height: 1),
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
                  title: const Text('Delete Account', style: TextStyle(color: Colors.white)),
                  content: const Text('This will permanently delete your account and all your data. This action cannot be undone.', style: TextStyle(color: Colors.white70)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
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
                  
                  final watchlist = await db.collection('users').doc(user.uid).collection('watchlist').get();
                  // ignore: curly_braces_in_flow_control_structures
                  for (var doc in watchlist.docs) batch.delete(doc.reference);
                  
                  final progress = await db.collection('users').doc(user.uid).collection('progress').get();
                  // ignore: curly_braces_in_flow_control_structures
                  for (var doc in progress.docs) batch.delete(doc.reference);
                  
                  batch.delete(db.collection('users').doc(user.uid));
                  await batch.commit();

                  // Delete Firebase Auth user
                  await user.delete();
                  
                  if (context.mounted) {
                    Navigator.of(context).popUntil((route) => route.isFirst);
                    AppNotification.show(context, 'Account deleted successfully.', color: Colors.green);
                  }
                } on FirebaseAuthException catch (e) {
                  if (e.code == 'requires-recent-login') {
                    if (context.mounted) {
                      AppNotification.show(context, 'Please sign out and sign back in to delete your account.', color: Colors.red);
                    }
                  } else {
                    if (context.mounted) {
                      AppNotification.show(context, 'Error deleting account: ${e.message}', color: Colors.red);
                    }
                  }
                } catch (e) {
                  if (context.mounted) {
                    AppNotification.show(context, 'Error: $e', color: Colors.red);
                  }
                }
              }
            },
          ),
          const Divider(color: Colors.white24, height: 1),
        ],
      ),
    );
    }); // End of StatefulBuilder
  }
}

class FeaturedMediaItem extends StatefulWidget {
  final List<dynamic> mediaList;
  final bool isMuted;

  const FeaturedMediaItem({
    super.key,
    required this.mediaList,
    this.isMuted = true,
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
          defaultTargetPlatform == TargetPlatform.iOS);

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
        provider: CachedNetworkImageProvider(imageUrl),
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
          _extractDominantColor('https://image.tmdb.org/t/p/w500$extractedLogo');
        } else if (media['poster_path'] != null) {
          _extractDominantColor(
            'https://image.tmdb.org/t/p/w300${media['poster_path']}',
          );
        } else {
          if (mounted) {
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
                tempTvProgress.putIfAbsent(s, () => {})[e] = (prog['progress'] as num?)?.toDouble() ?? 0.0;
              }
            }

            int latestSeason = 1;
            int latestEpisode = 1;
            double latestProgress = 0.0;

            if (tempTvProgress.isNotEmpty) {
              // Find the highest season with any progress
              latestSeason = tempTvProgress.keys.reduce((a, b) => a > b ? a : b);
              Map<int, double>? episodesInLatestSeason = tempTvProgress[latestSeason];

              if (episodesInLatestSeason != null && episodesInLatestSeason.isNotEmpty) {
                // Find the highest episode watched in that season
                latestEpisode = episodesInLatestSeason.keys.reduce((a, b) => a > b ? a : b);
                latestProgress = episodesInLatestSeason[latestEpisode] ?? 0.0;
              }
            }

            // If the latest episode is completed (>= 90%), suggest the next one
            if (latestProgress >= 0.9) {
              _selectedSeason = latestSeason;
              _selectedEpisode = latestEpisode + 1; // Suggest next episode
            } else { // Otherwise, resume the last watched one
              _selectedSeason = latestSeason;
              _selectedEpisode = latestEpisode;
            }
            _featuredTvProgress = tempTvProgress;
          }
        } else { // movie
          final savedProgress = await ProgressManager.getProgress(mediaId);
          if (mounted) {
            _featuredMovieProgress = (savedProgress?['progress'] as num?)?.toDouble() ?? 0.0;
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

        if (_trailerKey != null) {
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

    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final media = widget.mediaList[_currentIndex];
    final imageUrl = media['backdrop_path'] != null
        ? 'https://image.tmdb.org/t/p/w1280${media['backdrop_path']}'
        : (media['poster_path'] != null
              ? 'https://image.tmdb.org/t/p/original${media['poster_path']}'
              : 'https://via.placeholder.com/1280x720?text=No+Image');
    final title = media['title'] ?? media['name'] ?? 'Unknown';
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

    final isTvShow = media['media_type'] == 'tv';
    double currentProgress = 0.0;
    int selectedSeason = 1;
    int selectedEpisode = 1;

    if (isTvShow) {
      selectedSeason = _selectedSeason;
      selectedEpisode = _selectedEpisode;
      if (_featuredTvProgress.containsKey(selectedSeason) && _featuredTvProgress[selectedSeason]!.containsKey(selectedEpisode)) {
        currentProgress = _featuredTvProgress[selectedSeason]![selectedEpisode]!;
      } else {
        currentProgress = 0.0; // If no progress for this specific episode, assume 0
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

    return RepaintBoundary(
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
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
        ).then((_) {
          if (mounted) {
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
          Column(
            children: [
              SizedBox(
                height: 440,
                width: double.infinity,
                child: Stack(
                  clipBehavior: Clip.antiAlias,
                  children: [
                    if (_trailerKey != null)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: FittedBox(
                            fit: BoxFit.cover,
                            child: ClipRect(
                              child: Transform.scale(
                                scale: kIsWeb ? 1.0 : 1.35,
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
                      ),
                    Positioned.fill(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 500),
                        child: _isVideoPlaying
                            ? Container(
                                key: const ValueKey('empty_video_bg'),
                                // Use a tiny amount of opacity so the browser doesn't
                                // pass scroll events through to the iframe.
                                color: Colors.black.withOpacity(0.01),
                              )
                            : Hero(
                                key: ValueKey(heroTag),
                                tag: heroTag,
                                child: CachedNetworkImage(
                                  imageUrl: imageUrl,
                                  memCacheWidth: 280,
                                  height: 440,
                                  width: double.infinity,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => Container(
                                    height: 440,
                                    color: Colors.black26,
                                  ),
                                  errorWidget: (context, url, error) =>
                                      Container(
                                        height: 440,
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
                      height: 220,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF0F1014), Colors.transparent],
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                height: 220,
                width: double.infinity,
                color: const Color(0xFF0F1014),
              ),
            ],
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
                  crossAxisAlignment: isMobile
                      ? CrossAxisAlignment.center
                      : CrossAxisAlignment.start,
                  children: [
                    if (_logoPath != null)
                      CachedNetworkImage(
                        imageUrl: 'https://image.tmdb.org/t/p/w500$_logoPath',
                        width: 250,
                        height: 100,
                        fit: BoxFit.contain,
                        alignment: isMobile
                            ? Alignment.center
                            : Alignment.centerLeft,
                      )
                    else
                      Text(
                        title,
                        textAlign: isMobile
                            ? TextAlign.center
                            : TextAlign.start,
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
                      alignment: isMobile
                          ? WrapAlignment.center
                          : WrapAlignment.start,
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
                      Text(
                        overview,
                        maxLines: 3,
                        textAlign: isMobile
                            ? TextAlign.center
                            : TextAlign.start,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: isMobile ? 12 : 14,
                          height: 1.4,
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
                      mainAxisAlignment: isMobile
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: defaultTargetPlatform == TargetPlatform.iOS
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: BackdropFilter(
                                    filter: ImageFilter.blur(
                                      sigmaX: 20,
                                      sigmaY: 20,
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: btnBaseColor != null
                                            ? btnBaseColor.withOpacity(0.15)
                                            : Colors.white.withOpacity(0.15),
                                        border: Border.all(
                                          color: btnBaseColor != null
                                              ? btnBaseColor.withOpacity(0.3)
                                              : Colors.white.withOpacity(0.3),
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.transparent,
                                          shadowColor: Colors.transparent,
                                          foregroundColor:
                                              btnBaseColor ?? Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 12,
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
                                              final mediaType = isTvShow
                                                  ? 'tv'
                                                  : 'movie';
                                              final url =
                                                  'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey';
                                              final data = await fetchWithCache(
                                                url,
                                              );

                                              if (isTvShow) {
                                                final epUrl =
                                                    'https://api.themoviedb.org/3/tv/$mediaId/season/$selectedSeason/episode/$selectedEpisode?api_key=$tmdbApiKey';
                                                try {
                                                  final epData =
                                                      await fetchWithCache(
                                                        epUrl,
                                                      );
                                                  if (epData['runtime'] !=
                                                      null) {
                                                    rTime = epData['runtime'];
                                                  } else if (data['episode_run_time']
                                                          is List &&
                                                      data['episode_run_time']
                                                          .isNotEmpty) {
                                                    rTime =
                                                        data['episode_run_time'][0];
                                                  }
                                                } catch (_) {
                                                  if (data['episode_run_time']
                                                          is List &&
                                                      data['episode_run_time']
                                                          .isNotEmpty) {
                                                    rTime =
                                                        data['episode_run_time'][0];
                                                  }
                                                }
                                              } else {
                                                if (data['runtime'] != null) {
                                                  rTime = data['runtime'];
                                                }
                                              }
                                            } catch (_) {}
                                            resumeSeconds =
                                                (rTime * 60 * currentProgress)
                                                    .toInt();
                                          }
                                          final String progressParam =
                                              '&progress=$resumeSeconds';
                                          final String placeholderLink =
                                              isTvShow
                                              ? 'https://player.videasy.net/tv/${media['id']}/$selectedSeason/$selectedEpisode?color=1ce783&autoPlay=true&overlay=true$progressParam'
                                              : 'https://player.videasy.net/movie/${media['id']}?color=1ce783&autoPlay=true&overlay=true$progressParam';

                                          ProgressManager.saveProgress(
                                            media: media,
                                            progress: currentProgress == 0 ? 0.05 : currentProgress,
                                            season: isTvShow ? selectedSeason : null,
                                            episode: isTvShow ? selectedEpisode : null,
                                            position: resumeSeconds,
                                          );

                                          if (!context.mounted) return;
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  VideoPlayerPage(
                                                    videoUrl: placeholderLink,
                                                    media: media,
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
                                            }
                                          });
                                        },
                                        icon: const Icon(
                                          Icons.play_arrow,
                                          size: 24,
                                        ),
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
                                  ),
                                )
                                : ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        btnBaseColor ?? Colors.white,
                                    foregroundColor:
                                        (!isTvShow && _isCamRelease) || btnBaseColor == null
                                        ? Colors.white
                                        : (btnBaseColor.computeLuminance() <
                                                  0.5
                                              ? Colors.white
                                              : Colors.black),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4.0)),
                                  ),
                                  onPressed: () async {
                                    _stopTrailerVideo();
                                    int resumeSeconds = 0;
                                    if (currentProgress > 0 &&
                                        currentProgress < 1.0) {
                                      int rTime = isTvShow ? 45 : 120;
                                      try {
                                        final mediaId = media['id'];
                                        final mediaType = isTvShow
                                            ? 'tv'
                                            : 'movie';
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
                                                data['episode_run_time']
                                                    .isNotEmpty) {
                                              rTime =
                                                  data['episode_run_time'][0];
                                            }
                                          } catch (_) {
                                            if (data['episode_run_time']
                                                    is List &&
                                                data['episode_run_time']
                                                    .isNotEmpty) {
                                              rTime =
                                                  data['episode_run_time'][0];
                                            }
                                          }
                                        } else {
                                          if (data['runtime'] != null) {
                                            rTime = data['runtime'];
                                          }
                                        }
                                      } catch (_) {}
                                      resumeSeconds =
                                          (rTime * 60 * currentProgress)
                                              .toInt();
                                    }
                                    final String progressParam =
                                        '&progress=$resumeSeconds';
                                    final String placeholderLink = isTvShow
                                        ? 'https://player.videasy.net/tv/${media['id']}/$selectedSeason/$selectedEpisode?color=1ce783&autoPlay=true&nextEpisode=true&overlay=true$progressParam'
                                        : 'https://player.videasy.net/movie/${media['id']}?color=1ce783&autoPlay=true&overlay=true$progressParam';

                                    ProgressManager.saveProgress(
                                      media: media,
                                      progress: currentProgress == 0 ? 0.05 : currentProgress,
                                      season: isTvShow ? selectedSeason : null,
                                      episode: isTvShow ? selectedEpisode : null,
                                      position: resumeSeconds,
                                    );

                                    if (!context.mounted) return;
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => VideoPlayerPage(
                                          videoUrl: placeholderLink,
                                          media: media,
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
                                      }
                                    });
                                  },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.play_arrow, size: 24),
                                      const SizedBox(width: 8),
                                      Text(playButtonText,
                                          style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold)),
                                    ],
                                  ), 
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: defaultTargetPlatform == TargetPlatform.iOS
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: BackdropFilter(
                                    filter: ImageFilter.blur(
                                      sigmaX: 20,
                                      sigmaY: 20,
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.05),
                                        border: Border.all(
                                          color: Colors.white.withOpacity(0.15),
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                          side: BorderSide.none,
                                        ),
                                        onPressed: () {
                                          _stopTrailerVideo();
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) =>
                                                  MediaDetailsPage(
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
                                  ),
                                )
                              : OutlinedButton.icon(
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    side: const BorderSide(
                                      color: Colors.white54,
                                      width: 2,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(4.0),
                                    ),
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
                        if (!isMobile) const Spacer(flex: 4),
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
                                          color: const Color.fromARGB(255, 255, 255, 255),
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
      )
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
  bool _detailsFetched = false;
  Map<int, Map<int, double>> _tvProgress = {};
  double _movieProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _calculateInitialYear();
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
        (media.containsKey('first_air_date') ? 'tv' : 'movie');
    final mediaId = media['id'];

    if (mediaId != null) {
      try {
        final url =
            'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey&append_to_response=content_ratings,release_dates';
        final data = await fetchWithCache(url);
        if (mounted) {
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
                if (endYear.isNotEmpty && endYear != startYear) {
                  setState(() {
                    _displayYear = '$startYear - $endYear$seasonStr';
                  });
                } else {
                  setState(() {
                    _displayYear = '$startYear$seasonStr';
                  });
                }
              } else {
                setState(() {
                  _displayYear = '$startYear - $endYear$seasonStr';
                });
              }
            } else if (seasonStr.isNotEmpty) {
              setState(() {
                _displayYear = seasonStr.substring(3);
              });
            }
          } else {
            final runtime = data['runtime'];
            if (runtime != null && runtime > 0) {
              final int hrs = runtime ~/ 60;
              final int mins = runtime % 60;
              final runtimeStr = hrs > 0
                  ? ' • ${hrs}h ${mins}m'
                  : ' • ${mins}m';
              setState(() {
                _displayYear = '$_displayYear$runtimeStr';
              });
            }
          }

          if (cert.isNotEmpty) {
            setState(() {
              _contentRating = cert;
            });
          }

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
                    _tvProgress.putIfAbsent(s, () => {})[e] = (prog['progress'] as num?)?.toDouble() ?? 0.0;
                  }
                }
              });
            }
          } else {
            final savedProgress = await ProgressManager.getProgress(mediaId);
            if (mounted) {
              setState(() {
                _movieProgress = (savedProgress?['progress'] as num?)?.toDouble() ?? 0.0;
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
    final title = media['title'] ?? media['name'] ?? 'Unknown';
    final voteAverageRaw = media['vote_average'];
    final voteAverage = voteAverageRaw != null
        ? double.tryParse(voteAverageRaw.toString())?.toStringAsFixed(1) ??
              '0.0'
        : '0.0';
    final overview = media['overview']?.toString() ?? 'No overview available.';
    final isMobile = MediaQuery.sizeOf(context).width < 600;

    final mediaType =
        media['media_type'] ??
        (media.containsKey('first_air_date') ? 'tv' : 'movie');
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
          Navigator.push<bool?>( // Specify return type
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
                  child: CachedNetworkImage(
                    imageUrl: widget.imageUrl,
                    memCacheWidth: 135,
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
                                              Color.fromARGB(255, 255, 255, 255),
                                            ),
                                        minHeight: 4,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
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

class ContinueWatchingMediaItem extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final title = media['title'] ?? media['name'] ?? 'Unknown';
    final backdropPath = media['backdrop_path'];
    final imageUrl = backdropPath != null
        ? 'https://image.tmdb.org/t/p/w300$backdropPath'
        : (media['poster_path'] != null 
            ? 'https://image.tmdb.org/t/p/w342${media['poster_path']}'
            : 'https://via.placeholder.com/500x281?text=No+Image');

    final bool isTv = media['media_type'] == 'tv' || media.containsKey('first_air_date');
    final mediaType = media['media_type']?.toString() ?? (isTv ? 'tv' : 'movie');
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
      onTap: () async { // Make async
        final bool? shouldRefresh = await Navigator.push<bool?>( // Specify return type
          context,
          MaterialPageRoute(
            builder: (context) => MediaDetailsPage(media: media, heroTag: heroTag),
          ),
        );
        if (shouldRefresh == true && onRefreshParent != null) {
          onRefreshParent!(); // Trigger refresh on parent
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
                      tag: heroTag,
                      child: CachedNetworkImage(
                        imageUrl: imageUrl,
            memCacheWidth: 135,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(color: Colors.black26),
                        errorWidget: (context, url, error) => Container(
                          color: Colors.black26,
                          child: const Icon(Icons.broken_image, color: Colors.white24),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () {
                      // Calculate mock resume position
                      final int rTime = (media['runtime'] as num?)?.toInt() ?? (isTv ? 45 : 120);
                      final int resumeSeconds = (media['position'] as num?)?.toInt() ?? (rTime * 60 * progress).toInt();
                      final String progressParam = '&progress=$resumeSeconds';
                      
                      final String videoUrl = isTv
                          ? 'https://player.videasy.net/tv/${media['id']}/${season ?? 1}/${episode ?? 1}?color=1ce783&autoPlay=true&nextEpisode=true&overlay=true$progressParam'
                          : 'https://player.videasy.net/movie/${media['id']}?color=1ce783&autoPlay=true&overlay=true$progressParam';

                      Navigator.push<bool?>( // Specify return type
                        context,
                        MaterialPageRoute(
                          builder: (context) => VideoPlayerPage(
                            videoUrl: videoUrl,
                            media: media is Map<String, dynamic> ? media : null,
                            season: season,
                            episode: episode,
                          ),
                        ),
                      ).then((bool? videoPlayerChanged) {
                        if (videoPlayerChanged == true && onRefreshParent != null) {
                          onRefreshParent!(); // Trigger refresh on parent
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
                        child: const Icon(Icons.play_arrow, color: Colors.white, size: 28),
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
                      borderRadius: BorderRadius.only(bottomLeft: Radius.circular(8), bottomRight: Radius.circular(8)),
                    ),
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: progress,
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Color.fromARGB(255, 255, 255, 255),
                          borderRadius: BorderRadius.only(bottomLeft: Radius.circular(8)),
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
                      Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.more_vert, color: Colors.white54, size: 20),
                  onSelected: (value) async {
                    if (value == 'remove') {
                      await ProgressManager.deleteProgress(
                        media['id'],
                        mediaType,
                        season: season,
                        episode: episode,
                      );
                      if (onRemove != null) onRemove!();
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
            onTap: widget.categoryTitle == 'Continue Watching' ? null : () {
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
              );
            },
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(widget.categoryTitle,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
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
                        right: widget.categoryTitle == 'Continue Watching' ? 12.0 : 212.0,
                      ),
                  itemCount: widget.items.length,
                  itemBuilder: (context, index) {
                    final media = widget.items[index];
                    final heroTag =
                        '${widget.categoryTitle}_${media['media_type']}_${media['id']}_$index';
                    final mediaType = media['media_type'] ?? (media.containsKey('first_air_date') ? 'tv' : 'movie');
                    final posterPath = media['poster_path'];
                    final imageUrl = posterPath != null
                        ? 'https://image.tmdb.org/t/p/w342$posterPath'
                        : 'https://via.placeholder.com/500x750?text=No+Image';

                    if (widget.categoryTitle == 'Continue Watching') {
                      return ContinueWatchingMediaItem(
                        media: media,
                        heroTag: heroTag,
                        onRemove: widget.onRefresh,
                      );
                    } else if (mediaType == 'movie' || mediaType == 'tv') {
                      // Pass onChildRefresh to HoverableMediaItem
                      return HoverableMediaItem(
                        media: media,
                        heroTag: heroTag,
                        imageUrl: imageUrl,
                        onRefreshParent: widget.onChildRefresh, // Pass the callback
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
    fetchData();
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

  Future<void> fetchData() async {
    try {
      final trendingUrl =
          'https://api.themoviedb.org/3/trending/${widget.mediaType}/day?api_key=$tmdbApiKey';
      final genreUrl =
          'https://api.themoviedb.org/3/genre/${widget.mediaType}/list?api_key=$tmdbApiKey';
      final topRatedUrl =
          'https://api.themoviedb.org/3/${widget.mediaType}/top_rated?api_key=$tmdbApiKey';
      final onTheAirUrl =
          'https://api.themoviedb.org/3/tv/on_the_air?api_key=$tmdbApiKey';

      // PERFORMANCE: Fetch multiple API resources in parallel to reduce startup latency.
      final results = await Future.wait([
        fetchWithCache(trendingUrl),
        fetchWithCache(genreUrl),
        fetchWithCache(topRatedUrl),
        widget.mediaType == 'tv' ? fetchWithCache(onTheAirUrl) : Future.value(null),
      ]);

      final trendingData = results[0];
      final genreData = results[1];
      final topRatedData = results[2];
      final onTheAirData = results[3];

      if (mounted) {
        setState(() {
          final rawTrending = trendingData['results'] as List? ?? [];
          final filtered = rawTrending
              .where((item) => _isReleased(item, strictFilter: true))
              .toList();
          final basicFiltered = rawTrending.where((item) => _isReleased(item)).toList();

          // Fallback if strict filter is too aggressive for this category
          trendingList = filtered.isNotEmpty ? filtered : (basicFiltered.isNotEmpty ? basicFiltered : rawTrending);

          final rawTopRated = topRatedData['results'] as List? ?? [];
          topRatedList = rawTopRated
              .where((item) => _isReleased(item, strictFilter: true))
              .map((item) {
            item['media_type'] = widget.mediaType;
            return item;
          }).toList();

          if (onTheAirData != null) {
            final rawOnTheAir = onTheAirData['results'] as List? ?? [];
            onTheAirList = rawOnTheAir
                .where((item) => _isReleased(item, strictFilter: true))
                .map((item) {
              item['media_type'] = 'tv';
              return item;
            }).toList();
          }

          // Mark trending items as seen so they don't repeat in genre lists
          for (var item in trendingList) {
            item['media_type'] = widget.mediaType;
            if (item['id'] != null) seenMediaIds.add(item['id']);
          }
          for (var item in topRatedList) {
            item['media_type'] = widget.mediaType;
            if (item['id'] != null) seenMediaIds.add(item['id']);
          }
          allGenres = genreData['genres'] ?? [];
          
          ProgressManager.getContinueWatching().then((cw) {
            if (mounted) {
              final filtered = cw.where((i) => i['media_type'] == widget.mediaType).toList();
              setState(() => continueWatching = filtered);
              if (filtered.isNotEmpty) {
                _fetchCategoryRecommendations(filtered.first);
              } else {
                setState(() => recommendations = []);
              }
            }
          });
          displayedGenresCount = allGenres.length > 5 ? 5 : allGenres.length;
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => isLoading = false);
      debugPrint('Error: $e');
    }
  }

  Future<void> _fetchCategoryRecommendations(Map<String, dynamic> item) async {
    final id = item['id'];
    try {
      final url = 'https://api.themoviedb.org/3/${widget.mediaType}/$id/recommendations?api_key=$tmdbApiKey';
      final data = await fetchWithCache(url);
      final List recs = data['results'] as List? ?? [];
      if (mounted) {
        setState(() {
          var filtered = recs.where((item) => _isReleased(item, strictFilter: true)).toList();
          if (filtered.isEmpty) {
            filtered = recs.where((item) => _isReleased(item)).toList();
          }

          recommendations = filtered.map((item) {
            item['media_type'] = widget.mediaType;
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
        child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255)),
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
            ),
          const SizedBox(height: 20),
          HorizontalMediaList(
            categoryTitle: 'Trending Now',
            items: trendingList.length > 5 ? trendingList.skip(5).toList() : trendingList,
            apiUrl: 'https://api.themoviedb.org/3/trending/${widget.mediaType}/day?api_key=$tmdbApiKey',
          ),
          const SizedBox(height: 16),
          if (continueWatching.isNotEmpty)
            HorizontalMediaList(
              categoryTitle: 'Continue Watching',
              items: continueWatching,
              onRefresh: () => fetchData(),
            ),
          const SizedBox(height: 16),
          if (recommendations.isNotEmpty && continueWatching.isNotEmpty)
            HorizontalMediaList(
              categoryTitle: 'For You',
              items: recommendations,
              apiUrl: 'https://api.themoviedb.org/3/${widget.mediaType}/${continueWatching.first['id']}/recommendations?api_key=$tmdbApiKey',
              onChildRefresh: fetchData,
              defaultMediaType: widget.mediaType,
            ),
          const SizedBox(height: 16),
          if (topRatedList.isNotEmpty)
            HorizontalMediaList(
              categoryTitle: 'Top Rated',
              items: topRatedList,
              apiUrl: 'https://api.themoviedb.org/3/${widget.mediaType}/top_rated?api_key=$tmdbApiKey',
              defaultMediaType: widget.mediaType,
            ),
          if (widget.mediaType == 'tv' && onTheAirList.isNotEmpty) ...[
            const SizedBox(height: 16),
            HorizontalMediaList(
              categoryTitle: 'On The Air',
              items: onTheAirList,
              apiUrl: 'https://api.themoviedb.org/3/tv/on_the_air?api_key=$tmdbApiKey',
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
                child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255)),
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
    fetchGenreItems();
  }

  Future<void> fetchGenreItems() async {
    // Stagger API calls based on index to enforce deduplication priority
    // and strictly manage rate-limits to a safe trickle.
    await Future.delayed(Duration(milliseconds: (widget.index % 5) * 200));

    try {
      String url =
          'https://api.themoviedb.org/3/discover/${widget.mediaType}?api_key=$tmdbApiKey&with_genres=${widget.genreId}';
      if (widget.mediaType == 'movie') {
        url += '&with_runtime.gte=20';
      }

      final data = await fetchWithCache(url);
      if (mounted) {
        List<dynamic> deduplicatedItems = [];
        for (var item in (data['results'] as List? ?? [])) {
          if (!_isReleased(item, strictFilter: true)) continue;
          final int? id = item['id'];
          if (id != null && !widget.seenMediaIds.contains(id)) {
            item['media_type'] = widget.mediaType;
            deduplicatedItems.add(item);
            widget.seenMediaIds.add(id);
          }
        }
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
          child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255)),
        ),
      );
    }
    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: HorizontalMediaList(
        categoryTitle: widget.title, 
        items: items,
        apiUrl: 'https://api.themoviedb.org/3/discover/${widget.mediaType}?api_key=$tmdbApiKey&with_genres=${widget.genreId}${widget.mediaType == 'movie' ? '&with_runtime.gte=20' : ''}',
        defaultMediaType: widget.mediaType,
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

class _AppNotificationWidgetState extends State<_AppNotificationWidget> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  Timer? _dismissTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(milliseconds: 300), vsync: this);
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _slideAnimation = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

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
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Colors.white.withOpacity(0.15), Colors.white.withOpacity(0.03), Colors.white.withOpacity(0.03), Colors.white.withOpacity(0.1)],
                            stops: const [0.0, 0.2, 0.8, 1.0],
                          ),
                          borderRadius: BorderRadius.circular(40.0),
                          border: Border.all(color: widget.color?.withOpacity(0.3) ?? Colors.white.withOpacity(0.15), width: 1.0),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(widget.color == Colors.red ? Icons.error_outline : Icons.info_outline, color: widget.color ?? Colors.white, size: 20),
                            const SizedBox(width: 12),
                            Flexible(child: Text(widget.message, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold))),
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
  // ignore: unused_field
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

  final Map<int, List<dynamic>> _seasonEpisodesData = {};
  double _movieProgress = 0.0;
  // ignore: prefer_final_fields
  Map<int, Map<int, double>> _tvProgress = {};

  DownloadTask? _task;
  late AnimationController _spinnerController;

  @override
  void initState() {
    super.initState();
    _spinnerController =
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
          ..repeat();
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
      if (_task?.status == DownloadStatus.done) {
      }
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
    if (widget.media['id'] == null) return;
    final isOn = await WatchlistManager.isOnWatchlist(widget.media['id']);
    if (mounted) {
      setState(() {
        _isOnWatchlist = isOn;
      });
    }
  }

  // ignore: unused_element
  Future<void> _toggleWatchlist() async {
    if (_isOnWatchlist) {
      await WatchlistManager.removeFromWatchlist(widget.media['id']);
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
        title: const Text('Delete Download', style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to delete this download?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white), onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirm == true) {
      // Reconstruct file path to delete it
      final title = widget.media['title']?.toString() ?? widget.media['name']?.toString() ?? 'Unknown';
      final docsDir = await getApplicationDocumentsDirectory();
      final finalFileName = '$mediaId+$title.mp4'.replaceAll(RegExp(r'[^\w\s\.-]+'), '').replaceAll(' ', '_');
      final finalPath = '${docsDir.path}/LunarDrift/Movies/$finalFileName';
      final file = File(finalPath);

      if (await file.exists()) {
        await file.delete();
      }
      await DownloadManager().removeDownloadFromCache(mediaId);
      _updateTask(); // This will refresh the state
      if (mounted) { // No need to pop here, as this is a local action.
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download deleted.'), backgroundColor: Colors.green));
      }
    }
  }

  Future<void> fetchDetails() async {
    final mediaType = widget.media['media_type']?.toString() ?? 
                     (widget.media.containsKey('first_air_date') ? 'tv' : 'movie');
    final mediaId = widget.media['id'];
    if (mediaId == null) {
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
            // Fetch all episode progress for this show and calculate series completion
            final showProgress = await ProgressManager.getShowProgress(mediaId);
            if (mounted) {
              setState(() {
                for (var prog in showProgress) {
                  final s = prog['season'] as int?;
                  final e = prog['episode'] as int?;
                  if (s != null && e != null) {
                    _tvProgress.putIfAbsent(s, () => {})[e] =
                        (prog['progress'] as num?)?.toDouble() ?? 0.0;
                  }
                }

                // Determine if the entire series is completed
                bool allEpisodesCompleted = true;
                if (data['seasons'] is List) {
                  final seasonsList = data['seasons'] as List;
                  for (var s in seasonsList) {
                    if (s is Map) {
                      final seasonNumber = (s['season_number'] ?? 0) as int;
                      if (seasonNumber == 0) continue; // Skip "Specials" season

                      final airedEpisodeCount = _getEpisodeCountForSeason(seasonNumber);
                      if (airedEpisodeCount == 0) continue; // No aired episodes for this season

                      for (int i = 1; i <= airedEpisodeCount; i++) {
                        final episodeProgress = _tvProgress[seasonNumber]?[i] ?? 0.0;
                        if (episodeProgress < 0.9) { // Using 0.9 as threshold for completed
                          allEpisodesCompleted = false;
                          break;
                        }
                      }
                    }
                    if (!allEpisodesCompleted) break; // If any season is not complete, break outer loop
                  }
                }
                _isSeriesCompleted = allEpisodesCompleted;
              });
            }
          } else {
            // Fetch single movie progress
            final savedProgress = await ProgressManager.getProgress(mediaId);
            setState(() {
             _movieProgress = (savedProgress?['progress'] as num?)?.toDouble() ?? 0.0;
             _isMovieCompleted = _movieProgress >= 0.9; // Using 0.9 as threshold for completed
            });
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
            _extractDominantColor('https://image.tmdb.org/t/p/w500$extractedLogo');
          } else {
            final posterPath = data['poster_path']?.toString();
            if (posterPath != null) {
              _extractDominantColor('https://image.tmdb.org/t/p/w300$posterPath');
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
    final url = 'https://api.themoviedb.org/3/tv/$mediaId/season/$seasonNumber?api_key=$tmdbApiKey';
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
      return const Icon(Icons.check_circle, color: Color.fromARGB(255, 255, 255, 255), size: 16);
    } else if (progress > 0.0) {
      return SizedBox(
        width: 24,
        height: 4,
        child: LinearProgressIndicator(
          value: progress,
          backgroundColor: Colors.white24,
          valueColor: const AlwaysStoppedAnimation<Color>(Color.fromARGB(255, 255, 255, 255)),
          borderRadius: BorderRadius.circular(2),
        ),
      );
    }
    return const SizedBox.shrink();
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
    return defaultTargetPlatform == TargetPlatform.iOS
        ? ClipRRect(
            borderRadius: BorderRadius.circular(
              16,
            ),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: 20,
                sigmaY: 20,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: _dominantColor != null
                      ? _dominantColor!.withOpacity(0.15)
                      : Colors.white.withOpacity(0.15),
                  border: Border.all(
                    color: _dominantColor != null
                        ? _dominantColor!.withOpacity(0.3)
                        : Colors.white.withOpacity(0.3),
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: _dominantColor ?? Colors.white,
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                    ),
                  ),
                  onPressed: () {
                    final String progressParam = '&progress=$mainResumeSeconds';
                    final String placeholderLink = isTvShow
                        ? 'https://player.videasy.net/tv/${widget.media['id']}/$_selectedSeason/$_selectedEpisode?color=$colorHex&autoPlay=true&nextEpisode=true&overlay=true$progressParam'
                        : 'https://player.videasy.net/movie/${widget.media['id']}?color=$colorHex&autoPlay=true&overlay=true$progressParam';

                    // Save initial progress when clicking play
                    ProgressManager.saveProgress(
                      media: sourceMedia,
                      progress: currentProgress == 0 ? 0.05 : currentProgress,
                      season: isTvShow ? _selectedSeason : null,
                      episode: isTvShow ? _selectedEpisode : null,
                      position: mainResumeSeconds,
                      runtime: runtimeInt,
                    );

                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => VideoPlayerPage(
                          videoUrl: placeholderLink,
                          media: sourceMedia,
                          season: isTvShow ? _selectedSeason : null,
                          episode: isTvShow ? _selectedEpisode : null,
                        ),
                      ),
                ).then((videoPlayerChanged) {
                  if (mounted) { if (videoPlayerChanged == true) setState(() => _hasMadeChanges = true); fetchDetails(); }
                });
                  },
                  icon: const Icon(
                    Icons.play_arrow,
                    size: 24,
                  ),
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
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          )
        : ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: (!isTvShow && _isCamRelease)
                  ? Colors.red
                  : (_dominantColor ?? Colors.white),
              foregroundColor: (!isTvShow && _isCamRelease)
                  ? Colors.white
                  : ((_dominantColor?.computeLuminance() ?? 1.0) < 0.5
                      ? Colors.white
                      : Colors.black),
              padding: const EdgeInsets.symmetric(
                vertical: 12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4.0),
              ),
            ),
            onPressed: () {
              final String progressParam = '&progress=$mainResumeSeconds';
              final String placeholderLink = isTvShow
                  ? 'https://player.videasy.net/tv/${widget.media['id']}/$_selectedSeason/$_selectedEpisode?color=$colorHex&autoPlay=true&nextEpisode=true&overlay=true$progressParam'
                  : 'https://player.videasy.net/movie/${widget.media['id']}?color=$colorHex&autoPlay=true&overlay=true$progressParam';

              // Save initial progress when clicking play
              ProgressManager.saveProgress(
                media: sourceMedia,
                progress: currentProgress == 0 ? 0.05 : currentProgress,
                season: isTvShow ? _selectedSeason : null,
                episode: isTvShow ? _selectedEpisode : null,
                position: mainResumeSeconds,
                runtime: runtimeInt,
              );

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => VideoPlayerPage(
                    videoUrl: placeholderLink,
                    media: sourceMedia,
                    season: isTvShow ? _selectedSeason : null,
                    episode: isTvShow ? _selectedEpisode : null,
                  ),
                ),
            ).then((videoPlayerChanged) {
              if (mounted) { if (videoPlayerChanged == true) setState(() => _hasMadeChanges = true); fetchDetails(); }
            });
            },
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.play_arrow, size: 24),
                  const SizedBox(width: 8),
                  Text(
                    isTvShow
                        ? ((currentProgress > 0 && currentProgress < 1.0)
                            ? 'Resume S$_selectedSeason E$_selectedEpisode'
                            : 'Play S$_selectedSeason E$_selectedEpisode')
                        : ((currentProgress > 0 && currentProgress < 1.0)
                            ? (_isCamRelease ? 'Resume (Cam)' : 'Resume')
                            : (_isCamRelease ? 'Play (Cam)' : 'Play')),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    softWrap: false,
                  ),
                ],
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
          title: widget.media['title']?.toString() ??
              widget.media['name']?.toString() ??
              'Unknown',
          year: releaseYear,
          resolution: resolution,
          mediaType: widget.media['media_type']?.toString() ?? 'movie',
            posterPath: posterPath
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
          border: Border.all(
            color: isSelected ? Colors.white : Colors.white38,
          ),
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
      iconChild = const Icon(Icons.delete_outline, color: Colors.white, size: 24);
    } else {
      switch (status) {
        case DownloadStatus.requesting:
          iconChild = const SizedBox.shrink(); // Spinner is painted outside
          break;
        case DownloadStatus.downloading:
          iconChild = Text(
            '${(progress * 100).floor()}%',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
          );
          break;
        case DownloadStatus.done:
          // This case is handled by isDownloaded, but kept for safety.
          iconChild = const Icon(Icons.check, color: Color.fromARGB(255, 255, 255, 255), size: 24);
          break;
        case DownloadStatus.failed:
          iconChild = const Icon(Icons.close, color: Colors.redAccent, size: 28);
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
            shape: BoxShape.circle,
          ),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                padding: EdgeInsets.zero,
                side: BorderSide.none,
                shape: const CircleBorder()),            
            onPressed: () {
              if (isDownloaded) {
                _handleDelete();
              } else if (status == DownloadStatus.none || status == DownloadStatus.failed) {
                setState(() => _isDownloadActive = true);
              } else if (status == DownloadStatus.downloading || status == DownloadStatus.requesting) {
                DownloadManager().cancelDownload(widget.media['id'].toString());
              }
            },
            child: AnimatedSwitcher(duration: const Duration(milliseconds: 300), child: Align(key: ValueKey(status), alignment: Alignment.center, child: iconChild)),
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
        border: Border.all(
          color: Colors.white.withOpacity(0.15),
        ),
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
                _buildResolutionButton('480p', 'SD', posterPath, logoPath, backdropPath, overview),
                  const SizedBox(width: 8),
                _buildResolutionButton('720p', 'HD', posterPath, logoPath, backdropPath, overview),
                  const SizedBox(width: 8),
                _buildResolutionButton('1080p', 'FHD', posterPath, logoPath, backdropPath, overview),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrailerButton() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        border: Border.all(
          color: Colors.white.withOpacity(0.15),
        ),
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
                pageBuilder: (
                  context,
                  animation,
                  secondaryAnimation,
                ) =>
                    FullscreenTrailerPage(
                  trailerKey: _trailerKey!,
                ),
                transitionsBuilder: (
                  context,
                  animation,
                  secondaryAnimation,
                  child,
                ) {
                  return FadeTransition(
                    opacity: animation,
                    child: child,
                  );
                },
              ),
            );
          } else {
            showDialog(
              context: context,
              builder: (context) => TrailerPlayerDialog(
                trailerKey: _trailerKey!,
              ),
            );
          }
        },
        child: const Icon(Icons.movie_creation_outlined, size: 24),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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

    final bool isTvShow = sourceMedia['media_type'] == 'tv' || sourceMedia.containsKey('first_air_date');
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

    final reviewsData =
        details['reviews'] is Map ? details['reviews'] as Map : null;
    final reviews = (reviewsData != null && reviewsData['results'] is List
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
          if (item is Map && !item.containsKey('media_type')) {
            item['media_type'] = isTvShow ? 'tv' : 'movie';
          }
          return item;
        })
        .where((item) => _isReleased(item, strictFilter: true))
        .take(15)
        .toList();

    final backgroundImageUrl = backdropPath != null
        ? 'https://image.tmdb.org/t/p/w1280$backdropPath'
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
                  child: Icon(_isOnWatchlist ? Icons.check : Icons.add, size: 26),
                ),
              ),
            ),
          ),
        ], // Watchlist button
          ),
          body: Stack(
            fit: StackFit.expand,
            children: [ // Background image and gradient
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
                child: SafeArea( // Ensures content is not obscured by system UI
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      isMobile ? 20.0 : 40.0,
                      100.0,
                      isMobile ? 20.0 : 40.0,
                      40.0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: isMobile // Conditional padding for mobile vs desktop
                              ? const EdgeInsets.all(16.0)
                              : EdgeInsets.zero,
                          decoration: const BoxDecoration(),
                          child: Column(
                            crossAxisAlignment: isMobile
                                ? CrossAxisAlignment.center
                                : CrossAxisAlignment.start,
                            children: [
                              if (_logoPath != null)
                                CachedNetworkImage(
                                  imageUrl:
                                      'https://image.tmdb.org/t/p/w500$_logoPath',
                                  width: 250, // Fixed width for logo
                                  height: 100,
                                  fit: BoxFit.contain,
                                  alignment: isMobile
                                      ? Alignment.center
                                      : Alignment.centerLeft,
                                )
                              else
                                Text(
                                  title,
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
                                Wrap( // For responsive layout of details
                                  spacing: 16,
                                  runSpacing: 8,
                                  alignment: isMobile
                                      ? WrapAlignment.center
                                      : WrapAlignment.start,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (_contentRating.isNotEmpty)
                                      Container( // Content rating badge
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                              color: Colors.white54),
                                          borderRadius:
                                              BorderRadius.circular(4),
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
                                      style: TextStyle( // Release year
                                        color: Colors.white70,
                                        fontSize: isMobile ? 14 : 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [ // Star rating
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
                                      Text( // Runtime for movies
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
                                        style: TextStyle( // Episodes for TV shows
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
                                    style: TextStyle(
                                      color: Colors.white54,
                                      fontSize: isMobile ? 12 : 14,
                                    ),
                                  ),
                                ],
                              ],
                              const SizedBox(height: 16), // Spacing
                              if ((!isTvShow && _isMovieCompleted) || (isTvShow && _isSeriesCompleted))
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 12.0),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
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
                                          color: const Color.fromARGB(255, 255, 255, 255),
                                          size: isMobile ? 16 : 18,
                                        ),
                                    ],
                                  ),
                                ),
                                Row( // Play and Download buttons
                                  mainAxisAlignment: isMobile
                                      ? MainAxisAlignment.center
                                      : MainAxisAlignment.start,
                                  children: [Expanded(
                                    child: LayoutBuilder(builder: (context, constraints) {
                                      final containerWidth = constraints.maxWidth;
                                      const trailerButtonWidth = 56.0;
                                      final downloadButtonWidth = isTvShow ? 0.0 : 56.0;
                                      const spacing = 12.0; // Spacing between buttons
                                      final downloadSpacing = isTvShow ? 0.0 : spacing;
                                  
                                      // Inactive positions (from the right)
                                      const downloadRightInactive = 0.0;
                                      final trailerRightInactive = _trailerKey != null ? (downloadButtonWidth + downloadSpacing) : -100.0;
                                      final playRightInactive = _trailerKey != null
                                          ? (trailerRightInactive + trailerButtonWidth + spacing)
                                          : (downloadButtonWidth + downloadSpacing);
                                  
                                      final trailerLeftInactive = _trailerKey != null ? (containerWidth - trailerRightInactive - trailerButtonWidth) : 0.0;

                                      return SizedBox(
                                        height: 56, // Fixed height for button row
                                        child: Stack(
                                          alignment: Alignment.centerRight,
                                          children: [
                                            // Play Button
                                            AnimatedPositioned(
                                              duration: const Duration(milliseconds: 400),
                                              curve: Curves.easeInOut,
                                              left: 0, // Play button always starts from left
                                              right: _isDownloadActive ? containerWidth : playRightInactive,
                                              child: ClipRect(
                                                child: AnimatedOpacity(
                                                  duration: const Duration(milliseconds: 200),
                                                  opacity: _isDownloadActive ? 0.0 : 1.0,
                                                  child: _buildPlayButton(mainResumeSeconds),
                                                ),
                                              ),
                                            ),
                                  
                                            // Trailer Button
                                            if (_trailerKey != null)
                                              AnimatedPositioned(
                                                duration: const Duration(milliseconds: 400), // Animation duration
                                                curve: Curves.easeInOut,
                                                left: _isDownloadActive ? -trailerButtonWidth - spacing : trailerLeftInactive,
                                                width: trailerButtonWidth,
                                                height: 56,
                                                child: AnimatedOpacity(
                                                  duration: const Duration(milliseconds: 200),
                                                  opacity: _isDownloadActive ? 0.0 : 1.0,
                                                  child: _buildTrailerButton(),
                                                ),
                                              ),
                                  
                                            if (!isTvShow)
                                              // Download Button/UI
                                              AnimatedPositioned(
                                                duration: const Duration(milliseconds: 400),
                                                curve: Curves.easeInOut, // Animation curve
                                                width: _isDownloadActive ? containerWidth : 56.0,
                                                right: downloadRightInactive,
                                                height: 56,
                                                child: AnimatedSwitcher(
                                                  duration: const Duration(milliseconds: 200),
                                                  layoutBuilder: (currentChild, previousChildren) {
                                                    return Stack(
                                                      alignment: Alignment.center,
                                                      children: <Widget>[
                                                        ...previousChildren, // Keep previous children during transition
                                                       
                                                      if (currentChild != null) currentChild,
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
                                    }),
                                  ),],
                                ), // Progress indicator for continue watching
                          if (currentProgress > 0 && currentProgress < 1.0)
                            Padding(
                              padding: const EdgeInsets.only(top: 12.0),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
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
                                              Color.fromARGB(255, 255, 255, 255)),
                                      borderRadius: BorderRadius.circular(
                                        2,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            
                          
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      overview,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: isMobile ? 14 : 16,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 40),
                    ...[
                      Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'CAST',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                        ),
                        const SizedBox(height: 16),
                        castList.isEmpty // Conditional display for cast list
                            ? const Text(
                                'Cast information is unavailable.',
                                style: TextStyle(color: Colors.white70),
                              )
                            : SizedBox(
                                height: 190,
                                child: ListView.builder(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: castList.length, // Number of cast members
                                  itemBuilder: (context, index) {
                                    final actor = castList[index];
                                    if (actor == null || actor is! Map) {
                                      return const SizedBox.shrink();
                                    }

                                    final profilePath = actor['profile_path']
                                        ?.toString();
                                    final actorImageUrl = profilePath != null
                                        ? 'https://image.tmdb.org/t/p/w200$profilePath'
                                        : 'https://via.placeholder.com/200x300?text=No+Image';
                                    final actorName =
                                        actor['name']?.toString() ?? 'Unknown';
                                    final characterName =
                                        actor['character']?.toString() ?? '';
                                    final actorId = actor['id'];

                                    return MouseRegion(
                                      cursor: SystemMouseCursors.click, // Cursor for clickable items
                                      child: GestureDetector(
                                        onTap: () {
                                          if (actorId != null) {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (context) =>
                                                    ActorDetailsPage(
                                                      actorId: actorId,
                                                      actorName: actorName,
                                                    ),
                                              ),
                                            );
                                          }
                                        },
                                        child: Container(
                                          width: 90,
                                          margin: const EdgeInsets.only( // Spacing between cast items
                                            right: 12.0,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.center,
                                            children: [
                                              ClipOval(
                                                child: CachedNetworkImage( // Actor profile image
                                                  imageUrl: actorImageUrl,
                                                  width: 70,
                                                  height: 70,
                                                  fit: BoxFit.cover,
                                                  placeholder: (context, url) =>
                                                      Container(
                                                        width: 70,
                                                        height: 70,
                                                        color: Colors.white24,
                                                      ),
                                                  errorWidget:
                                                      (
                                                        context,
                                                        url,
                                                        error,
                                                      ) => Container(
                                                        width: 70,
                                                        height: 70,
                                                        color: Colors.white24,
                                                        child: const Icon(
                                                          Icons.person,
                                                          color: Colors.white54,
                                                        ),
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(height: 8), // Spacing
                                              Text(
                                                actorName,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                                textAlign: TextAlign.center,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              if (characterName.isNotEmpty) ...[
                                                const SizedBox(height: 4), // Spacing
                                                Text(
                                                  characterName,
                                                  style: const TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 11,
                                                    fontStyle: FontStyle.italic,
                                                  ),
                                                  textAlign: TextAlign.center,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),

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
                                double progress = _getSeasonProgress(s, _getEpisodeCountForSeason(s));
                                return GestureDetector( // Season selection button
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
                                    margin: const EdgeInsets.only(right: 12), // Spacing between season buttons
                                    padding: const EdgeInsets.symmetric(horizontal: 16),
                                    decoration: BoxDecoration(
                                      color: isSelected 
                                        ? (_dominantColor ?? const Color(0xFF1CE783)) 
                                        : Colors.white.withOpacity(0.05),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(color: isSelected ? Colors.transparent : Colors.white10),
                                    ),
                                    alignment: Alignment.center,
                                    child: Row( // Season text and progress indicator
                                      children: [
                                        Text(
                                          'Season $s',
                                          style: TextStyle(
                                            color: isSelected 
                                              ? ((_dominantColor?.computeLuminance() ?? 1.0) < 0.5 ? Colors.white : Colors.black) 
                                              : Colors.white70,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                          ),
                                        ),
                                        if (progress >= 1.0) ...[
                                          const SizedBox(width: 8), // Spacing
                                          Icon(Icons.check_circle, size: 16, color: isSelected ? ((_dominantColor?.computeLuminance() ?? 1.0) < 0.5 ? Colors.white : Colors.black) : Colors.white70),
                                        ] else if (progress > 0.0) ...[
                                          const SizedBox(width: 8), // Spacing
                                          Icon(Icons.brightness_medium, size: 16, color: isSelected ? ((_dominantColor?.computeLuminance() ?? 1.0) < 0.5 ? Colors.white : Colors.black) : Colors.white70), // Half-filled circle for in-progress
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
                                            e['episode_number']?.toString() ??
                                                '',
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
                                  epStillPath = epData['still_path']
                                      ?.toString();
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
                                  subtitleChildren.add(
                                    const SizedBox(height: 4),
                                  );
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
                                  subtitleChildren.add(
                                    const SizedBox(height: 4),
                                  );
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
                                  if (subtitleChildren.isNotEmpty) { // Add spacing if other subtitles exist
                                    subtitleChildren.add(const SizedBox(height: 6));
                                  }
                                  final int resumeMins = ((epRuntime ?? 45) * progress).toInt();
                                  final int rHr = resumeMins ~/ 60;
                                  final int rMin = resumeMins % 60;
                                  subtitleChildren.add(
                                    Text(
                                      'Resuming from ${rHr > 0 ? '${rHr}h ' : ''}${rMin}m',
                                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                    ),
                                  );
                                }
                              }

                              Widget? subtitleWidget =
                                  subtitleChildren.isNotEmpty
                                  ? Padding( // Subtitle widget for episode details
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
                                    child: Container(
                                      margin: const EdgeInsets.only(
                                        bottom: 12.0,
                                      ),
                                      clipBehavior: Clip.hardEdge,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular( // Rounded corners for episode card
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
                                            () => isInteractionActive =
                                                highlighted,
                                          );
                                        },
                                        child: IntrinsicHeight( // Ensures children take up full height
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              Expanded(
                                                flex: 4, // Extended width to the right
                                                child: GestureDetector(
                                                  onTap: () {
                                                    setState(() { // Update selected episode
                                                      _visualSelectedEpisode = val;
                                                      _selectedEpisode = val;
                                                    });
                                                    final String progressParam = '&progress=$epResumeSeconds';
                                                    final String placeholderLink = 'https://player.videasy.net/tv/${widget.media['id']}/$_selectedSeason/$val?color=$colorHex&autoPlay=true&nextEpisode=true&overlay=true$progressParam';
                                                    Navigator.push(
                                                      context,
                                                      MaterialPageRoute(
                                                        builder: (context) => VideoPlayerPage(
                                                          videoUrl: placeholderLink,
                                                          media: sourceMedia,
                                                          season: _selectedSeason,
                                                          episode: val,
                                                        ),
                                                      ),
                                                    ).then((videoPlayerChanged) {
                                                      if (mounted) {
                                                        fetchDetails();
                                                      }
                                                    });
                                                    ProgressManager.saveProgress(
                                                      media: sourceMedia,
                                                      progress: progress == 0 ? 0.05 : progress,
                                                      season: _selectedSeason,
                                                      episode: val,
                                                      position: epResumeSeconds,
                                                      runtime: epRuntime,
                                                    );
                                                  },
                                                  child: Container(
                                                    clipBehavior: Clip.hardEdge,
                                                    decoration: const BoxDecoration(
                                                      borderRadius: BorderRadius.only( // Rounded corners for episode image
                                                        topLeft: Radius.circular(8.0),
                                                        bottomLeft: Radius.circular(8.0),
                                                      ),
                                                    ),
                                                    child: Stack(
                                                      alignment: Alignment.center,
                                                      children: [
                                                        Positioned.fill( // Dark overlay for image
                                                          child: Container(
                                                            color: Colors.black.withOpacity(0.3), // Dark overlay
                                                          ),
                                                        ),
                                                        Positioned.fill(
                                                          child: epStillPath != null
                                                              ? CachedNetworkImage(
                                                                  imageUrl: 'https://image.tmdb.org/t/p/w500$epStillPath', // Episode still image
                                                                  fit: BoxFit.cover,
                                                                  placeholder: (context, url) => Container(color: Colors.black26),
                                                                  errorWidget: (context, url, error) => Container(
                                                                    color: Colors.black26,
                                                                    child: const Icon(Icons.broken_image, color: Colors.white54),
                                                                  ),
                                                                )
                                                              : Container(
                                                                  color: Colors.black26,
                                                                  child: const Icon(Icons.tv, color: Colors.white54, size: 60),
                                                                ),
                                                        ), // Gradient overlay for text
                                                        Positioned.fill(
                                                          child: Container(
                                                            decoration: BoxDecoration(
                                                              gradient: LinearGradient(
                                                                begin: Alignment.centerLeft,
                                                                end: Alignment.centerRight,
                                                                colors: [
                                                                  Colors.transparent,
                                                                  Colors.transparent,
                                                                  const Color(0xFF1E1F24).withOpacity(0.8),
                                                                  const Color(0xFF1E1F24),
                                                                ],
                                                                stops: const [0.0, 0.7, 0.9, 1.0],
                                                              ),
                                                            ),
                                                          ),
                                                        ), // Play button and progress indicator
                                                      CustomPaint(
                                                        painter: DownloadProgressPainter(
                                                          status: progress >= 0.9 ? DownloadStatus.done : (progress > 0 ? DownloadStatus.downloading : DownloadStatus.none),
                                                          progress: progress,
                                                          rotationAnimation: _spinnerController,
                                                          color: _dominantColor ?? const Color(0xFF1CE783),
                                                        ),
                                                        child: Padding(
                                                          padding: const EdgeInsets.all(2.0),
                                                          child: Icon(
                                                            Icons.play_circle_fill,
                                                            color: (isMobile || isInteractionActive) ? Colors.white : Colors.white54,
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
                                                  padding: const EdgeInsets.only(left: 4.0, right: 16.0, top: 12.0, bottom: 12.0), // Padding for episode text
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      Row(
                                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                        children: [
                                                          Expanded(
                                                            child: Text( // Episode title
                                                              titleText,
                                                              style: TextStyle(
                                                                color: isSelected ? const Color(0xFF1CE783) : Colors.white,
                                                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                      if (subtitleWidget != null) subtitleWidget,
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        )));
                                },
                              );
                            },
                          ),
                        ],

                        if (recommendationsList.isNotEmpty) ...[
                          const SizedBox(height: 40),
                          HorizontalMediaList( // Recommendations section
                            categoryTitle: 'Recommendations',
                            items: recommendationsList,
                            showTitle: true,
                            listPadding: const EdgeInsets.only(right: 212.0),
                          ),
                        ],
                        const SizedBox(height: 40),
                        Text( // Details section title
                          'DETAILS',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                        ),
                        const SizedBox(height: 16),
                        if (isTvShow) ...[ // TV show specific details
                          _buildDetailRow('Network', networks),
                          _buildDetailRow('Type', type),
                          _buildDetailRow('Status', status),
                          _buildDetailRow('First Aired', firstAirDate),
                          _buildDetailRow('Last Aired', lastAirDate),
                          _buildDetailRow('In Production', inProduction),
                        ] else ...[
                          _buildDetailRow('Status', status), // Movie specific details
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
                          ListView.builder( // Reviews list
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
                              final content =
                                  review['content']?.toString() ?? '';
                              final authorDetails =
                                  review['author_details'] is Map
                                  ? review['author_details'] as Map
                                  : null;
                              final rating = authorDetails != null
                                  ? authorDetails['rating']?.toString()
                                  : null;

                              return Container(
                                margin: const EdgeInsets.only(bottom: 16.0),
                                padding: const EdgeInsets.all(16.0), // Padding for review card
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
                                        Text( // Author name
                                          author,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                        const Spacer(),
                                        if (rating != null) ...[
                                          const Icon( // Star icon for rating
                                            Icons.star,
                                            color: Color.fromARGB(255, 255, 255, 255),
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
                                    Text( // Review content
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
                      ),
                    ],
                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),
          ),
          if (!_showContent) // Loading indicator
            const Center(
              child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255)),
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
  State<DownloadedMediaDetailsPage> createState() => _DownloadedMediaDetailsPageState();
}

class _DownloadedMediaDetailsPageState extends State<DownloadedMediaDetailsPage> {
  late File _videoFile;
  Map<String, dynamic>? _mediaDetails;
  String? _logoPath;
  Color? _dominantColor;
  // ignore: unused_field, prefer_final_fields
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
      debugPrint('Could not calculate file size for ${widget.item.filePath}: $e');
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
          const SnackBar(content: Text('Error: Downloaded file not found.'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    try {
      final mediaType = widget.item.mediaType;
      final mediaId = widget.item.mediaId;
      final url = 'https://api.themoviedb.org/3/$mediaType/$mediaId?api_key=$tmdbApiKey&append_to_response=images,content_ratings,release_dates';
      final data = await fetchWithCache(url);

      String? extractedLogo;
      if (data['images'] != null && data['images']['logos'] is List) {
        final logos = data['images']['logos'] as List;
        final validLogos = logos.where((l) => l is Map && !(l['file_path']?.toString().toLowerCase().endsWith('.svg') ?? false)).toList();
        if (validLogos.isNotEmpty) {
          validLogos.sort((a, b) => (double.tryParse(b['vote_average']?.toString() ?? '0') ?? 0.0).compareTo(double.tryParse(a['vote_average']?.toString() ?? '0') ?? 0.0));
          final enLogo = validLogos.firstWhere((l) => l['iso_639_1'] == 'en', orElse: () => validLogos.first);
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
      final colorScheme = await ColorScheme.fromImageProvider(provider: CachedNetworkImageProvider(imageUrl), brightness: Brightness.dark);
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
    final mediaId = int.tryParse(widget.item.mediaId);
    if (mediaId == null) return;
    final isOn = await WatchlistManager.isOnWatchlist(mediaId);
    if (mounted) {
      setState(() {
        _isOnWatchlist = isOn;
      });
    }
  }

  Future<void> _toggleWatchlist() async {
    final mediaId = int.tryParse(widget.item.mediaId);
    if (mediaId == null) return;
    if (_isOnWatchlist) {
      await WatchlistManager.removeFromWatchlist(mediaId);
    } else {
      await WatchlistManager.addToWatchlist(_mediaDetails ?? {
        'id': mediaId,
        'title': widget.item.title,
        'poster_path': widget.item.posterPath,
        'media_type': widget.item.mediaType,
      });
    }
    _checkWatchlistStatus();
  }

  Future<void> _handleDelete() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1F24),
        title: const Text('Delete Download', style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to delete this download?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white), onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirm == true) {
      await _videoFile.delete();
      await DownloadManager().removeDownloadFromCache(widget.item.mediaId);
      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download deleted.'), backgroundColor: Colors.green));
      }
    }
  }

  Widget _buildDownloadedButtons() {
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                decoration: BoxDecoration(
                  color: _dominantColor != null
                      ? _dominantColor!.withOpacity(0.15)
                      : Colors.white.withOpacity(0.15),
                  border: Border.all(
                    color: _dominantColor != null
                        ? _dominantColor!.withOpacity(0.3)
                        : Colors.white.withOpacity(0.3),
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: _dominantColor ?? Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) =>
                        LocalVideoPlayerPage(
                          videoFile: _videoFile,
                          title: widget.item.title,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.play_arrow, size: 24),
                  label: const Text('Play Offline',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 56,
          height: 56,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
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
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sourceMedia = _mediaDetails ?? {'title': widget.item.title, 'name': widget.item.title};
    final title = sourceMedia['title']?.toString() ?? sourceMedia['name']?.toString() ?? 'Unknown';
    final backdropPath = sourceMedia['backdrop_path']?.toString();
    final backgroundImageUrl = backdropPath != null
        ? 'https://image.tmdb.org/t/p/w1280$backdropPath'
        : 'https://via.placeholder.com/1280x720?text=No+Image';

    final details = _mediaDetails ?? {};
    final isTvShow = widget.item.mediaType == 'tv';

    String contentRating = '';
    if (_mediaDetails != null) {
      if (isTvShow) {
        final results = (details['content_ratings']?['results'] as List?)?.whereType<Map>().toList() ?? [];
        for (var r in results) {
          if (r['iso_3166_1'] == 'US' && r['rating'] != null) {
            contentRating = r['rating'].toString();
            break;
          }
        }
      } else {
        final results = (details['release_dates']?['results'] as List?)?.whereType<Map>().toList() ?? [];
        for (var r in results) {
          if (r['iso_3166_1'] == 'US' && r['release_dates'] is List) {
            for (var d in r['release_dates']) {
              if (d is Map && d['certification'] != null && d['certification'].toString().isNotEmpty) {
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
    final year = (releaseDateRaw?.toString() ?? '').length >= 4 ? releaseDateRaw.toString().substring(0, 4) : '';

    final voteAverageRaw = details['vote_average'];
    final voteAverage = voteAverageRaw != null ? double.tryParse(voteAverageRaw.toString())?.toStringAsFixed(1) : null;

    final runtimeRaw = details['runtime'] ?? (details['episode_run_time'] is List && (details['episode_run_time'] as List).isNotEmpty ? (details['episode_run_time'] as List)[0] : null);
    String runtimeStr = '';
    if (runtimeRaw is num && runtimeRaw > 0) {
        final int hrs = runtimeRaw.toInt() ~/ 60;
        final int mins = runtimeRaw.toInt() % 60;
        runtimeStr = hrs > 0 ? '${hrs}h ${mins}m' : '${mins}m';
    }

    final genresList = (details['genres'] as List?)?.whereType<Map>().toList() ?? [];
    final genres = genresList.map((g) => g['name']).join(', ');

    final overview = details['overview']?.toString();

    return Scaffold(
      backgroundColor: const Color(0xFF0F1014),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent, // Ensure transparent for consistent look
        iconTheme: const IconThemeData(color: Colors.white, size: 28), // Back button icon
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
                  child: Icon(_isOnWatchlist ? Icons.check : Icons.add, size: 26),
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
            Opacity(opacity: 0.2, child: CachedNetworkImage(imageUrl: backgroundImageUrl, fit: BoxFit.cover)),
          Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [Colors.transparent, Color(0xFF0F1014)], begin: Alignment.topCenter, end: Alignment.bottomCenter, stops: [0.2, 1.0]))),
          if (_isLoading) // Loading indicator
            const Center(child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255)))
          else
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40.0, vertical: 20.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Spacer(flex: 2), // Spacing
                    if (_logoPath != null)
                      CachedNetworkImage(imageUrl: 'https://image.tmdb.org/t/p/w500$_logoPath', width: 300, height: 150, fit: BoxFit.contain)
                    else
                      Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold, color: Colors.white, height: 1.1)),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (contentRating.isNotEmpty) // Content rating badge
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white54),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            contentRating,
                            style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                        ),
                      if (year.isNotEmpty)
                        Text( // Release year
                          year,
                          style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      if (voteAverage != null)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star, color: Color.fromARGB(255, 255, 255, 255), size: 18), // Star icon for rating
                            const SizedBox(width: 4),
                            Text(
                              '$voteAverage / 10',
                              style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      if (runtimeStr.isNotEmpty)
                        Text( // Runtime
                          runtimeStr,
                          style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                    ],
                  ),
                  if (genres.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(genres, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 14)),
                  ], // Genres
                    const Spacer(flex: 1),
                    _buildDownloadedButtons(),
                  if (overview != null && overview.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(overview, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5), maxLines: 3, overflow: TextOverflow.ellipsis),
                  ],
                  if (_fileSize.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('File Size: $_fileSize', style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
          child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255)),
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
    // ignore: unused_local_variable
    final youtubeUrl =
        'https://www.youtube.com/embed/\${widget.trailerKey}?autoplay=1&playsinline=1&origin=http://localhost';
    // ignore: unused_local_variable
    final proxyUrl = _triedFallbackProxy
        ? 'https://cors-anywhere.com/\$youtubeUrl'
        : 'https://corsproxy.io/?\${Uri.encodeComponent(youtubeUrl)}';

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
          src="\$proxyUrl" 
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
      'https://www.youtube.com/watch?v=\${widget.trailerKey}',
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
                          'https://www.youtube.com/watch?v=\${widget.trailerKey}',
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
              child: CircularProgressIndicator(color: Color.fromARGB(255, 255, 255, 255)),
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
  final String? videoUrl;
  final List<Map<String, String>>? sources;
  final String? matchTitle;
  final Map<String, dynamic>? media;
  final int? season;
  final int? episode;

  const VideoPlayerPage({
    super.key,
    this.videoUrl,
    this.sources,
    this.matchTitle,
    this.media,
    this.season,
    this.episode,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  InAppWebViewController? _webViewController;
  Timer? _webPopupTimer;
  Timer? _controlsTimer;
  String? _currentUrl;
  // ignore: unused_field
  bool _isLoading = true;
  bool _isChangingStream = false;
  double _lastSavedProgress = 0.0;
  int _lastPosition = 0;
  int _lastRuntime = 0;

  // Highly aggressive content blocking rules
  final List<ContentBlocker> _contentBlockers = [ // Content blockers for WebView
    // Block common ad/popup domains individually
    // iOS Content Rule Lists do not support "Disjunctions" (| operator) in a single filter.
    ...["ads", "popads", "doubleclick", "googleadservices", "adservice", "ad-delivery", "onclickads", "bet365", "1xbet", "mostbet"]
        .map((pattern) => ContentBlocker(
              trigger: ContentBlockerTrigger(
                urlFilter: ".*$pattern.*",
              ),
              action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
            )),
    // Hide common invisible overlay and ad classes/ids
    ContentBlocker( // CSS display none for common ad/overlay elements
      trigger: ContentBlockerTrigger(urlFilter: ".*"),
      action: ContentBlockerAction(
        type: ContentBlockerActionType.CSS_DISPLAY_NONE,
        // Removed the explicit z-index 2147483647 block to prevent hiding our own UI
        // Loosened: Removed '.overlay' and '#overlay' as they are commonly used by player UIs
        selector: ".ad, .ads, .ad-container, [class*='popup'], [id*='popup'], .invisible-overlay",
      ),
    ),
    ContentBlocker( // Block third-party images
      trigger: ContentBlockerTrigger(
        urlFilter: ".*",
        resourceType: [ContentBlockerTriggerResourceType.IMAGE],
        loadType: [ContentBlockerTriggerLoadType.THIRD_PARTY],
      ),
      action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
    ),
  ];

  @override
  void initState() {
    super.initState();

    // Pre-process the URL for Web to ensure registration matches rendering.
    // This prevents a white screen caused by key mismatch in the platform view registry.
    String url = widget.videoUrl ?? 'about:blank';
    if (kIsWeb && url != 'about:blank' && !url.contains('mute=')) {
      final separator = url.contains('?') ? '&' : '?';
      // Autoplay + Mute is required for video to play on many browsers without user interaction
      url = '$url${separator}autoplay=1&mute=1';
    }
    _currentUrl = url;

    if (!kIsWeb && // Set preferred orientation for mobile
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeRight,
        DeviceOrientation.landscapeLeft,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _resetControlsTimer();

    final isNativeWebView =
        !kIsWeb && // Check if native WebView is supported
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    if (kIsWeb) {
      // On Web, set loading to false immediately as we can't reliably
      // detect iframe 'load stop' without complex JS Interop.
      _isLoading = false;
    }

    if (kIsWeb && _currentUrl != null) {
      registerWebIframe(_currentUrl!);
      // Show helpful tip for web users
      // Show a helpful tip on the Web since we cannot natively automate the server switch here
      if (!_hasShownWebPopup) {
        _webPopupTimer = Timer(const Duration(seconds: 10), () {
          if (mounted) {
            _hasShownWebPopup = true;
            final size = MediaQuery.sizeOf(context);
            // Pushes the SnackBar to the top right by creating large bottom and left margins
            final bottomMargin = size.height > 120 ? size.height - 120 : 20.0;
            // Restricts the width to ~350px on desktop, but falls back to full width on mobile
            final leftMargin = size.width > 400 ? size.width - 380 : 24.0;

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                duration: const Duration(seconds: 5),
                behavior: SnackBarBehavior.floating,
                margin: EdgeInsets.only(
                  bottom: bottomMargin,
                  left: leftMargin,
                  right: 24,
                ),
                dismissDirection: DismissDirection.horizontal,
                padding:
                    EdgeInsets.zero, // Remove default padding to use our own
                content: ClipRRect(
                  borderRadius: BorderRadius.circular(12.0),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 16,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1F24).withOpacity(0.85),
                        borderRadius: BorderRadius.circular(12.0),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                      child: const Text(
                        'Having issues loading the video?\nTry switching to the Sage server!',
                        style: TextStyle(
                          color: Color.fromARGB(255, 255, 255, 255),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
        });
      }
    } else if (isNativeWebView) {
    }
  }

  Future<void> _switchStream(Map<String, String> source) async {
    setState(() {
      _isChangingStream = true;
    });

    final newUrl = await LiveSportsApi().fetchStreamUrl(
      source['source']!,
      source['id']!,
    );

    if (mounted) {
      if (newUrl != null && newUrl.isNotEmpty) {
        setState(() => _currentUrl = newUrl);
        _webViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(newUrl)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load this stream source.')),
        );
      }
      setState(() => _isChangingStream = false);
    }
  }

  void _resetControlsTimer() {
    if (!mounted) return;
    setState(() {});
    _controlsTimer?.cancel();
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _webPopupTimer?.cancel();
    _controlsTimer?.cancel();
    if (widget.media != null && _lastRuntime > 0) {
       ProgressManager.saveProgress(
          media: widget.media!,
          progress: _lastSavedProgress,
          season: widget.season,
          episode: widget.episode,
          position: _lastPosition,
          runtime: _lastRuntime,
        );
    }
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Future<void> _stopAndPop({bool savedProgress = false}) async {
    if (_webViewController != null) {
      // Load a blank page instantly to cut off playing audio before popping
      _webViewController!.loadUrl(urlRequest: URLRequest(url: WebUri('about:blank')));
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  } // This method is not used directly by the PopScope, but by the back button.

  @override
  Widget build(BuildContext context) {
    final isNativeWebView =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        _stopAndPop(savedProgress: _lastSavedProgress > 0); // Pass savedProgress to pop
      },
      child: Stack(
        children: [
          MouseRegion(
            onHover: (_) => _resetControlsTimer(),
            child: GestureDetector(
              onTap: _resetControlsTimer,
              behavior: HitTestBehavior.translucent,
              child: Scaffold(
                backgroundColor: Colors.black,
                extendBodyBehindAppBar: isNativeWebView,
                appBar: isNativeWebView
                    ? null
                    : AppBar(
                        backgroundColor: Colors.black,
                        elevation: 0,
                        iconTheme: const IconThemeData(color: Colors.white),
                        leading: IconButton(
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => _stopAndPop(savedProgress: _lastSavedProgress > 0),
                        ),
                      ),
                body: kIsWeb
                    ? buildWebIframe(_currentUrl ?? 'about:blank')
                    : isNativeWebView
                    ? InAppWebView(
                        initialUrlRequest: URLRequest(url: WebUri(_currentUrl ?? 'about:blank')),
                        initialSettings: InAppWebViewSettings(
                          javaScriptCanOpenWindowsAutomatically: false,
                          supportMultipleWindows: false, // Prevents popup windows
                          mediaPlaybackRequiresUserGesture: false,
                          allowsInlineMediaPlayback: true,
                          useShouldOverrideUrlLoading: true,
                          contentBlockers: _contentBlockers,
                          // Use a more appropriate User-Agent based on the platform to avoid being flagged or blocked
                          userAgent: kIsWeb ? null : (defaultTargetPlatform == TargetPlatform.iOS ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1' : 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36'),
                          
                        ),
                        onWebViewCreated: (controller) {
                          _webViewController = controller;
                          
                          // Setup handlers for Native UI communication
                          controller.addJavaScriptHandler(handlerName: 'FlutterControls', callback: (args) {
                            if (args.isNotEmpty) { // Check if args is not empty
                              if (args[0] == 'pop') _stopAndPop();
                              if (args[0] == 'hover') _resetControlsTimer();
                            }
                          });
                          
                          controller.addJavaScriptHandler(handlerName: 'FlutterProgress', callback: (args) {
                            if (args.length >= 3 && widget.media != null) {
                              final event = args[0] as String;
                              _lastPosition = (args[1] as num).toInt();
                              _lastRuntime = (args[2] as num).toInt();
                              _lastSavedProgress = _lastRuntime > 0 ? (_lastPosition / _lastRuntime).clamp(0.0, 1.0) : 0.0;

                              if (event == 'pause' || event == 'seeked' || event == 'ended') {
                                ProgressManager.saveProgress(
                                  media: widget.media!,
                                  progress: event == 'ended' ? 1.0 : _lastSavedProgress,
                                  season: widget.season,
                                  episode: widget.episode,
                                  position: _lastPosition,
                                  runtime: _lastRuntime,
                                );

                                if (event == 'ended') {
                                  _stopAndPop(savedProgress: true); // Pop with true if video ended
                                }
                              }
                            }
                          });
                          
                          // Handle server switching from the injected JS menu
                          controller.addJavaScriptHandler(handlerName: 'switchServer', callback: (args) {
                            if (args.isNotEmpty && widget.sources != null && args[0] is int) {
                              final index = args[0] as int;
                              if (index < widget.sources!.length) {
                                _switchStream(widget.sources![index]);
                              }
                            } 
                          });
                        },
                        shouldOverrideUrlLoading: (controller, navigationAction) async {
                          var uri = navigationAction.request.url!;
                          
                          // Only allow navigation to known trusted domains for streaming and API
                          // This prevents "hijack redirects" where a site sends you to an ad domain
                          final trustedDomains = ['videasy.net', 'cineby.sc', 'streamed.pk', 'youtube.com', 'google.com', 'gstatic.com', 'vidoza.net', 'upstream.to'];
                          final urlString = uri.toString().toLowerCase();
                          bool isTrusted = trustedDomains.any((domain) => uri.host.contains(domain)) || urlString.contains('embed') || urlString.contains('player');

                          if (!isTrusted) {
                            debugPrint("BLOCKING REDIRECT TO: ${uri.toString()}");
                            return NavigationActionPolicy.CANCEL;
                          }
                          
                          return NavigationActionPolicy.ALLOW;
                        },
                        onLoadStop: (controller, url) async {
                          _resetControlsTimer();
                          
                          // Hide overlay 1 second after page loads
                          Timer(const Duration(seconds: 1), () {
                            if (mounted) {
                              setState(() {
                                _isLoading = false;
                              });
                            }
                          });

                          final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
                          final sourcesJson = jsonEncode(widget.sources ?? []);
                          final backBtnTop = isIOS
                              ? 'calc(env(safe-area-inset-top, 0px) + 36px)'
                              : 'calc(env(safe-area-inset-top, 0px) + 4px)';
                          
                          // Inject helper JS for redirects, back buttons, and popups
                          await controller.evaluateJavascript(source: '''
                            // Block window.open completely
                            window.open = function() { return null; };

                            // Communication helper
                            function sendToFlutter(msg) {
                              if (Array.isArray(msg)) window.flutter_inappwebview.callHandler(msg[0], msg.slice(1)[0]);
                              else window.flutter_inappwebview.callHandler('FlutterControls', msg);
                            }

                            // Progress tracking logic
                            var lastPosition = 0;
                            var lastDuration = 0;

                            function sendProgress(event) {
                              var v = document.querySelector('video');
                              if (v && v.duration > 0) {
                                lastPosition = Math.floor(v.currentTime);
                                lastDuration = Math.floor(v.duration);
                                window.flutter_inappwebview.callHandler('FlutterProgress', event, lastPosition, lastDuration);
                              }
                            }

                            setInterval(function() {
                              var v = document.querySelector('video');
                              if (v) {
                                if (!v._monitored) {
                                  v._monitored = true;
                                  v.addEventListener('pause', function() { sendProgress('pause'); });
                                  v.addEventListener('seeked', function() { sendProgress('seeked'); });
                                  v.addEventListener('ended', function() { sendProgress('ended'); });
                                }
                                lastPosition = Math.floor(v.currentTime);
                                lastDuration = Math.floor(v.duration);
                                window.flutter_inappwebview.callHandler('FlutterProgress', 'tick', lastPosition, lastDuration);
                              }
                            }, 1000);

                            // Setup Native Back Button
                            var backBtn = document.createElement('div');
                            backBtn.className = 'native-control';
                            backBtn.id = 'native-back-button';
                            backBtn.style.position = 'fixed';
                            backBtn.style.top = '$backBtnTop';
                            backBtn.style.left = 'calc(env(safe-area-inset-left, 0px) + 4px)';
                            backBtn.style.width = '48px';
                            backBtn.style.height = '48px';
                            backBtn.style.borderRadius = '50%';
                            backBtn.style.backgroundColor = 'rgba(0, 0, 0, 0.4)';
                            backBtn.style.backdropFilter = 'blur(4px)';
                            backBtn.style.display = 'flex';
                            backBtn.style.alignItems = 'center';
                            backBtn.style.justifyContent = 'center';
                            // Use the maximum possible z-index to stay above player overlays
                            backBtn.style.zIndex = '2147483647';
                            backBtn.style.pointerEvents = 'auto';
                            backBtn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="white"><path d="M20 11H7.83l5.59-5.59L12 4l-8 8 8 8 1.41-1.41L7.83 13H20v-2z"/></svg>';
                            
                            backBtn.onclick = function(e) { e.preventDefault(); sendToFlutter('pop'); };
                            document.body.appendChild(backBtn);

                            // Setup Native PiP Button
                            var pipBtn = document.createElement('div');
                            pipBtn.className = 'native-control';
                            pipBtn.id = 'native-pip-button';
                            pipBtn.style.position = 'fixed';
                            pipBtn.style.top = '$backBtnTop';
                            pipBtn.style.right = 'calc(env(safe-area-inset-right, 0px) + 4px)';
                            pipBtn.style.width = '48px';
                            pipBtn.style.height = '48px';
                            pipBtn.style.borderRadius = '50%';
                            pipBtn.style.backgroundColor = 'rgba(0, 0, 0, 0.4)';
                            pipBtn.style.backdropFilter = 'blur(4px)';
                            pipBtn.style.display = 'flex';
                            pipBtn.style.alignItems = 'center';
                            pipBtn.style.justifyContent = 'center';
                            pipBtn.style.zIndex = '2147483647';
                            pipBtn.style.pointerEvents = 'auto';
                            pipBtn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="white"><path d="M19 11h-8v6h8v-6zm4 8V4.98C23 3.88 22.1 3 21 3H3c-1.1 0-2 .88-2 1.98V19c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2zm-2 .02H3V4.97h18v14.05z"/></svg>';
                            
                            pipBtn.onclick = function(e) {
                              var v = document.querySelector('video');
                              if (v) {
                                if (v.webkitSetPresentationMode) v.webkitSetPresentationMode("picture-in-picture");
                                else if (v.requestPictureInPicture) v.requestPictureInPicture();
                              }
                            };
                            document.body.appendChild(pipBtn);

                            // Setup Native Server Switcher
                            var sources = $sourcesJson;
                            if (sources && sources.length > 1) {
                              var serverBtn = document.createElement('div');
                              serverBtn.className = 'native-control-btn';
                              serverBtn.style.position = 'fixed';
                              serverBtn.style.top = '$backBtnTop';
                              serverBtn.style.right = 'calc(env(safe-area-inset-right, 0px) + 56px)';
                              serverBtn.style.width = '48px';
                              serverBtn.style.height = '48px';
                              serverBtn.style.borderRadius = '50%';
                              serverBtn.style.backgroundColor = 'rgba(0, 0, 0, 0.4)';
                              serverBtn.style.backdropFilter = 'blur(4px)';
                              serverBtn.style.display = 'flex';
                              serverBtn.style.alignItems = 'center';
                              serverBtn.style.justifyContent = 'center';
                              serverBtn.style.zIndex = '2147483647';
                              serverBtn.style.pointerEvents = 'auto';
                              serverBtn.style.transition = 'opacity 0.3s';
                              serverBtn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="white"><path d="M2 20h20v-4H2v4zm2-3h2v2H4v-2zM2 4v4h20V4H2zm4 3H4V5h2v2zm-4 7h20v-4H2v4zm2-3h2v2H4v-2z"/></svg>';
                              
                              var serverMenu = document.createElement('div');
                              serverMenu.className = 'native-control-menu';
                              serverMenu.style.position = 'fixed';
                              serverMenu.style.top = 'calc($backBtnTop + 56px)';
                              serverMenu.style.right = 'calc(env(safe-area-inset-right, 0px) + 56px)';
                              serverMenu.style.backgroundColor = 'rgba(30, 31, 36, 0.95)';
                              serverMenu.style.borderRadius = '12px';
                              serverMenu.style.padding = '8px 0';
                              serverMenu.style.zIndex = '2147483647';
                              serverMenu.style.display = 'none';
                              serverMenu.style.flexDirection = 'column';
                              serverMenu.style.border = '1px solid rgba(255,255,255,0.1)';
                              serverMenu.style.minWidth = '140px';

                              sources.forEach(function(s, i) {
                                var item = document.createElement('div');
                                item.style.padding = '12px 20px';
                                item.style.color = 'white';
                                item.style.fontSize = '14px';
                                item.style.fontFamily = 'sans-serif';
                                item.innerText = 'Server ' + (i + 1) + ' (' + s.source + ')';
                                item.onclick = function() {
                                  window.flutter_inappwebview.callHandler('switchServer', i);
                                  serverMenu.style.display = 'none';
                                };
                                serverMenu.appendChild(item);
                              });

                              serverBtn.onclick = function(e) {
                                e.stopPropagation();
                                serverMenu.style.display = serverMenu.style.display === 'none' ? 'flex' : 'none';
                              };
                              
                              document.body.appendChild(serverBtn);
                              document.body.appendChild(serverMenu);
                              
                              document.addEventListener('click', function() { 
                                if(serverMenu) serverMenu.style.display = 'none'; 
                              });
                            }

                            // Auto-hide controls logic
                            var hideTimeout;
                            function resetUI() {
                              sendToFlutter('hover');
                              backBtn.style.opacity = '1';
                              pipBtn.style.opacity = '1';
                              if (typeof serverBtn !== 'undefined') serverBtn.style.opacity = '1';
                              clearTimeout(hideTimeout);
                              hideTimeout = setTimeout(() => {
                                backBtn.style.opacity = '0';
                                pipBtn.style.opacity = '0';
                                if (typeof serverBtn !== 'undefined') {
                                  serverBtn.style.opacity = '0';
                                  serverMenu.style.display = 'none';
                                }
                              }, 3000);
                            }
                            // Use capture:true to ensure we catch the tap before the player stops propagation
                            window.addEventListener('mousemove', resetUI, true);
                            window.addEventListener('touchstart', resetUI, true);
                            resetUI();

                            // Anti-Ad: Remove any elements with high z-index that cover too much screen
                            setInterval(function() {
                              document.querySelectorAll('div').forEach(function(div) {
                                var z = parseInt(window.getComputedStyle(div).zIndex);
                                // Prevent removing elements that look like video player controls or overlays
                                if (z > 1000 && !div.className.includes('native-') && !div.id.includes('native-') && !div.querySelector('video') && !div.className.toLowerCase().includes('vjs') && !div.className.toLowerCase().includes('play') && !div.id.toLowerCase().includes('play')) {
                                  div.remove();
                                }
                              });
                            }, 2000);

                            // Autoplay and Unmute logic
                            var playInterval = setInterval(function() {
                                var v = document.querySelector('video');
                                
                                if (v && !v.paused) {
                                    // Video is playing! Try to unmute and then kill the loop.
                                    setTimeout(function() {
                                      if (v) { v.muted = false; v.volume = 1.0; }
                                    }, 500);
                                    clearInterval(playInterval);
                                    return;
                                }

                                if (v && v.paused) {
                                    v.muted = true;
                                    v.play().catch(function(e) {});
                                }

                                // Aggressively click common play/unmute elements for cineby/videasy
                                var unmuteButtons = document.querySelectorAll('.vjs-mute-control.vjs-vol-0, .jw-icon-volume-off, .volume-unmute, [aria-label="Unmute"], .ytp-unmute');
                                unmuteButtons.forEach(function(btn) { btn.click(); });

                                var selectors = [
                                  '.vjs-big-play-button', '.play-button', '[aria-label="Play"]', 
                                  '.jw-display-icon-container', '.ytp-large-play-button', '.play-icon',
                                  '.vjs-play-control.vjs-paused', '.vjs-poster', '#player_html5_api'
                                ];
                                for (var i = 0; i < selectors.length; i++) {
                                  var btn = document.querySelector(selectors[i]);
                                  if (btn && btn.offsetParent !== null) { // Only click if visible
                                    btn.click();
                                  }
                                }

                                // Specific fix for Cineby/Videasy style overlays
                                // If video isn't playing, click the center of the screen to trigger hidden play overlays
                                if (!v || v.paused) {
                                    var bigCenterPlay = document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2);
                                    if (bigCenterPlay && bigCenterPlay !== document.body && bigCenterPlay.tagName !== 'VIDEO') {
                                        bigCenterPlay.click();
                                    }
                                }
                            }, 1000);

                            // Clean up interval after some time
                            setTimeout(function() { clearInterval(playInterval); }, 20000);
                          ''');
                        },
                      )
                    : const Center(
                        child: Text(
                          'Webview only supported on Windows, Android, and iOS in this configuration.',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
              ),
            ),
          ),
          // Loading overlay for stream switching
          if (_isChangingStream)
            Container(
              color: Colors.black87,
              child: const Center(
                child: Material(
                  color: Colors.transparent,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(color: Colors.white70, strokeWidth: 2),
                      ),
                      SizedBox(height: 12),
                      Text(
                        'Switching source...',
                        style: TextStyle(color: Colors.white70, fontSize: 12, decoration: TextDecoration.none),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}