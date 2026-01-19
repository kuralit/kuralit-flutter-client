import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:convert';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';

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

class KuralitWebSocketConfig {
  /// Example emulator default: `ws://10.0.2.2:8000/ws`
  final String wsUrl;

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
    // this.wsUrl = 'wss://kuralit-backend-server-499321408948.us-central1.run.app/ws',
    this.wsUrl = 'ws://10.0.2.2:8080/ws',
    this.pingInterval = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 5),
    this.audioBacklog = const Duration(milliseconds: 300),
    this.audioChunk = const Duration(milliseconds: 20),
  });
}

class KuralitWebSocket {
  static KuralitWebSocketController createController({
    KuralitWebSocketConfig config = const KuralitWebSocketConfig(),
  }) {
    return _KuralitWebSocketControllerImpl(config: config);
  }
}

class _KuralitWebSocketControllerImpl implements KuralitWebSocketController {
  final KuralitWebSocketConfig _config;

  final StreamController<KuralitUiEvent> _events =
      StreamController<KuralitUiEvent>.broadcast();

  IOWebSocketChannel? _channel;
  StreamSubscription? _wsSub;

  bool _isConnected = false;
  String? _sessionId;

  Completer<void>? _connectingCompleter;
  Completer<String>? _sessionIdCompleter;

  /// Map tool_id -> tool_name so we can mark completion on `tool_response`.
  final Map<String, String> _toolIdToName = <String, String>{};

  // --- Mic / audio pipeline (Phase 2) ---
  final AudioRecorder _recorder = AudioRecorder();
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

  _KuralitWebSocketControllerImpl({required KuralitWebSocketConfig config})
      : _config = config;

  @override
  bool get isConnected => _isConnected;

  @override
  String? get sessionId => _sessionId;

  @override
  Stream<KuralitUiEvent> get events => _events.stream;

  @override
  Future<void> connect() async {
    if (_isConnected) return;
    if (_connectingCompleter != null) return _connectingCompleter!.future;

    _connectingCompleter = Completer<void>();
    _sessionIdCompleter = Completer<String>();

    try {
      final ch = IOWebSocketChannel.connect(
        Uri.parse(_config.wsUrl),
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
    } catch (e) {
      _emit(KuralitUiErrorEvent('WebSocket connect failed: $e'));
      _handleDisconnect();
      _connectingCompleter?.completeError(e);
      rethrow;
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

      // Android-first: keep behavior explicit and predictable.
      if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
        _emit(const KuralitUiErrorEvent('Voice streaming is Android-first.'));
        return;
      }

    try {
      if (!_isConnected) {
        await connect();
      }

      // Requirement: start streaming only after `session_created`.
      final sid = _sessionId ?? await _waitForSessionId();
      if (sid.trim().isEmpty) {
        _emit(const KuralitUiErrorEvent('Missing session_id; cannot start mic.'));
        return;
      }

      final hasPerm = await _recorder.hasPermission();
      if (!hasPerm) {
        _emit(const KuralitUiErrorEvent('Microphone permission not granted.'));
        return;
      }

      // Configure audio focus (best-effort).
      try {
        _audioSession ??= await AudioSession.instance;
        await _audioSession!.configure(const AudioSessionConfiguration.speech());
        await _audioSession!.setActive(true);
      } catch (e) {
        // Best-effort; do not fail mic start.
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

      // Reset audio diagnostics for new recording session
      AudioDiagnostics.reset();

      // Strict backend contract.
      const sampleRate = 16000;
      const numChannels = 1;

      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: numChannels,
        ),
      );
      _micSub = stream.listen(
        (bytes) => _handleMicBytes(sid, bytes),
        onError: (Object e, StackTrace st) {
          _emit(KuralitUiErrorEvent('Mic stream error: $e'));
          // Stop mic and require user to tap again.
          stopMic();
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

    try {
      await _micSub?.cancel();
    } catch (_) {}
    _micSub = null;

    _audioQueue.clear();
    _audioQueuedBytes = 0;
    _audioRemainder = Uint8List(0);
    _isSendingAudio = false;
    _lastLevel = 0.0;
    _emit(const KuralitUiAudioLevelEvent(0.0));

    try {
      await _recorder.stop();
    } catch (_) {}

    try {
      await _audioSession?.setActive(false);
    } catch (_) {}
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
          if (_sessionIdCompleter != null && !_sessionIdCompleter!.isCompleted) {
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

    // Step 1: Diagnostic analysis (only on first chunk)
    if (_isFirstAudioChunk) {
      AudioDiagnostics.analyzeChunk(bytes, source: 'record_package');
      AudioDiagnostics.verifyByteOrder(bytes);
    }

    // Step 2: Strip WAV header ONLY from first chunk
    if (_isFirstAudioChunk) {
      _isFirstAudioChunk = false;
      bytes = AudioDiagnostics.stripWavHeader(bytes);
    }

    // Validate audio format
    final validationError = AudioDiagnostics.validatePcm16(bytes);
    if (validationError != null) {
      _emit(KuralitUiErrorEvent('Audio format error: $validationError'));
      return;
    }

    _maybeEmitAudioLevel(bytes);

    // Build up a remainder buffer so we can emit fixed-size chunks.
    if (_audioRemainder.isEmpty) {
      _audioRemainder = bytes;
    } else {
      final merged = Uint8List(_audioRemainder.length + bytes.length);
      merged.setAll(0, _audioRemainder);
      merged.setAll(_audioRemainder.length, bytes);
      _audioRemainder = merged;
    }

    final bytesPerChunk = _bytesPerChunk();
    while (_audioRemainder.length >= bytesPerChunk) {
      final chunk = Uint8List.fromList(
        _audioRemainder.sublist(0, bytesPerChunk)
      );
      _enqueueAudioChunk(sid, chunk);
      _audioRemainder = Uint8List.fromList(
        _audioRemainder.sublist(bytesPerChunk)
      );
    }
  }

  int _bytesPerChunk() {
    // PCM16 (2 bytes/sample) * 16kHz * 20ms * mono
    final ms = _config.audioChunk.inMilliseconds;
    final samples = (16000 * ms) ~/ 1000; // 320 @ 20ms
    return samples * 2;
  }

  int _maxBacklogBytes() {
    final frames = (_config.audioBacklog.inMilliseconds / _config.audioChunk.inMilliseconds).floor();
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
        debugPrint('⚠️  High audio drop rate: $dropPercent% ($_totalChunksDropped/$_totalChunksSent)');
        _emit(KuralitUiErrorEvent('Audio quality degraded: $dropPercent% chunks dropped'));
      }
    }

    if (_isSendingAudio) return;
    _isSendingAudio = true;
    scheduleMicrotask(() async {
      try {
        while (_isMicActive && _isConnected && _audioQueue.isNotEmpty) {
          final next = _audioQueue.removeFirst();
          _audioQueuedBytes -= next.length;
          _sendAudioIn(sid, next);
          // Yield to avoid starving UI.
          await Future<void>.delayed(Duration.zero);
        }
      } finally {
        _isSendingAudio = false;
      }
    });
  }

  void _sendAudioIn(String sid, Uint8List chunk) {
    _totalChunksSent++;

    final payload = <String, dynamic>{
      'type': 'audio_in',
      'session_id': sid,
      'data': <String, dynamic>{
        'chunk': base64Encode(chunk),
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
    // Typical speech RMS is small (~0.01-0.08), so linear mapping looks static.
    const minDb = -55.0; // noise floor
    const maxDb = 0.0;
    final safe = rms <= 1e-9 ? 1e-9 : rms;
    final db = 20.0 * (math.log(safe) / math.ln10); // log10
    final norm = ((db - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);

    // Gentle compressor curve (boost low levels, tame highs).
    final curved = math.pow(norm, 0.55).toDouble();

    // Smooth to avoid jitter.
    final smoothed = (_lastLevel * 0.70) + (curved * 0.30);
    _lastLevel = smoothed;

    _emit(KuralitUiAudioLevelEvent(smoothed));
  }

  void _sendJson(Map<String, dynamic> payload) {
    final sink = _channel?.sink;
    if (sink == null) return;
    try {
      sink.add(jsonEncode(payload));
    } catch (e) {
      _emit(KuralitUiErrorEvent('Send failed: $e'));
    }
  }

  void _emit(KuralitUiEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  Future<void> _reconnectWithBackoff() async {
    if (!_shouldReconnect || _reconnectAttempts >= _maxReconnectAttempts) {
      _emit(KuralitUiErrorEvent('Max reconnection attempts reached'));
      return;
    }

    _reconnectAttempts++;
    final delaySeconds = math.pow(2, _reconnectAttempts - 1).toInt();

    debugPrint('Reconnecting in $delaySeconds seconds (attempt $_reconnectAttempts/$_maxReconnectAttempts)...');

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

  void _handleDisconnect() {
    // If mic was active, stop it. Requirement: user must tap mic again after reconnect.
    if (_isMicActive) {
      // Best-effort; don't await inside sync close path.
      unawaited(stopMic());
    }

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
      _sessionIdCompleter!.completeError(StateError('Disconnected before session_created'));
    }
    _sessionIdCompleter = null;
  }
}


