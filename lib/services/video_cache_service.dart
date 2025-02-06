import 'dart:io';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';

class VideoCacheService {
  static final VideoCacheService _instance = VideoCacheService._internal();
  factory VideoCacheService() => _instance;

  bool _isInitialized = false;
  final Completer<void> _initCompleter = Completer<void>();

  VideoCacheService._internal() {
    _initialize();
  }

  Future<void> _initialize() async {
    if (_isInitialized) return;
    try {
      debugPrint('VideoCacheService: Starting initialization');
      await _loadUrlMapping();
      await loadExistingCache();
      _isInitialized = true;
      _initCompleter.complete();
      debugPrint('VideoCacheService: Initialization completed successfully');
    } catch (e, stack) {
      debugPrint('VideoCacheService: Error during initialization: $e');
      debugPrint('Stack trace: $stack');
      _initCompleter.completeError(e);
    }
  }

  Future<void> ensureInitialized() async {
    if (!_isInitialized) {
      await _initCompleter.future;
    }
  }

  // Increased maximum cache size to 5GB
  static const int _maxCacheSize = 5 * 1024 * 1024 * 1024;

  final Map<String, String> _cachedVideos = {};
  final Map<String, DateTime> _lastAccessed = {};
  final Map<String, int> _downloadedBytes = {};
  final Map<String, int> _totalBytes = {};
  final Map<String, Completer<String>> _downloadCompleters = {};

  // Generate a consistent filename for a URL
  String _getFileNameForUrl(String url) {
    final bytes = utf8.encode(url);
    final hash = sha256.convert(bytes);
    final extension = url.split('.').last.split('?').first;
    return '${hash.toString().substring(0, 16)}.$extension';
  }

  Future<String> getCacheDirectory() async {
    if (Platform.isAndroid) {
      // On Android, use external storage for persistence
      final List<Directory>? extDirs =
          await path_provider.getExternalStorageDirectories();
      if (extDirs != null && extDirs.isNotEmpty) {
        final Directory cacheDir =
            Directory('${extDirs.first.path}/flipsy_video_cache');
        if (!await cacheDir.exists()) {
          await cacheDir.create(recursive: true);
        }
        return cacheDir.path;
      }
    }

    // Fallback to application documents directory
    final Directory appDir =
        await path_provider.getApplicationDocumentsDirectory();
    final Directory cacheDir = Directory('${appDir.path}/video_cache');
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir.path;
  }

  // Load existing cached videos on initialization
  Future<void> loadExistingCache() async {
    try {
      final cacheDir = await getCacheDirectory();
      final mappingFile = File('$cacheDir/url_mapping.json');

      if (await mappingFile.exists()) {
        final String content = await mappingFile.readAsString();
        final Map<String, dynamic> mapping = jsonDecode(content);

        // Verify each cached file exists
        for (var entry in mapping.entries) {
          final data = entry.value as Map<String, dynamic>;
          final String filePath = data['path'] as String;

          if (await File(filePath).exists()) {
            _cachedVideos[entry.key] = filePath;
            _lastAccessed[entry.key] = DateTime.parse(data['lastAccessed']);
          }
        }
        debugPrint('Loaded ${_cachedVideos.length} videos from existing cache');
      }
    } catch (e) {
      debugPrint('Error loading existing cache: $e');
    }
  }

  Future<String?> getCachedVideoPath(String videoUrl) async {
    try {
      await ensureInitialized();
      debugPrint('VideoCacheService: Getting cached path for: $videoUrl');

      if (_cachedVideos.containsKey(videoUrl)) {
        _lastAccessed[videoUrl] = DateTime.now();
        final cachePath = _cachedVideos[videoUrl]!;

        if (await File(cachePath).exists()) {
          debugPrint('VideoCacheService: Cache hit: $videoUrl -> $cachePath');
          return cachePath;
        } else {
          debugPrint(
              'VideoCacheService: Cached file not found, removing from cache: $cachePath');
          _cachedVideos.remove(videoUrl);
          _lastAccessed.remove(videoUrl);
        }
      }

      if (_downloadCompleters.containsKey(videoUrl)) {
        debugPrint(
            'VideoCacheService: Waiting for ongoing download: $videoUrl');
        return _downloadCompleters[videoUrl]!.future;
      }

      debugPrint('VideoCacheService: Starting new download for: $videoUrl');
      final completer = Completer<String>();
      _downloadCompleters[videoUrl] = completer;

      _downloadAndCacheVideo(videoUrl).then((cachePath) {
        if (cachePath != null) {
          debugPrint(
              'VideoCacheService: Download completed successfully: $cachePath');
          completer.complete(cachePath);
        } else {
          debugPrint('VideoCacheService: Download failed');
          completer.completeError('Failed to download video');
        }
        _downloadCompleters.remove(videoUrl);
      }).catchError((error, stack) {
        debugPrint('VideoCacheService: Download error: $error');
        debugPrint('Stack trace: $stack');
        completer.completeError(error);
        _downloadCompleters.remove(videoUrl);
      });

      return completer.future;
    } catch (e, stack) {
      debugPrint('VideoCacheService: Error in getCachedVideoPath: $e');
      debugPrint('Stack trace: $stack');
      rethrow;
    }
  }

  Future<String?> _downloadAndCacheVideo(String url) async {
    debugPrint('VideoCacheService: Starting download: $url');
    final fileName = _getFileNameForUrl(url);
    final cacheDir = await getCacheDirectory();
    final filePath = '$cacheDir/$fileName';
    final file = File(filePath);

    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      _totalBytes[url] = response.contentLength ?? 0;
      _downloadedBytes[url] = 0;

      final totalSize = (_totalBytes[url] ?? 0) ~/ 1024;
      debugPrint('VideoCacheService: Total size to download: ${totalSize}KB');

      final sink = file.openWrite();
      await response.stream.listen(
        (chunk) {
          sink.add(chunk);
          _downloadedBytes[url] = (_downloadedBytes[url] ?? 0) + chunk.length;
          final downloaded = (_downloadedBytes[url] ?? 0);
          final total = (_totalBytes[url] ?? 1);
          final progress = (downloaded / total) * 100;
          final downloadedKB = downloaded ~/ 1024;
          final totalKB = total ~/ 1024;
          debugPrint(
              'VideoCacheService: Download progress: ${progress.toStringAsFixed(1)}% - ${downloadedKB}KB/${totalKB}KB');
        },
        onDone: () async {
          await sink.flush();
          await sink.close();
        },
        onError: (error) {
          debugPrint('VideoCacheService: Download error: $error');
          sink.close();
          file.deleteSync();
          throw error;
        },
        cancelOnError: true,
      ).asFuture();

      _cachedVideos[url] = filePath;
      _lastAccessed[url] = DateTime.now();

      debugPrint('VideoCacheService: Download completed: $url');
      return filePath;
    } catch (e) {
      debugPrint('VideoCacheService: Download failed: $e');
      if (await file.exists()) {
        await file.delete();
      }
      return null;
    } finally {
      _downloadedBytes.remove(url);
      _totalBytes.remove(url);
    }
  }

  Future<void> _maintainCacheSize() async {
    try {
      final cacheDir = await getCacheDirectory();
      final Directory dir = Directory(cacheDir);

      // Calculate current cache size
      int currentSize = 0;
      final List<FileSystemEntity> files = await dir.list().toList();
      for (var file in files) {
        if (file is File) {
          currentSize += await file.length();
        }
      }

      debugPrint('Current cache size: ${currentSize ~/ 1024 / 1024}MB');

      // If we're over 90% of the limit, remove oldest accessed files until we're under 70%
      if (currentSize > (_maxCacheSize * 0.9)) {
        final List<MapEntry<String, DateTime>> sortedEntries =
            _lastAccessed.entries.toList()
              ..sort((a, b) => a.value.compareTo(b.value));

        final targetSize = (_maxCacheSize * 0.7).toInt();
        debugPrint(
            'Cleaning cache to reach target size: ${targetSize ~/ 1024 / 1024}MB');

        for (var entry in sortedEntries) {
          if (currentSize <= targetSize) break;

          final String videoUrl = entry.key;
          final String? cachePath = _cachedVideos[videoUrl];

          if (cachePath != null) {
            final file = File(cachePath);
            if (await file.exists()) {
              final int fileSize = await file.length();
              await file.delete();
              currentSize -= fileSize;

              _cachedVideos.remove(videoUrl);
              _lastAccessed.remove(videoUrl);

              debugPrint(
                  'Removed from cache: $videoUrl (${fileSize ~/ 1024 / 1024}MB)');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error maintaining cache size: $e');
    }
  }

  Future<void> _persistUrlMapping() async {
    try {
      final cacheDir = await getCacheDirectory();
      final mappingFile = File('$cacheDir/url_mapping.json');
      final Map<String, dynamic> mapping = {};
      for (var entry in _cachedVideos.entries) {
        mapping[entry.key] = {
          'path': entry.value,
          'lastAccessed': _lastAccessed[entry.key]?.toIso8601String(),
        };
      }
      await mappingFile.writeAsString(jsonEncode(mapping));
    } catch (e) {
      debugPrint('Error persisting URL mapping: $e');
    }
  }

  Future<void> _loadUrlMapping() async {
    try {
      final cacheDir = await getCacheDirectory();
      final mappingFile = File('$cacheDir/url_mapping.json');
      if (await mappingFile.exists()) {
        final String content = await mappingFile.readAsString();
        final Map<String, dynamic> mapping = jsonDecode(content);
        for (var entry in mapping.entries) {
          final data = entry.value as Map<String, dynamic>;
          _cachedVideos[entry.key] = data['path'];
          _lastAccessed[entry.key] = DateTime.parse(data['lastAccessed']);
        }
      }
    } catch (e) {
      debugPrint('Error loading URL mapping: $e');
    }
  }

  @override
  Future<void> clearCache() async {
    try {
      final cacheDir = await getCacheDirectory();
      final Directory dir = Directory(cacheDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _cachedVideos.clear();
      _lastAccessed.clear();
      _downloadCompleters.clear();
      await _persistUrlMapping(); // Update the mapping file
      debugPrint('Cache cleared successfully');
    } catch (e) {
      debugPrint('Error clearing cache: $e');
    }
  }

  // Preload a list of videos in the background
  Future<void> preloadVideos(List<String> videoUrls) async {
    for (final url in videoUrls) {
      if (!_cachedVideos.containsKey(url) &&
          !_downloadCompleters.containsKey(url)) {
        debugPrint('Preloading video: $url');
        getCachedVideoPath(url); // Don't await, let it download in background
      }
    }
  }

  Map<String, int> getBandwidthStats() {
    return {
      'activeDownloads': _downloadedBytes.length,
      'totalDownloading': _totalBytes.values.fold(0, (sum, size) => sum + size),
      'downloadedSoFar':
          _downloadedBytes.values.fold(0, (sum, size) => sum + size),
    };
  }
}
