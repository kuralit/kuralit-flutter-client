# Kuralit Flutter SDK

A Flutter SDK for integrating Kuralit AI agent overlay UI with WebSocket-backed voice and text interactions.

## Features

- **Voice & Text Interactions** - Support for both voice and text-based conversations with the AI agent
- **Beautiful UI Templates** - Pre-built, customizable agent overlay UI components
- **WebSocket Integration** - Real-time bidirectional communication with your backend
- **Product Cards** - Display structured product information in an elegant card strip
- **Audio Streaming** - Real-time audio capture and streaming with visual feedback
- **Customizable Themes** - Fully customizable theming system for brand consistency
- **Responsive Design** - Works seamlessly across different screen sizes
- **Session Management** - Built-in session handling for conversation continuity

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  kuralit_sdk: ^0.2.0
```

Then run:

```bash
flutter pub get
```

## Quick Start

### Basic Setup

1. Import the package:

```dart
import 'package:kuralit_sdk/kuralit.dart';
```

2. Create a WebSocket controller:

```dart
final controller = KuralitWebSocket.createController(
  config: const KuralitWebSocketConfig(
    wsUrl: 'wss://your-backend-url/ws',
  ),
);
```

3. Add the agent overlay to your app:

```dart
KuralitAgentOverlay.show(
  context,
  controller: controller,
  theme: const KuralitTheme(),
);
```

### Using the Anchor Widget

For a minimal entry point, use the `KuralitAnchor` widget:

```dart
KuralitAnchor(
  controller: controller,
  label: 'Ask for help',
  theme: const KuralitTheme(),
)
```

## Usage Examples

### Basic Agent Overlay

```dart
import 'package:flutter/material.dart';
import 'package:kuralit_sdk/kuralit.dart';

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final controller = KuralitWebSocket.createController(
      config: const KuralitWebSocketConfig(
        wsUrl: 'wss://your-backend-url/ws',
      ),
    );

    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: KuralitAnchor(
            controller: controller,
            label: 'Start Conversation',
          ),
        ),
      ),
    );
  }
}
```

### Custom Theme

```dart
final customTheme = KuralitTheme(
  surfaceColor: Colors.white,
  textPrimary: Colors.black87,
  accentColor: Colors.blue,
  cornerRadius: 16.0,
  showLogo: true,
);

KuralitAgentOverlay.show(
  context,
  controller: controller,
  theme: customTheme,
);
```

### Listening to Events

```dart
controller.events.listen((event) {
  if (event is KuralitUiTextEvent) {
    print('Agent response: ${event.text}');
  } else if (event is KuralitUiProductsEvent) {
    print('Products received: ${event.items.length}');
  } else if (event is KuralitUiConnectionEvent) {
    print('Connection status: ${event.isConnected}');
  }
});
```

### Sending Text Messages

```dart
await controller.sendText('Hello, I need help with my order');
```

### Managing Audio

```dart
// Start microphone
await controller.startMic();

// Stop microphone
await controller.stopMic();
```

## API Reference

### Core Classes

#### `KuralitWebSocketController`
Main controller interface for managing WebSocket connections and interactions.

**Key Methods:**
- `connect()` - Establish connection to backend
- `sendText(String text)` - Send text message
- `startMic()` - Start audio capture
- `stopMic()` - Stop audio capture
- `dispose()` - Clean up resources

#### `KuralitAgentOverlay`
Full-featured overlay widget for agent interactions.

#### `KuralitAnchor`
Minimal entry point widget that opens the full overlay.

#### `KuralitTheme`
Customizable theme configuration for UI components.

#### `KuralitWebSocketConfig`
Configuration for WebSocket connection.

**Properties:**
- `wsUrl` - WebSocket server URL
- `pingInterval` - Keep-alive ping interval (default: 15s)
- `connectTimeout` - Connection timeout (default: 5s)
- `audioBacklog` - Audio buffer duration (default: 300ms)
- `audioChunk` - Audio chunk duration (default: 20ms)

### Events

The SDK provides various event types through the `events` stream:

- `KuralitUiTextEvent` - Text responses from the agent
- `KuralitUiProductsEvent` - Product information
- `KuralitUiSttEvent` - Speech-to-text transcription
- `KuralitUiAudioLevelEvent` - Audio level for visual feedback
- `KuralitUiConnectionEvent` - Connection status changes
- `KuralitUiToolStatusEvent` - Tool execution status
- `KuralitUiErrorEvent` - Error notifications

## Example App

See the `example` directory for a complete example app demonstrating all features.

## Requirements

- Flutter SDK: `>=3.10.0`
- Dart SDK: `>=3.0.0 <4.0.0`

## Dependencies

- `audio_session` - Audio session management
- `record` - Audio recording capabilities
- `web_socket_channel` - WebSocket communication

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

For issues, questions, or contributions, please open an issue on the GitHub repository.
