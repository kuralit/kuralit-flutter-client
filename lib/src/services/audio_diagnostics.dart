import 'dart:math' as math;
import 'package:flutter/foundation.dart';

/// Audio diagnostics utility to debug PCM16 audio streaming issues
class AudioDiagnostics {
  static bool _hasLoggedFirstChunk = false;
  static int _totalChunks = 0;
  static int _totalBytes = 0;
  static DateTime? _firstChunkTime;
  static bool _byteOrderVerified = false;

  /// Analyze a raw audio chunk and log detailed diagnostics
  static void analyzeChunk(Uint8List chunk, {String source = 'unknown'}) {
    _totalChunks++;
    _totalBytes += chunk.length;
    _firstChunkTime ??= DateTime.now();

    // Log first chunk details
    if (!_hasLoggedFirstChunk) {
      _logFirstChunk(chunk, source);
      _hasLoggedFirstChunk = true;
    }

    // Periodic summary every 50 chunks (~1 second at 20ms chunks)
    if (_totalChunks % 50 == 0) {
      _logSummary();
    }
  }

  static void _logFirstChunk(Uint8List chunk, String source) {
    debugPrint('\n=== AUDIO CHUNK ANALYSIS (source: $source) ===');
    debugPrint('Chunk size: ${chunk.length} bytes');
    debugPrint(
        'Note: record package provides raw PCM16 bytes without WAV headers');

    // Show first 32 bytes in hex
    final hexBytes = chunk
        .take(32)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    debugPrint('First 32 bytes (hex): $hexBytes');

    // Analyze as PCM16 samples
    _analyzePcm16Samples(chunk);

    debugPrint('==========================================\n');
  }

  static void _analyzePcm16Samples(Uint8List chunk) {
    if (chunk.length < 2) {
      debugPrint('⚠️  Chunk too small for PCM16 analysis');
      return;
    }

    // Ensure even number of bytes
    final validBytes = chunk.length - (chunk.length % 2);
    if (validBytes != chunk.length) {
      debugPrint('⚠️  WARNING: Odd number of bytes (${chunk.length})');
      debugPrint('   PCM16 requires even number of bytes!');
    }

    // Calculate sample statistics
    final samples = <int>[];
    int minSample = 32767;
    int maxSample = -32768;
    int sumSample = 0;

    for (int i = 0; i < validBytes - 1; i += 2) {
      final lo = chunk[i];
      final hi = chunk[i + 1];
      int value = (hi << 8) | lo;
      if (value & 0x8000 != 0) value = value - 0x10000;

      samples.add(value);
      minSample = math.min(minSample, value);
      maxSample = math.max(maxSample, value);
      sumSample += value;
    }

    final avgSample = sumSample ~/ samples.length;

    debugPrint('PCM16 samples: ${samples.length}');
    debugPrint('  Min: $minSample');
    debugPrint('  Max: $maxSample');
    debugPrint('  Avg: $avgSample');
    debugPrint('  Range: ${maxSample - minSample}');

    // Assess audio level
    final maxAbs = math.max(minSample.abs(), maxSample.abs());
    String assessment;
    if (maxAbs < 100) {
      assessment = 'SILENT (might be all zeros)';
    } else if (maxAbs < 1000) {
      assessment = 'VERY QUIET (possible issue)';
    } else if (maxAbs < 10000) {
      assessment = 'QUIET (acceptable)';
    } else if (maxAbs < 30000) {
      assessment = 'REASONABLE (good)';
    } else {
      assessment = 'LOUD/CLIPPING (might distort)';
    }
    debugPrint('  Assessment: $assessment');

    // Calculate expected duration
    const sampleRate = 16000;
    final durationMs = (samples.length / sampleRate * 1000).toStringAsFixed(1);
    debugPrint(
        '  Duration: ${durationMs}ms (expected: ~20ms for standard chunk)');
  }

  static void _logSummary() {
    if (_firstChunkTime == null) return;

    final elapsed = DateTime.now().difference(_firstChunkTime!);
    final elapsedSeconds = elapsed.inMilliseconds / 1000.0;
    final avgChunkSize = _totalBytes / _totalChunks;
    final chunksPerSecond = _totalChunks / elapsedSeconds;

    // print('📊 Audio Streaming Summary:');
    // print('   Total chunks: $_totalChunks');
    // print('   Total bytes: ${(_totalBytes / 1024).toStringAsFixed(1)} KB');
    // print('   Elapsed: ${elapsedSeconds.toStringAsFixed(1)}s');
    // print(
    //     '   Avg chunk size: ${avgChunkSize.toStringAsFixed(0)} bytes (expected: 640)');
    // print(
    //     '   Chunks/sec: ${chunksPerSecond.toStringAsFixed(1)} (expected: 50 @ 20ms chunks)');

    if ((avgChunkSize - 640).abs() > 100) {
      // print('   ⚠️  Chunk size deviates significantly from expected 640 bytes');
    }

    if ((chunksPerSecond - 50).abs() > 10) {
      // print('   ⚠️  Chunk rate deviates from expected 50/sec');
      // print('      This suggests timing or buffering issues');
    }
  }

  /// Verify and log byte order of PCM16 audio data
  static void verifyByteOrder(Uint8List bytes) {
    if (_byteOrderVerified || bytes.length < 20) return;
    _byteOrderVerified = true;

    debugPrint('=== BYTE ORDER VERIFICATION ===');

    // Analyze first 10 samples (20 bytes)
    final littleEndianSamples = <int>[];
    final bigEndianSamples = <int>[];

    for (int i = 0; i < 20; i += 2) {
      // Little-endian: low byte first
      final le = (bytes[i + 1] << 8) | bytes[i];
      final leValue = (le & 0x8000) != 0 ? le - 0x10000 : le;
      littleEndianSamples.add(leValue);

      // Big-endian: high byte first
      final be = (bytes[i] << 8) | bytes[i + 1];
      final beValue = (be & 0x8000) != 0 ? be - 0x10000 : be;
      bigEndianSamples.add(beValue);
    }

    debugPrint('Little-endian samples: $littleEndianSamples');
    debugPrint('Big-endian samples: $bigEndianSamples');

    // Calculate reasonable value ranges
    final leMax = littleEndianSamples.reduce(math.max).abs();
    final beMax = bigEndianSamples.reduce(math.max).abs();

    debugPrint('LE max abs value: $leMax (should be < 32768)');
    debugPrint('BE max abs value: $beMax (should be < 32768)');

    // Most devices use little-endian, warn if suspicious
    if (leMax > 32768 && beMax < 32768) {
      debugPrint('⚠️  WARNING: Data might be big-endian!');
    } else if (leMax < 32768) {
      debugPrint('✓ Byte order appears to be little-endian (expected)');
    }

    debugPrint('==============================');
  }

  /// Reset diagnostics counters
  static void reset() {
    _hasLoggedFirstChunk = false;
    _totalChunks = 0;
    _totalBytes = 0;
    _firstChunkTime = null;
    _byteOrderVerified = false;
  }

  /// Validate that bytes are likely valid PCM16
  /// Note: record package provides raw PCM16 bytes without WAV headers
  static String? validatePcm16(Uint8List chunk) {
    if (chunk.isEmpty) {
      return 'Empty chunk';
    }

    if (chunk.length % 2 != 0) {
      return 'Odd byte count (${chunk.length}) - PCM16 needs even bytes';
    }

    // Check if completely silent (all zeros)
    bool allZeros = true;
    for (var byte in chunk) {
      if (byte != 0) {
        allZeros = false;
        break;
      }
    }

    if (allZeros) {
      return 'All zeros - microphone not capturing audio';
    }

    return null; // Valid
  }
}
