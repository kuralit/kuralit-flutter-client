import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Web platform WebSocket implementation.
/// Uses HtmlWebSocketChannel which works in browsers.
/// Note: HtmlWebSocketChannel doesn't support pingInterval/connectTimeout
/// parameters - these are handled by the browser's WebSocket implementation.
WebSocketChannel connect(
  Uri uri, {
  Duration? pingInterval,
  Duration? connectTimeout,
}) {
  // HtmlWebSocketChannel doesn't support pingInterval/connectTimeout
  // Browser handles connection management automatically
  return HtmlWebSocketChannel.connect(uri);
}
