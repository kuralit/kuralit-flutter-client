import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Native platform (Android/iOS/desktop) WebSocket implementation.
/// Uses IOWebSocketChannel which supports pingInterval and connectTimeout.
WebSocketChannel connect(
  Uri uri, {
  Duration? pingInterval,
  Duration? connectTimeout,
}) {
  return IOWebSocketChannel.connect(
    uri,
    pingInterval: pingInterval,
    connectTimeout: connectTimeout,
  );
}
