import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DownloadStatus { none, requesting, downloading, done, failed }

class SimpleLock {
  Completer<void>? _completer;

  Future<void> acquire() async {
    while (_completer != null) {
      await _completer!.future;
    }
    _completer = Completer<void>();
  }

  void release() {
    final c = _completer;
    _completer = null;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
  }

  Future<T> synchronized<T>(FutureOr<T> Function() computation) async {
    await acquire();
    try {
      return await computation();
    } finally {
      release();
    }
  }
}

class DownloadTask extends ChangeNotifier {
  final String mediaId;
  final String title;
  final String? posterPath;
  final String mediaType;
  DownloadStatus _status = DownloadStatus.none;
  DownloadStatus get status => _status;
  double _progress = 0.0;
  double get progress => _progress;

  DownloadTask({required this.mediaId, required this.title, this.posterPath, required this.mediaType});

  void update({DownloadStatus? newStatus, double? newProgress}) {
    bool changed = false;
    if (newStatus != null && _status != newStatus) {
      _status = newStatus;
      changed = true;
    }
    if (newProgress != null && _progress != newProgress) {
      _progress = newProgress;
      changed = true;
    }
    if (changed) {
      notifyListeners();
    }
  }
}

class CachedDownloadItem {
  final String mediaId;
  final String title;
  final String? posterPath;
  final String mediaType;
  final String filePath;
  final DateTime downloadedAt;

  CachedDownloadItem({
    required this.mediaId,
    required this.title,
    this.posterPath,
    required this.mediaType,
    required this.filePath,
    required this.downloadedAt,
  });

  factory CachedDownloadItem.fromJson(Map<String, dynamic> json) {
    return CachedDownloadItem(
      mediaId: json['mediaId'] as String,
      title: json['title'] as String,
      posterPath: json['posterPath'] as String?,
      mediaType: json['mediaType'] as String,
      filePath: json['filePath'] as String,
      downloadedAt: DateTime.tryParse(json['downloadedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'mediaId': mediaId,
    'title': title,
    'posterPath': posterPath,
    'mediaType': mediaType,
    'filePath': filePath,
    'downloadedAt': downloadedAt.toIso8601String(),
  };
}

class DownloadManager {
  static final DownloadManager _instance = DownloadManager._internal();
  factory DownloadManager() => _instance;
  DownloadManager._internal();

  final Map<String, DownloadTask> _tasks = {};
  final Map<String, List<http.Client>> _clients = {};
  final Map<String, bool> _cancellations = {};
  final SimpleLock _lock = SimpleLock();

  List<DownloadTask> get allTasks => _tasks.values.toList();
  final StreamController<String> _messageController = StreamController.broadcast();
  Stream<String> get messages => _messageController.stream;

  final ValueNotifier<DownloadTask?> _activeTaskNotifier = ValueNotifier(null);
  ValueNotifier<DownloadTask?> get activeTaskNotifier => _activeTaskNotifier;

  static const String _browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  DownloadTask? getTask(String mediaId) => _tasks[mediaId];

  void cancelDownload(String mediaId) {
    if (!_cancellations.containsKey(mediaId) || _cancellations[mediaId] == true) return;
    _cancellations[mediaId] = true;

    final clients = _clients[mediaId];
    if (clients != null) {
      for (var client in clients) {
        client.close();
      }
      clients.clear();
    }

    final task = _tasks[mediaId];
    if (task != null) {
      task.update(newStatus: DownloadStatus.failed);
      _messageController.add('ERROR:Download cancelled.');
      _scheduleTaskCleanup(mediaId);
    }
  }

  Future<void> removeDownloadFromCache(String mediaId) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedDownloads = prefs.getStringList('downloadedItemsCache') ?? [];
    cachedDownloads.removeWhere((item) {
      try {
        final decoded = json.decode(item) as Map<String, dynamic>;
        return decoded['mediaId'] == mediaId;
      } catch (e) {
        return false;
      }
    });
    await prefs.setStringList('downloadedItemsCache', cachedDownloads);
  }

  Future<void> startDownload({
    required String mediaId,
    required String title,
    required String year,
    required String resolution,
    String? posterPath,
    required String mediaType,
  }) async {
    if (_tasks.containsKey(mediaId) &&
        (_tasks[mediaId]!.status == DownloadStatus.downloading ||
            _tasks[mediaId]!.status == DownloadStatus.requesting)) {
      return;
    }

    final task = DownloadTask(mediaId: mediaId, title: title, posterPath: posterPath, mediaType: mediaType);
    _tasks[mediaId] = task;
    _cancellations[mediaId] = false;
    _activeTaskNotifier.value = task;

    task.update(newStatus: DownloadStatus.requesting, newProgress: 0.0);

    try {
      final url = Uri.parse('http://192.3.222.59:8088/query');
      final headers = {
        'Content-Type': 'application/json',
        'Authorization': 'Basic ${base64Encode(utf8.encode('cinestream:privateapi'))}',
        'User-Agent': _browserUserAgent,
        'Referer': url.origin,
      };
      final body = json.encode({'text': '$title $year'.trim(), 'resolution': resolution});

      final response = await http.post(url, headers: headers, body: body);

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        var downloadUrl = responseData['url'] as String?;

        if (downloadUrl != null && downloadUrl.isNotEmpty) {
          if (downloadUrl.startsWith('//')) {
            downloadUrl = 'https:$downloadUrl';
          }
          await _processDownload(mediaId, title, downloadUrl);
        } else {
          throw Exception('API returned an empty URL.');
        }
      } else {
        throw Exception('API request failed with status: ${response.statusCode}\nBody: ${response.body}');
      }
    } catch (e) {
      task.update(newStatus: DownloadStatus.failed);
      _messageController.add('ERROR:Failed to initiate download: $e');
      _scheduleTaskCleanup(mediaId);
    }
  }

  Future<void> _addDownloadToCache(DownloadTask task, String filePath) async {
    final prefs = await SharedPreferences.getInstance();
    final cachedDownloads = prefs.getStringList('downloadedItemsCache') ?? [];

    final newItem = CachedDownloadItem(
      mediaId: task.mediaId,
      title: task.title,
      posterPath: task.posterPath,
      mediaType: task.mediaType,
      filePath: filePath,
      downloadedAt: DateTime.now(),
    );

    cachedDownloads.removeWhere((item) {
      try {
        return (json.decode(item) as Map<String, dynamic>)['mediaId'] == task.mediaId;
      } catch (e) { return false; }
    });

    cachedDownloads.add(json.encode(newItem.toJson()));
    await prefs.setStringList('downloadedItemsCache', cachedDownloads);
  }

  Future<void> _processDownload(String mediaId, String title, String downloadUrl) async {
    final task = _tasks[mediaId]!;

    final docsDir = await getApplicationDocumentsDirectory();
    final finalDir = Directory('${docsDir.path}/CineStream/Movies');
    await finalDir.create(recursive: true);
    final finalFileName = '$mediaId+$title.mp4'.replaceAll(RegExp(r'[^\w\s\.-]+'), '').replaceAll(' ', '_');
    final finalPath = '${finalDir.path}/$finalFileName';

    try {
      task.update(newStatus: DownloadStatus.downloading);
      await _downloadFileInParts(mediaId, downloadUrl, finalPath);

      if (_cancellations[mediaId] == true) throw http.ClientException("Download cancelled by user.");

      task.update(newStatus: DownloadStatus.done, newProgress: 1.0);
      _messageController.add('SUCCESS:Download complete! Saved to local files.');
      await _addDownloadToCache(task, finalPath);
    } catch (e) {
      if (_cancellations[mediaId] != true) {
        task.update(newStatus: DownloadStatus.failed);
        _messageController.add('ERROR:Download failed: ${e.toString().split(':').last.trim()}');
      }
    } finally {
      _clients.remove(mediaId);
      _cancellations.remove(mediaId);
      _scheduleTaskCleanup(mediaId);

    }
  }

  Future<void> _downloadFileInParts(String mediaId, String url, String savePath) async {
    _clients[mediaId] = [];
    final headClient = http.Client();
    _clients[mediaId]!.add(headClient);

    final headRequest = http.Request('HEAD', Uri.parse(url))..headers['User-Agent'] = _browserUserAgent;
    final headResponse = await headClient.send(headRequest);

    if (headResponse.statusCode != 200) throw Exception('Server responded with ${headResponse.statusCode}');
    final totalSize = headResponse.contentLength ?? 0;
    if (totalSize <= 0) throw Exception('Could not get file size.');

    final supportsRange = headResponse.headers['accept-ranges'] == 'bytes';
    if (!supportsRange) throw Exception('Server does not support parallel downloads.');

    // Dynamically adjust part count based on network type.
    // Cellular networks benefit from more connections to overcome latency.
    // Wi-Fi can be faster with fewer connections, as consumer routers can struggle with too many parallel streams.
    int partCount;
    final connectivityResult = await (Connectivity().checkConnectivity());
    if (connectivityResult.contains(ConnectivityResult.wifi)) {
      partCount = 4; // Use fewer connections on Wi-Fi to avoid overwhelming the router.
    } else if (connectivityResult.contains(ConnectivityResult.mobile)) {
      partCount = 8; // Use more connections on Cellular to maximize throughput.
    } else {
      partCount = 6; // A safe default for Ethernet or unknown networks.
    }

    final partSize = (totalSize / partCount).ceil();
    final parts = List.generate(partCount, (i) => i);
    final task = _tasks[mediaId]!;
    final tempDir = await getTemporaryDirectory();
    final List<String> partPaths = [];
    int totalDownloaded = 0;

    try {
      Future<void> downloadPart(int partIndex) async {
        final partPath = '${tempDir.path}/$mediaId-part$partIndex.tmp';
        partPaths.add(partPath);
        final partFile = File(partPath);

        const maxRetries = 5;
        int retryCount = 0;
        int bytesDownloadedForPart = 0;
        final partStartByte = partIndex * partSize;
        final partEndByte = min(partStartByte + partSize - 1, totalSize - 1);
        final expectedPartSize = partEndByte - partStartByte + 1;

        if (expectedPartSize <= 0) return;

        while (bytesDownloadedForPart < expectedPartSize) {
          if (_cancellations[mediaId] == true) return;

          final currentRequestStartByte = partStartByte + bytesDownloadedForPart;
          final rangeHeader = 'bytes=$currentRequestStartByte-$partEndByte';
          final partClient = http.Client();
          _clients[mediaId]!.add(partClient);
          final partFileSink = partFile.openWrite(mode: bytesDownloadedForPart > 0 ? FileMode.append : FileMode.write);

          try {
            final request = http.Request('GET', Uri.parse(url))..headers['Range'] = rangeHeader..headers['User-Agent'] = _browserUserAgent;
            final response = await partClient.send(request).timeout(const Duration(seconds: 20));

            if (response.statusCode != 206) throw http.ClientException('Server responded with ${response.statusCode} for range $rangeHeader', request.url);

            await for (final chunk in response.stream) {
              if (_cancellations[mediaId] == true) {
                partClient.close();
                return;
              }
              partFileSink.add(chunk);
              bytesDownloadedForPart += chunk.length;
              await _lock.synchronized(() async {
                totalDownloaded += chunk.length;
                task.update(newProgress: (totalDownloaded / totalSize).clamp(0.0, 1.0));
              });
            }
          } catch (e) {
            if (e is SocketException || e is http.ClientException || e is TimeoutException || e is HandshakeException) {
              retryCount++;
              if (retryCount > maxRetries) throw Exception('Part $partIndex failed after $maxRetries retries: $e');
              final delay = pow(2, retryCount).toInt();
              await Future.delayed(Duration(seconds: delay));
            } else {
              rethrow;
            }
          } finally {
            await partFileSink.close();
            partClient.close();
          }
        }
      }

      await Future.wait(parts.map((i) => downloadPart(i)));

      if (_cancellations[mediaId] == true) return;

      // Combine the downloaded parts into the final file.
      final finalFile = File(savePath);
      // Ensure the file is empty before starting the append operations.
      if (await finalFile.exists()) {
        await finalFile.delete();
      }

      for (int i = 0; i < partCount; i++) {
        if (_cancellations[mediaId] == true) return;
        final partPath = '${tempDir.path}/$mediaId-part$i.tmp';
        final partFile = File(partPath);
        if (await partFile.exists()) {
          final bytes = await partFile.readAsBytes();
          // Using FileMode.append is a very safe way to concatenate files,
          // as it opens, writes, and closes the file handle for each operation.
          await finalFile.writeAsBytes(bytes, mode: FileMode.append);
          await partFile.delete();
        } else {
          throw Exception('Download part $i is missing.');
        }
      }
    } finally {
      // Clean up any remaining temp part files in case of an early error.
      for (final path in partPaths) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
  }

  void _scheduleTaskCleanup(String mediaId) {
    Timer(const Duration(seconds: 5), () {
      final task = _tasks[mediaId];
      if (task != null && (task.status == DownloadStatus.done || task.status == DownloadStatus.failed)) {
        task.update(newStatus: DownloadStatus.none, newProgress: 0.0);
        if (_activeTaskNotifier.value == task) {
          _activeTaskNotifier.value = null;
        }
      }
    });
  }

  void dispose() {
    _messageController.close();
  }
}