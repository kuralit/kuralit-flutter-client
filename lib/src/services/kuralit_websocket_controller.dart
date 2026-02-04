import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:convert';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Platform-specific WebSocket imports using conditional imports
import 'websocket_channel_stub.dart'
    if (dart.library.io) 'websocket_channel_io.dart'
    if (dart.library.html) 'websocket_channel_html.dart' as ws_platform;

import 'kuralit_response_parser.dart';
import '../../templates/kuralit_ui_controller.dart';
import 'audio_diagnostics.dart';

/// Public interface for the SDK-backed controller (adds lifecycle).
abstract class KuralitWebSocketController implements KuralitUiController {
  void dispose();

  /// Force a brand new backend session (new `session_created` / `session_id`).
  ///
  /// Useful when switching modalities (e.g., text -> voice) and you want the
  /// backend to treat it as a fresh conversation.
  Future<void> startNewSession();
}

/// Default Kuralit API WebSocket base URL (without query parameters).
const String kuralitDefaultBaseWsUrl =
    'wss://kuralit-api-499321408948.us-central1.run.app/ws';

class KuralitWebSocketConfig {
  /// Full WebSocket URL. If non-null and non-empty, this is used as-is and
  /// [baseWsUrl] / [appId] are ignored. Use this for full control (e.g. emulator:
  /// `ws://10.0.2.2:8000/ws` or custom query params).
  final String? wsUrl;

  /// Base WebSocket URL (used when [wsUrl] is null or empty). Appended with
  /// `?app_id=[appId]` to form the effective URL.
  final String baseWsUrl;

  /// Kuralit app ID for the connection. Required when using [baseWsUrl];
  /// appended as `app_id` query parameter. Must be non-empty.
  final String appId;

  /// Keep idle connections alive through proxies/NAT.
  final Duration pingInterval;

  /// Fail fast if backend isn't reachable.
  final Duration connectTimeout;

  /// Outgoing audio backlog budget. If exceeded, drop oldest audio chunks.
  ///
  /// Default: 300ms.
  final Duration audioBacklog;

  /// PCM chunk duration sent over the wire.
  ///
  /// Backend contract: 20ms @ 16kHz mono PCM16 => 640 bytes per chunk.
  final Duration audioChunk;

  const KuralitWebSocketConfig({
    this.wsUrl,
    this.baseWsUrl = kuralitDefaultBaseWsUrl,
    required this.appId,
    this.pingInterval = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 10),
    this.audioBacklog = const Duration(milliseconds: 300),
    this.audioChunk = const Duration(milliseconds: 20),
  });

  /// Effective WebSocket URL: [wsUrl] if set, otherwise [baseWsUrl]?app_id=[appId].
  String get effectiveWsUrl {
    if (wsUrl != null && wsUrl!.trim().isNotEmpty) {
      return wsUrl!.trim();
    }
    if (appId.trim().isEmpty) {
      throw ArgumentError(
        'KuralitWebSocketConfig.appId must be non-empty when not using wsUrl. '
        'Provide your Kuralit app ID.',
      );
    }
    final base = baseWsUrl.trim();
    final separator = base.contains('?') ? '&' : '?';
    return '$base${separator}app_id=${Uri.encodeComponent(appId.trim())}';
  }
}

class KuralitWebSocket {
  static KuralitWebSocketController createController({
    required KuralitWebSocketConfig config,
  }) {
    return _KuralitWebSocketControllerImpl(config: config);
  }
}

class _KuralitWebSocketControllerImpl implements KuralitWebSocketController {
  final KuralitWebSocketConfig _config;

  final StreamController<KuralitUiEvent> _events =
      StreamController<KuralitUiEvent>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;

  bool _isConnected = false;
  String? _sessionId;

  Completer<void>? _connectingCompleter;
  Completer<String>? _sessionIdCompleter;

  /// Map tool_id -> tool_name so we can mark completion on `tool_response`.
  final Map<String, String> _toolIdToName = <String, String>{};

  // --- Mic / audio pipeline (Phase 2) ---
  // Using record package instead of flutter_sound to fix PCM16 white noise issue
  AudioRecorder? _recorder;
  AudioSession? _audioSession;
  StreamSubscription<Uint8List>? _micSub;

  final Queue<Uint8List> _audioQueue = Queue<Uint8List>();
  int _audioQueuedBytes = 0;
  bool _isMicActive = false;
  bool _isSendingAudio = false;
  Uint8List _audioRemainder = Uint8List(0);
  double _lastLevel = 0.0;
  int _lastLevelEmitMs = 0;
  bool _isFirstAudioChunk = true;

  // Reconnection logic
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  bool _shouldReconnect = true;

  // Audio quality monitoring
  int _totalChunksSent = 0;
  int _totalChunksDropped = 0;
  int _lastDropWarningChunks = 0;

  // Diagnostic logging
  DateTime? _lastMicBytesTime;
  int _consecutiveZeroChunks = 0;
  int _totalZeroChunks = 0;

  _KuralitWebSocketControllerImpl({required KuralitWebSocketConfig config})
      : _config = config;

  @override
  bool get isConnected => _isConnected;

  @override
  String? get sessionId => _sessionId;

  @override
  Stream<KuralitUiEvent> get events => _events.stream;

  static const int _connectMaxAttempts = 3;
  static const Duration _connectRetryDelay = Duration(seconds: 1);

  @override
  Future<void> connect() async {
    if (_isConnected) return;
    if (_connectingCompleter != null) return _connectingCompleter!.future;

    // Cancel any existing subscription before creating a new one
    // This prevents duplicate event handlers from receiving the same messages
    _wsSub?.cancel();
    _wsSub = null;

    _connectingCompleter = Completer<void>();
    _sessionIdCompleter = Completer<String>();

    try {
      for (int attempt = 1; attempt <= _connectMaxAttempts; attempt++) {
        try {
          final ch = ws_platform.connect(
            Uri.parse(_config.effectiveWsUrl),
            pingInterval: _config.pingInterval,
            connectTimeout: _config.connectTimeout,
          );
          _channel = ch;

          // Await connection establishment.
          await ch.ready;

          _isConnected = true;

          _wsSub = ch.stream.listen(
            _handleWsEvent,
            onError: (Object e, StackTrace st) {
              debugPrint('WebSocket error: $e');
              _emit(KuralitUiErrorEvent('Connection error: $e'));
              _isConnected = false;
              _reconnectWithBackoff();
            },
            onDone: () {
              debugPrint('WebSocket closed');
              _isConnected = false;
              if (_shouldReconnect) {
                _reconnectWithBackoff();
              }
            },
            cancelOnError: false,
          );

          _shouldReconnect = true;

          _connectingCompleter?.complete();
          return;
        } catch (e) {
          debugPrint('WebSocket connect attempt $attempt failed: $e');
          if (attempt < _connectMaxAttempts) {
            _wsSub?.cancel();
            _wsSub = null;
            try {
              _channel?.sink.close();
            } catch (_) {}
            _channel = null;
            await Future.delayed(_connectRetryDelay);
          } else {
            _emit(KuralitUiErrorEvent(
                'WebSocket connect failed after $_connectMaxAttempts attempts: $e'));
            _handleDisconnect();
            _connectingCompleter?.completeError(e);
            rethrow;
          }
        }
      }
    } finally {
      _connectingCompleter = null;
    }
  }

  @override
  Future<void> sendText(String text, {Map<String, dynamic>? metadata}) async {
    final q = text.trim();
    if (q.isEmpty) return;

    try {
      if (!_isConnected) {
        await connect();
      }

      final sid = _sessionId ?? await _waitForSessionId();

      final payload = <String, dynamic>{
        'type': 'question',
        'session_id': sid,
        'question': q,
      };
      _sendJson(payload);
    } catch (e) {
      // Agent Overlay does not await sendText(); never throw here.
      _emit(KuralitUiErrorEvent('Failed to send text: $e'));
    }
  }

  @override
  Future<void> startMic() async {
    if (_isMicActive) return;

    // Voice streaming is supported on Android and Web platforms
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
      _emit(const KuralitUiErrorEvent('Voice streaming is currently supported on Android and Web only.'));
      return;
    }

    try {
      // First ensure we have microphone permission
      final hasPermission = await _ensureMicrophonePermission();
      if (!hasPermission) {
        return; // Early return if permission denied
      }

      if (!_isConnected) {
        await connect();
      }

      // Requirement: start streaming only after `session_created`.
      final sid = _sessionId ?? await _waitForSessionId();
      if (sid.trim().isEmpty) {
        _emit(
            const KuralitUiErrorEvent('Missing session_id; cannot start mic.'));
        return;
      }

      // Initialize AudioRecorder if needed (record package)
      // Dispose old recorder first to ensure clean state
      if (_recorder != null) {
        try {
          debugPrint('🔄 Disposing existing recorder...');
          await _recorder!.dispose();
        } catch (e) {
          debugPrint('⚠️  Error disposing recorder: $e');
        }
      }
      _recorder = AudioRecorder();

      // Check if PCM16 encoder is supported
      final isPcm16Supported = await _recorder!.isEncoderSupported(AudioEncoder.pcm16bits);
      if (!isPcm16Supported) {
        _emit(const KuralitUiErrorEvent('PCM16 encoding not supported on this device.'));
        return;
      }

      // Configure audio focus (best-effort).
      // Audio session is not supported on web - browser handles audio automatically
      if (!kIsWeb) {
        try {
          _audioSession ??= await AudioSession.instance;

          // More robust audio session configuration
          await _audioSession!.configure(const AudioSessionConfiguration(
            avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
            avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowBluetooth,
            avAudioSessionMode: AVAudioSessionMode.spokenAudio,
            avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
            avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
            androidAudioAttributes: AndroidAudioAttributes(
              contentType: AndroidAudioContentType.speech,
              flags: AndroidAudioFlags.none,
              usage: AndroidAudioUsage.voiceCommunication,
            ),
            androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
            androidWillPauseWhenDucked: true,
          ));

          // Explicitly request audio focus
          await _audioSession!.setActive(true);
        } catch (e) {
          debugPrint('⚠️ Audio session configuration error: $e');
          // Continue anyway as best-effort
        }
      }

      _isMicActive = true;
      _audioRemainder = Uint8List(0);
      _audioQueue.clear();
      _audioQueuedBytes = 0;
      _lastLevel = 0.0;
      _lastLevelEmitMs = 0;

      // Reset first chunk flag
      _isFirstAudioChunk = true;

      // Reset statistics
      _totalChunksSent = 0;
      _totalChunksDropped = 0;
      _lastDropWarningChunks = 0;

      // Reset diagnostic counters
      _lastMicBytesTime = null;
      _consecutiveZeroChunks = 0;
      _totalZeroChunks = 0;

      // Reset audio diagnostics for new recording session
      AudioDiagnostics.reset();

      // Strict backend contract: 16kHz mono PCM16
      const sampleRate = 16000;
      const numChannels = 1;

      // Start streaming with record package
      // Using pcm16bits encoder - outputs raw PCM16 bytes (Uint8List)
      // This fixes the white noise issue from flutter_sound's toStream: parameter
      final audioStream = await _recorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: numChannels,
          // Enable audio processing features for better quality
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );

      debugPrint('🎤 Started PCM16 audio stream with record package');

      // Listen to the audio stream
      _micSub = audioStream.listen(
        (bytes) => _handleMicBytes(sid, bytes),
        onError: (Object e, StackTrace st) {
          _emit(KuralitUiErrorEvent('Mic stream error: $e'));
          // Stop mic and require user to tap again.
          stopMic();
        },
        onDone: () {
          debugPrint('⚠️  Microphone stream completed/stopped');
          if (_isMicActive) {
            stopMic();
            _emit(
                const KuralitUiErrorEvent('Microphone stream stopped unexpectedly'));
          }
        },
        cancelOnError: true,
      );
    } catch (e) {
      _emit(KuralitUiErrorEvent('Failed to start mic: $e'));
      await stopMic();
    }
  }

  @override
  Future<void> stopMic() async {
    if (!_isMicActive) return;
    _isMicActive = false;

    // Step 1: Cancel subscription first to stop receiving new data
    try {
      await _micSub?.cancel();
    } catch (_) {}
    _micSub = null;

    // Step 2: Stop the recorder (record package)
    try {
      if (_recorder != null) {
        final isRecording = await _recorder!.isRecording();
        if (isRecording) {
          await _recorder!.stop();
          debugPrint('🛑 Stopped audio recording');
        }
      }
    } catch (e) {
      debugPrint('⚠️  Error stopping recorder: $e');
    }

    // Step 3: Dispose the recorder to release resources
    // Note: We don't dispose here to allow quick restart
    // The recorder will be disposed and recreated in startMic() if needed

    // Step 4: Clear all buffers and reset state
    _audioQueue.clear();
    _audioQueuedBytes = 0;
    _audioRemainder = Uint8List(0);
    _isSendingAudio = false;
    _lastLevel = 0.0;
    _isFirstAudioChunk = true;
    _lastMicBytesTime = null;
    _consecutiveZeroChunks = 0;
    _totalZeroChunks = 0;
    _emit(const KuralitUiAudioLevelEvent(0.0));

    // Step 5: Deactivate audio session (not supported on web)
    if (!kIsWeb) {
      try {
        await _audioSession?.setActive(false);
      } catch (_) {}
    }
  }

  @override
  Future<void> sendAudioChunk(Uint8List chunk) async {
    if (chunk.isEmpty) return;
    if (!_isConnected) return;
    final sid = _sessionId;
    if (sid == null || sid.isEmpty) return;
    _enqueueAudioChunk(sid, chunk);
  }

  @override
  Future<void> startNewSession() async {
    // Tear down any existing socket/session and reconnect.
    _handleDisconnect();
    await connect();
  }

  @override
  void dispose() {
    _handleDisconnect();
    _events.close();
  }

  Future<String> _waitForSessionId() async {
    // If session id already arrived, return it.
    final sid = _sessionId;
    if (sid != null) return sid;

    final completer = _sessionIdCompleter;
    if (completer == null) {
      // Should not happen, but fall back safely.
      throw StateError('SessionId completer missing; not connected?');
    }
    return completer.future;
  }

  void _handleWsEvent(dynamic event) {
    // Server contract: JSON text frames.
    if (event is! String) return;

    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(event);
      if (decoded is! Map) return;
      msg = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }

    final type = msg['type'];
    if (type is! String) return;

    switch (type) {
      case 'session_created':
        final sid = msg['session_id'];
        if (sid is String && sid.isNotEmpty) {
          _sessionId = sid;
          if (_sessionIdCompleter != null &&
              !_sessionIdCompleter!.isCompleted) {
            _sessionIdCompleter!.complete(sid);
          }
          _emit(KuralitUiConnectionEvent(isConnected: true, sessionId: sid));
        }
        return;

      case 'tool_status':
        final toolName = msg['tool_name'];
        final status = msg['status'];
        final toolId = msg['tool_id'];

        if (toolId is String && toolName is String) {
          _toolIdToName[toolId] = toolName;
        }
        if (toolName is String && status is String) {
          _emit(KuralitUiToolStatusEvent(toolName: toolName, status: status));
        }
        return;

      case 'tool_response':
        // Requirement: do NOT show tool result summaries.
        // We only mark completion.
        final toolId = msg['tool_id'];
        if (toolId is String) {
          final toolName = _toolIdToName[toolId];
          if (toolName != null) {
            // Agent overlay treats status == 'done' as completed.
            _emit(KuralitUiToolStatusEvent(toolName: toolName, status: 'done'));
          }
        }
        return;

      case 'response':
        final evt = parseKuralitResponseMessage(msg);
        if (evt != null) _emit(evt);
        return;

      case 'error':
        final err = msg['error'];
        _emit(KuralitUiErrorEvent(err is String ? err : 'Unknown error'));
        return;

      // Audio-related events for speech-to-text.
      case 'interim_transcript':
        final t = msg['transcript'];
        if (t is String) _emit(KuralitUiSttEvent(t, isFinal: false));
        return;
      case 'final_transcript':
        final t = msg['transcript'];
        if (t is String) _emit(KuralitUiSttEvent(t, isFinal: true));
        return;

      default:
        return;
    }
  }

  void _handleMicBytes(String sid, Uint8List bytes) {
    if (!_isMicActive || bytes.isEmpty) return;

    // Diagnostic logging: Track raw mic bytes
    final now = DateTime.now();
    final timeSinceLastCall = _lastMicBytesTime != null
        ? now.difference(_lastMicBytesTime!).inMilliseconds
        : 0;
    if (timeSinceLastCall > 100) {
      debugPrint(
          '⚠️  Gap in mic stream: ${timeSinceLastCall}ms since last call');
    }
    _lastMicBytesTime = now;

    // Log raw mic bytes (first time or every 50th call to avoid spam)
    final isZeroChunk = bytes.every((b) => b == 0);
    if (_isFirstAudioChunk || _totalChunksSent % 50 == 0) {
      debugPrint(
          '🎤 Mic bytes: size=${bytes.length}, is_all_zeros=$isZeroChunk, time_since_last=${timeSinceLastCall}ms');
    }

    // Step 1: Diagnostic analysis (only on first chunk)
    if (_isFirstAudioChunk) {
      AudioDiagnostics.analyzeChunk(bytes, source: 'record_package');
      AudioDiagnostics.verifyByteOrder(bytes);
    }

    // Step 2: Validate audio format (allow silence, only block critical errors)
    // Note: flutter_sound provides raw PCM16 bytes without WAV headers
    final validationError = AudioDiagnostics.validatePcm16(bytes);
    if (validationError != null) {
      // Silence (all zeros) is expected and should be processed normally
      final isSilence = validationError.contains('All zeros');

      if (isSilence) {
        // Track zero chunks for diagnostic purposes
        _totalZeroChunks++;
        _consecutiveZeroChunks++;
        if (_consecutiveZeroChunks % 50 == 0) {
          debugPrint(
              '⚠️  Zero chunks: consecutive=$_consecutiveZeroChunks, total=$_totalZeroChunks');
        }
        // Reset if we get non-zero data
      } else {
        // Other validation errors (empty, odd bytes) - log and skip
        debugPrint('Audio format error: $validationError');
        // Skip critical format issues
        if (validationError.contains('Empty chunk') ||
            validationError.contains('Odd byte count')) {
          return;
        }
      }
    } else {
      // Non-zero chunk detected - reset consecutive zero counter
      if (_consecutiveZeroChunks > 0) {
        debugPrint(
            '✅ Non-zero chunk detected after $_consecutiveZeroChunks zero chunks');
      }
      _consecutiveZeroChunks = 0;
    }

    // Mark first chunk as processed (whether silence or actual audio)
    if (_isFirstAudioChunk) {
      _isFirstAudioChunk = false;
    }

    _maybeEmitAudioLevel(bytes);

    // Build up a remainder buffer so we can emit fixed-size chunks.
    final remainderBefore = _audioRemainder.length;
    if (_audioRemainder.isEmpty) {
      _audioRemainder = bytes;
    } else {
      final merged = Uint8List(_audioRemainder.length + bytes.length);
      merged.setAll(0, _audioRemainder);
      merged.setAll(_audioRemainder.length, bytes);
      _audioRemainder = merged;
    }

    final bytesPerChunk = _bytesPerChunk();
    int chunksExtracted = 0;
    while (_audioRemainder.length >= bytesPerChunk) {
      final chunk =
          Uint8List.fromList(_audioRemainder.sublist(0, bytesPerChunk));
      _enqueueAudioChunk(sid, chunk);
      _audioRemainder =
          Uint8List.fromList(_audioRemainder.sublist(bytesPerChunk));
      chunksExtracted++;
    }

    // Log remainder buffer state (every 50th call to avoid spam)
    if (_totalChunksSent % 50 == 0 || chunksExtracted > 0) {
      debugPrint(
          '📦 Remainder buffer: before_size=$remainderBefore, after_size=${_audioRemainder.length}, chunks_extracted=$chunksExtracted, is_all_zeros=${_audioRemainder.isEmpty || _audioRemainder.every((b) => b == 0)}');
    }
  }

  int _bytesPerChunk() {
    // PCM16 (2 bytes/sample) * 16kHz * 20ms * mono
    final ms = _config.audioChunk.inMilliseconds;
    final samples = (16000 * ms) ~/ 1000; // 320 @ 20ms
    return samples * 2;
  }

  int _maxBacklogBytes() {
    final frames = (_config.audioBacklog.inMilliseconds /
            _config.audioChunk.inMilliseconds)
        .floor();
    final safeFrames = frames <= 0 ? 1 : frames;
    return safeFrames * _bytesPerChunk();
  }

  void _enqueueAudioChunk(String sid, Uint8List chunk) {
    if (!_isMicActive) return;
    if (!_isConnected || _channel == null) {
      // Requirement: stop recording and require user to tap mic again.
      stopMic();
      return;
    }

    _audioQueue.addLast(chunk);
    _audioQueuedBytes += chunk.length;

    final maxBytes = _maxBacklogBytes();
    while (_audioQueuedBytes > maxBytes && _audioQueue.isNotEmpty) {
      final dropped = _audioQueue.removeFirst();
      _audioQueuedBytes -= dropped.length;
      _totalChunksDropped++;
    }

    // Warn if drop rate exceeds 5% (check every 100 chunks)
    if (_totalChunksSent > 0 &&
        _totalChunksSent % 100 == 0 &&
        _totalChunksSent != _lastDropWarningChunks) {
      final dropRate = _totalChunksDropped / _totalChunksSent;
      if (dropRate > 0.05) {
        _lastDropWarningChunks = _totalChunksSent;
        final dropPercent = (dropRate * 100).toStringAsFixed(1);
        debugPrint(
            '⚠️  High audio drop rate: $dropPercent% ($_totalChunksDropped/$_totalChunksSent)');
        _emit(KuralitUiErrorEvent(
            'Audio quality degraded: $dropPercent% chunks dropped'));
      }
    }

    // Start continuous audio sending loop if not already running
    // This loop runs independently and continuously while mic is active,
    // ensuring audio chunks are sent without interruption, even when text messages are sent
    if (_isSendingAudio) return;
    _isSendingAudio = true;
    scheduleMicrotask(() async {
      try {
        // Continuous loop: keep sending audio chunks as long as mic is active
        // This ensures audio streaming is never interrupted by other operations (like sending text)
        while (_isMicActive && _isConnected) {
          if (_audioQueue.isNotEmpty) {
            // Process all available chunks
            while (_audioQueue.isNotEmpty && _isMicActive && _isConnected) {
              final next = _audioQueue.removeFirst();
              _audioQueuedBytes -= next.length;
              _sendAudioIn(sid, next);
              // Small delay to avoid overwhelming the WebSocket
              await Future<void>.delayed(Duration.zero);
            }
          } else {
            // Queue is empty - wait briefly for new chunks before checking again
            // This ensures continuous streaming without gaps, even during silence
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }

          // Stream health check: Detect if mic stream stopped sending data
          if (_lastMicBytesTime != null) {
            final timeSinceLastCall =
                DateTime.now().difference(_lastMicBytesTime!);
            if (timeSinceLastCall.inSeconds > 2) {
              debugPrint(
                  '⚠️  No audio bytes received for ${timeSinceLastCall.inSeconds}s. Stopping mic.');
              stopMic();
              _emit(const KuralitUiErrorEvent(
                  'Microphone stream appears to have stopped'));
              break;
            }
          }
        }
      } finally {
        _isSendingAudio = false;
        debugPrint(
            '🔇 Audio sending loop stopped (mic inactive or disconnected)');
      }
    });
  }

  void _sendAudioIn(String sid, Uint8List chunk) {
    _totalChunksSent++;

    // Diagnostic logging: Track what's being sent
    final isZeroChunk = chunk.every((b) => b == 0);
    if (_totalChunksSent % 50 == 0 || isZeroChunk) {
      debugPrint(
          '📤 Sending chunk #$_totalChunksSent: size=${chunk.length}, is_all_zeros=$isZeroChunk, base64_length=${base64Encode(chunk).length}');
    }

    final base64Chunk = base64Encode(chunk);
    final payload = <String, dynamic>{
      'type': 'audio_in',
      'session_id': sid,
      'data': <String, dynamic>{
        'chunk': base64Chunk,
      },
    };

    _sendJson(payload);
  }

  void _maybeEmitAudioLevel(Uint8List bytes) {
    // Throttle UI events (we only need ~20-50ms updates).
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastLevelEmitMs < 50) return;
    _lastLevelEmitMs = now;

    // RMS over PCM16 little-endian samples.
    final len = bytes.length - (bytes.length % 2);
    if (len <= 0) return;

    double sumSq = 0.0;
    final samples = len ~/ 2;
    for (int i = 0; i < len; i += 2) {
      final lo = bytes[i];
      final hi = bytes[i + 1];
      int v = (hi << 8) | lo;
      if (v & 0x8000 != 0) v = v - 0x10000; // sign extend
      final fv = v.toDouble();
      sumSq += fv * fv;
    }
    final rms = math.sqrt(sumSq / samples) / 32768.0; // 0..1

    // Map RMS -> dBFS -> 0..1 so speech visibly moves the UI.
    // Use a higher noise floor for better silence detection
    const minDb = -50.0; // Higher noise floor (was -55.0)
    const maxDb = -2.0;  // Allow some headroom (was 0.0)
    final safe = rms <= 1e-9 ? 1e-9 : rms;
    final db = 20.0 * (math.log(safe) / math.ln10); // log10
    final norm = ((db - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);

    // More aggressive compressor curve for clearer distinction between speech and silence
    // Lower exponent creates stronger threshold effect
    final curved = math.pow(norm, 0.45).toDouble();

    // Asymmetric smoothing - faster attack, slower release
    final double smoothed;
    if (curved > _lastLevel) {
      // Fast attack - quickly respond to beginning of speech
      smoothed = (_lastLevel * 0.40) + (curved * 0.60);
    } else {
      // Slow release - gradual falloff after speech ends
      smoothed = (_lastLevel * 0.80) + (curved * 0.20);
    }
    _lastLevel = smoothed;

    _emit(KuralitUiAudioLevelEvent(smoothed));
  }

  void _sendJson(Map<String, dynamic> payload) {
    final sink = _channel?.sink;
    if (sink == null) {
      debugPrint('⚠️  Cannot send to WebSocket: sink is null');
      return;
    }
    try {
      final jsonString = jsonEncode(payload);
      // Only log full JSON for non-audio messages to avoid spam
      if (payload['type'] != 'audio_in') {
        debugPrint('📤 WebSocket JSON: $jsonString');
      }
      sink.add(jsonString);
    } catch (e) {
      debugPrint('❌ Failed to send to WebSocket: $e');
      _emit(KuralitUiErrorEvent('Send failed: $e'));
    }
  }

  void _emit(KuralitUiEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  Future<void> _reconnectWithBackoff() async {
    if (!_shouldReconnect || _reconnectAttempts >= _maxReconnectAttempts) {
      _emit(const KuralitUiErrorEvent('Max reconnection attempts reached'));
      return;
    }

    _reconnectAttempts++;
    final delaySeconds = math.pow(2, _reconnectAttempts - 1).toInt();

    debugPrint(
        'Reconnecting in $delaySeconds seconds (attempt $_reconnectAttempts/$_maxReconnectAttempts)...');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      try {
        await connect();
        _reconnectAttempts = 0; // Reset on success
        debugPrint('✓ Reconnected successfully');
      } catch (e) {
        debugPrint('Reconnection failed: $e');
        _reconnectWithBackoff(); // Try again
      }
    });
  }

  Future<void> disconnect() async {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectAttempts = 0;
    _handleDisconnect();
  }

  /// Checks and requests microphone permission if not already granted.
  /// Returns true if permission is granted, false otherwise.
  Future<bool> _ensureMicrophonePermission() async {
    try {
      // Check current permission status
      final status = await Permission.microphone.status;

      if (status.isGranted) {
        return true; // Already granted
      }

      // Request permission
      final result = await Permission.microphone.request();

      if (result.isGranted) {
        return true; // User granted permission
      } else {
        // Handle different denial scenarios
        if (result.isPermanentlyDenied) {
          _emit(const KuralitUiErrorEvent(
            'Microphone permission permanently denied. Please enable it in app settings.',
          ));

          // We don't open app settings directly here.
          // The UI layer will provide a button for this purpose
        } else {
          _emit(const KuralitUiErrorEvent(
            'Microphone permission denied. Voice features require microphone access.',
          ));
        }
        return false;
      }
    } catch (e) {
      _emit(KuralitUiErrorEvent('Error checking microphone permission: $e'));
      return false;
    }
  }

  void _handleDisconnect() {
    // If mic was active, stop it. Requirement: user must tap mic again after reconnect.
    if (_isMicActive) {
      // Best-effort; don't await inside sync close path.
      unawaited(stopMic());
    }

    // Dispose recorder to release resources
    try {
      _recorder?.dispose();
    } catch (_) {}
    _recorder = null;

    _isConnected = false;
    _sessionId = null;
    _toolIdToName.clear();

    _wsSub?.cancel();
    _wsSub = null;

    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    if (!_events.isClosed) {
      _emit(const KuralitUiConnectionEvent(isConnected: false));
    }

    if (_sessionIdCompleter != null && !_sessionIdCompleter!.isCompleted) {
      _sessionIdCompleter!
          .completeError(StateError('Disconnected before session_created'));
    }
    _sessionIdCompleter = null;
  }
}
