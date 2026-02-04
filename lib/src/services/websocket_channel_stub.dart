import 'package:web_socket_channel/web_socket_channel.dart';

/// Stub implementation for conditional import.
/// This will be replaced by platform-specific implementations.
WebSocketChannel connect(
  Uri uri, {
  Duration? pingInterval,
  Duration? connectTimeout,
}) {
  throw UnsupportedError('No WebSocket implementation for this platform');
}
