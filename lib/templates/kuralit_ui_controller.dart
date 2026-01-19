import 'dart:typed_data';

import '../src/models/kuralit_product.dart';

/// UI-only interface that Kuralit templates use to talk to *your* app/service layer.
///
/// This file intentionally contains **no networking/audio backend implementation**.
/// It is the bridge for integrating these templates with any backend you want.
abstract class KuralitUiController {
  /// True if the app is currently connected to its backend.
  bool get isConnected;

  /// Optional active session id (if your backend uses sessions).
  String? get sessionId;

  /// Emits UI-relevant events (text, tool status, etc).
  Stream<KuralitUiEvent> get events;

  /// Ensure backend connection is up (optional).
  Future<void> connect();

  /// Send a text message.
  Future<void> sendText(String text, {Map<String, dynamic>? metadata});

  /// Start mic streaming (optional; templates can also use external UI).
  Future<void> startMic();

  /// Stop mic streaming.
  Future<void> stopMic();

  /// Called by templates to push a raw PCM chunk if they manage mic capture.
  Future<void> sendAudioChunk(Uint8List chunk);
}

/// Minimal UI event model. Expand as needed.
sealed class KuralitUiEvent {
  const KuralitUiEvent();
}

class KuralitUiTextEvent extends KuralitUiEvent {
  final String text;
  final bool isPartial;
  const KuralitUiTextEvent(this.text, {this.isPartial = false}) : super();
}

/// Structured entity response: products list.
class KuralitUiProductsEvent extends KuralitUiEvent {
  final String? title;
  final List<KuralitProduct> items;
  final String? followUpQuestion;

  const KuralitUiProductsEvent({
    this.title,
    required this.items,
    this.followUpQuestion,
  }) : super();
}

/// Speech-to-text event for user speech (UI can show it while recording).
class KuralitUiSttEvent extends KuralitUiEvent {
  final String text;
  final bool isFinal;
  const KuralitUiSttEvent(this.text, {this.isFinal = false}) : super();
}

/// Mic input loudness (0.0 - 1.0). Used to drive waveform visuals.
class KuralitUiAudioLevelEvent extends KuralitUiEvent {
  final double level;
  const KuralitUiAudioLevelEvent(this.level) : super();
}

class KuralitUiConnectionEvent extends KuralitUiEvent {
  final bool isConnected;
  final String? sessionId;
  const KuralitUiConnectionEvent({required this.isConnected, this.sessionId}) : super();
}

class KuralitUiToolStatusEvent extends KuralitUiEvent {
  final String toolName;
  final String status;
  const KuralitUiToolStatusEvent({required this.toolName, required this.status}) : super();
}

class KuralitUiErrorEvent extends KuralitUiEvent {
  final String message;
  const KuralitUiErrorEvent(this.message) : super();
}


