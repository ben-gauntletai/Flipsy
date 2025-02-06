import 'dart:io';
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as p;

class VideoCacheService {
  static final VideoCacheService _instance = VideoCacheService._internal();
  factory VideoCacheService() => _instance;

  bool _isInitialized = false;
  final Completer<void> _initCompleter = Completer<void>();
  static const int _maxConcurrentDownloads = 3;
  final Set<String> _activeDownloads = {};
  final Queue<String> _downloadQueue = Queue<String>();
  final Map<String, String> _cachedVideos = {};
  final Map<String, DateTime> _lastAccessed = {};
  final Map<String, int> _downloadedBytes = {};
  final Map<String, int> _totalBytes = {};
  static const int _maxCacheSize = 5 * 1024 * 1024 * 1024;

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

      // Start periodic cache maintenance
      Timer.periodic(const Duration(minutes: 30), (_) => _maintainCacheSize());
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

  // Generate a consistent filename for a URL
  String _getFileNameForUrl(String url) {
    final bytes = utf8.encode(url);
    final hash = sha256.convert(bytes);
    final extension = url.split('.').last.split('?').first;
    return '${hash.toString().substring(0, 16)}.$extension';
  }

  Future<String> getCacheDirectory() async {
    String cachePath;
    if (Platform.isAndroid) {
      // On Android, use external storage for persistence
      final List<Directory>? extDirs =
          await path_provider.getExternalStorageDirectories();
      if (extDirs != null && extDirs.isNotEmpty) {
        cachePath = '${extDirs.first.path}/flipsy_video_cache';
      } else {
        // Fallback to application documents directory
        final Directory appDir =
            await path_provider.getApplicationDocumentsDirectory();
        cachePath = '${appDir.path}/video_cache';
      }
    } else {
      // For other platforms, use application documents directory
      final Directory appDir =
          await path_provider.getApplicationDocumentsDirectory();
      cachePath = '${appDir.path}/video_cache';
    }

    debugPrint('VideoCacheService: Using cache directory: $cachePath');
    final cacheDir = Directory(cachePath);
    if (!await cacheDir.exists()) {
      debugPrint('VideoCacheService: Creating cache directory');
      await cacheDir.create(recursive: true);
    }
    return cachePath;
  }

  // Load existing cached videos on initialization
  Future<void> loadExistingCache() async {
    try {
      final cacheDir = await getCacheDirectory();
      final mappingFile = File('$cacheDir/url_mapping.json');
      debugPrint('VideoCacheService: Loading cache from: ${mappingFile.path}');

      if (await mappingFile.exists()) {
        final String content = await mappingFile.readAsString();
        debugPrint('VideoCacheService: Read mapping file content: $content');
        final Map<String, dynamic> mapping = jsonDecode(content);

        // Verify each cached file exists
        for (var entry in mapping.entries) {
          final data = entry.value as Map<String, dynamic>;
          final String filePath = data['path'] as String;
          debugPrint('VideoCacheService: Checking cached file: $filePath');

          final file = File(filePath);
          if (await file.exists()) {
            final fileSize = await file.length();
            debugPrint(
                'VideoCacheService: Found cached file: $filePath (${fileSize ~/ 1024}KB)');
            _cachedVideos[entry.key] = filePath;
            _lastAccessed[entry.key] = DateTime.parse(data['lastAccessed']);
          } else {
            debugPrint('VideoCacheService: Cached file not found: $filePath');
          }
        }
        debugPrint(
            'VideoCacheService: Loaded ${_cachedVideos.length} videos from existing cache');
      } else {
        debugPrint('VideoCacheService: No existing cache mapping file found');
      }
    } catch (e, stack) {
      debugPrint('VideoCacheService: Error loading existing cache: $e');
      debugPrint('Stack trace: $stack');
    }
  }

  Future<String?> getCachedVideoPath(String videoUrl) async {
    try {
      print('\n=== VideoCacheService: getCachedVideoPath ===');
      print('Input URL: $videoUrl');

      await ensureInitialized();
      print('Cache Status:');
      print('- Cached videos: ${_cachedVideos.length}');
      print('- Active downloads: ${_activeDownloads.length}');
      print('- Download queue: ${_downloadQueue.length}');

      // If video is already cached, return the cached path
      if (_cachedVideos.containsKey(videoUrl)) {
        _lastAccessed[videoUrl] = DateTime.now();
        final cachePath = _cachedVideos[videoUrl]!;
        print('Found cache entry: $cachePath');

        final file = File(cachePath);
        if (await file.exists()) {
          final fileSize = await file.length();
          print('Cache hit details:');
          print('- File exists: true');
          print('- File size: ${fileSize ~/ 1024}KB');
          print('- Last accessed: ${_lastAccessed[videoUrl]}');
          await _persistUrlMapping();
          return cachePath;
        } else {
          print('Cache miss reason: File does not exist');
          print('Removing invalid cache entry');
          _cachedVideos.remove(videoUrl);
          _lastAccessed.remove(videoUrl);
          await _persistUrlMapping();
        }
      } else {
        print('Cache miss reason: URL not in cache map');
      }

      // Start caching in the background if not already in progress
      if (!_activeDownloads.contains(videoUrl)) {
        print('Starting background caching');
        unawaited(_startBackgroundCaching(videoUrl));
      } else {
        print('Background caching already in progress');
      }

      print('Returning null while caching');
      return null;
    } catch (e, stack) {
      print('ERROR in getCachedVideoPath:');
      print('- Error: $e');
      print('- Stack: $stack');
      return null;
    } finally {
      print('=== End getCachedVideoPath ===\n');
    }
  }

  Future<void> _startBackgroundCaching(String videoUrl) async {
    print('\n=== VideoCacheService: _startBackgroundCaching ===');
    print('URL to cache: $videoUrl');

    if (_activeDownloads.contains(videoUrl)) {
      print('Download already in progress, skipping');
      return;
    }

    try {
      _activeDownloads.add(videoUrl);
      print('Added to active downloads (total: ${_activeDownloads.length})');

      final cacheDir = await getCacheDirectory();
      final fileName = _getFileNameForUrl(videoUrl);
      final filePath = p.join(cacheDir, fileName);
      print('Cache details:');
      print('- Directory: $cacheDir');
      print('- Filename: $fileName');
      print('- Full path: $filePath');

      final file = File(filePath);
      if (await file.exists()) {
        print('Existing file found, verifying...');
        try {
          final controller = VideoPlayerController.file(file);
          print('Created controller');
          await controller.initialize();
          print('Controller initialized');
          await controller.dispose();
          print('Existing file is valid');

          _cachedVideos[videoUrl] = filePath;
          _lastAccessed[videoUrl] = DateTime.now();
          await _persistUrlMapping();
          print('Cache entry updated');
          return;
        } catch (e) {
          print('Existing file verification failed: $e');
          print('Will re-download file');
          await file.delete();
        }
      }

      print('Downloading video...');
      final response = await http.get(Uri.parse(videoUrl));
      print('Download response: ${response.statusCode}');

      if (response.statusCode == 200) {
        print('Writing ${response.bodyBytes.length} bytes to file');
        await file.writeAsBytes(response.bodyBytes);
        print('File written successfully');

        print('Verifying downloaded file');
        try {
          final controller = VideoPlayerController.file(file);
          print('Created verification controller');
          await controller.initialize();
          print('Verification controller initialized');
          await controller.dispose();
          print('File verification successful');

          _cachedVideos[videoUrl] = filePath;
          _lastAccessed[videoUrl] = DateTime.now();
          await _persistUrlMapping();
          print('Cache entry added');
        } catch (e) {
          print('File verification failed: $e');
          await file.delete();
          print('Invalid file deleted');
        }
      } else {
        print('Download failed with status: ${response.statusCode}');
      }
    } catch (e, stack) {
      print('ERROR in background caching:');
      print('- Error: $e');
      print('- Stack: $stack');
    } finally {
      _activeDownloads.remove(videoUrl);
      print(
          'Removed from active downloads (remaining: ${_activeDownloads.length})');
      print('=== End _startBackgroundCaching ===\n');
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
      final tempMappingFile = File('$cacheDir/url_mapping.json.tmp');
      debugPrint(
          'VideoCacheService: Persisting URL mapping to: ${mappingFile.path}');

      final Map<String, dynamic> mapping = {};
      for (var entry in _cachedVideos.entries) {
        mapping[entry.key] = {
          'path': entry.value,
          'lastAccessed': _lastAccessed[entry.key]?.toIso8601String(),
        };
      }

      final String jsonContent = jsonEncode(mapping);

      // Write to temporary file first
      await tempMappingFile.writeAsString(jsonContent, flush: true);

      // Verify the content was written correctly
      final verificationContent = await tempMappingFile.readAsString();
      if (verificationContent != jsonContent) {
        throw Exception('URL mapping file verification failed');
      }

      // Rename temp file to actual file (atomic operation)
      await tempMappingFile.rename(mappingFile.path);

      debugPrint(
          'VideoCacheService: Successfully persisted URL mapping with ${mapping.length} entries');
    } catch (e, stack) {
      debugPrint('VideoCacheService: Error persisting URL mapping: $e');
      debugPrint('Stack trace: $stack');
    }
  }

  Future<void> _loadUrlMapping() async {
    try {
      final cacheDir = await getCacheDirectory();
      final mappingFile = File('$cacheDir/url_mapping.json');
      if (await mappingFile.exists()) {
        final String content = await mappingFile.readAsString();
        final Map<String, dynamic> mapping = jsonDecode(content);
        debugPrint(
            'VideoCacheService: Loading ${mapping.length} entries from URL mapping');

        for (var entry in mapping.entries) {
          final data = entry.value as Map<String, dynamic>;
          final String filePath = data['path'] as String;
          final file = File(filePath);

          if (await file.exists()) {
            _cachedVideos[entry.key] = filePath;
            _lastAccessed[entry.key] = DateTime.parse(data['lastAccessed']);
            debugPrint(
                'VideoCacheService: Loaded cache entry for ${entry.key}');
          } else {
            debugPrint(
                'VideoCacheService: Skipping missing cache file: $filePath');
          }
        }
        debugPrint(
            'VideoCacheService: Successfully loaded ${_cachedVideos.length} valid cache entries');
      }
    } catch (e) {
      debugPrint('Error loading URL mapping: $e');
      // If the mapping file is corrupted, try to recover by clearing it
      try {
        final cacheDir = await getCacheDirectory();
        final mappingFile = File('$cacheDir/url_mapping.json');
        if (await mappingFile.exists()) {
          await mappingFile.delete();
          debugPrint('VideoCacheService: Deleted corrupted mapping file');
        }
      } catch (e) {
        debugPrint(
            'VideoCacheService: Error cleaning up corrupted mapping file: $e');
      }
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
      await _persistUrlMapping(); // Update the mapping file
      debugPrint('Cache cleared successfully');
    } catch (e) {
      debugPrint('Error clearing cache: $e');
    }
  }

  // Preload a list of videos in the background with priority
  Future<void> preloadVideos(List<String> videoUrls,
      {bool highPriority = false}) async {
    if (highPriority) {
      // Clear existing queue for high priority downloads
      _downloadQueue.clear();
    }

    for (final url in videoUrls) {
      if (!_cachedVideos.containsKey(url) && !_activeDownloads.contains(url)) {
        debugPrint('Preloading video: $url');
        if (highPriority) {
          // Add to front of queue for high priority
          _downloadQueue.addFirst(url);
        } else {
          // Add to back of queue for normal priority
          _downloadQueue.add(url);
        }

        // Start download if possible
        if (_activeDownloads.length < _maxConcurrentDownloads) {
          final nextUrl = _downloadQueue.removeFirst();
          unawaited(_startBackgroundCaching(nextUrl));
        }
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
