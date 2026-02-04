# Kuralit SDK for Flutter

Flutter SDK for Kuralit real-time voice and text communication over WebSocket. Supports text chat, voice streaming (Android and Web), product/entity responses, tool status, and automatic reconnection.

To get the Kuralit Agent working for your app, check [kuralit.com](https://kuralit.com).

## Features

- **Voice & Text Interactions** — Support for both voice and text-based conversations with the AI agent
- **Beautiful UI Templates** — Pre-built, customizable agent overlay UI components
- **WebSocket Integration** — Real-time bidirectional communication with your backend
- **Product Cards** — Display structured product information in an elegant card strip
- **Audio Streaming** — Real-time audio capture and streaming with visual feedback
- **Customizable Themes** — Fully customizable theming system for brand consistency
- **Responsive Design** — Works seamlessly across different screen sizes
- **Session Management** — Built-in session handling for conversation continuity

## Installation

**From pub.dev** (when published):

```yaml
dependencies:
  kuralit_sdk: ^0.3.0
```

**From a local path** (e.g. same repo):

```yaml
dependencies:
  kuralit_sdk:
    path: ../kuralit   # or path to the kuralit package
```

Then run:

```bash
flutter pub get
```

## Integration (reference code)

Use this as the reference when integrating Kuralit into any Flutter app.

### 1. Add the import

```dart
import 'package:kuralit_sdk/kuralit.dart';
```

### 2. Create the controller and UI in a StatefulWidget

Create the WebSocket controller once (e.g. in your home or main screen state) and dispose it when the widget is disposed. Add the `KuralitAnchor` as the entry point (e.g. floating action button).

```dart
class _YourScreenState extends State<YourScreen> {
  late final KuralitWebSocketController _kuralitController =
      KuralitWebSocket.createController(
    config: KuralitWebSocketConfig(appId: 'your-kuralit-app-id'),
  );

  @override
  void dispose() {
    _kuralitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: KuralitAnchor(controller: _kuralitController),
      // ... rest of your UI
    );
  }
}
```

### 3. Configuration options

`appId` is required (no default). If you use [baseWsUrl] and pass an empty `appId`, the SDK throws.

| Use case | Code |
|----------|------|
| **Your app ID** (required) | `KuralitWebSocket.createController(config: KuralitWebSocketConfig(appId: 'your-app-id'))` |
| **Custom server + app ID** | `KuralitWebSocket.createController(config: KuralitWebSocketConfig(baseWsUrl: 'wss://your-server.com/ws', appId: 'your-app-id'))` |
| **Full URL override** (e.g. emulator) | `KuralitWebSocket.createController(config: KuralitWebSocketConfig(wsUrl: 'ws://10.0.2.2:8000/ws', appId: ''))` — when `wsUrl` is set, `appId` can be empty. |

### 4. Permissions (for voice)

Voice streaming is supported on **Android** and **Web** only. Add microphone permissions when using voice:

- **Android**: `android/app/src/main/AndroidManifest.xml` — add if not present:
  ```xml
  <uses-permission android:name="android.permission.RECORD_AUDIO"/>
  ```
- **Web**: The browser will prompt for microphone access when voice is used.
- **iOS**: Not yet supported for voice streaming. When support is added, add to `ios/Runner/Info.plist`:
  ```xml
  <key>NSMicrophoneUsageDescription</key>
  <string>This app uses the microphone for voice interaction.</string>
  ```

## API summary

- **`KuralitWebSocket.createController({ config })`** — Creates the WebSocket-backed controller. Pass `KuralitWebSocketConfig(appId: '...')` to set your Kuralit app ID. Uses platform-specific WebSocket (dart:io / web) under the hood.
- **`KuralitWebSocketController`** — Implements `KuralitUiController`: `connect()`, `sendText()`, `startMic()` / `stopMic()`, `startNewSession()`, `dispose()`. Emits events (text, products, STT, tool status, connection, errors). Automatic reconnection with backoff (up to 5 attempts) on disconnect.
- **`KuralitAnchor(controller: ..., theme: ..., label: ...)`** — Widget that opens the agent overlay (e.g. FAB). Pass your `KuralitWebSocketController`, optional `KuralitTheme`, and optional `label` (default: `"Ask for help"`).
- **`KuralitWebSocketConfig`** — `appId`, `baseWsUrl`, optional `wsUrl`, plus `pingInterval`, `connectTimeout`, `audioBacklog`, `audioChunk`.
- **`kuralitDefaultBaseWsUrl`** — Default Kuralit API base URL; use with custom `appId` if needed.
- **`startNewSession()`** — Tears down the current connection and reconnects so the backend creates a new session. Use when switching modalities (e.g. text → voice) for a fresh conversation.

## Example app

The **example** app in this repo (`example/lib/main.dart`) is a minimal Flutter app. Wire Kuralit as in the Integration section above: create `KuralitWebSocketController` in your screen state, dispose it in `dispose()`, and add `KuralitAnchor(controller: _kuralitController)` to your scaffold (e.g. `floatingActionButton`).
