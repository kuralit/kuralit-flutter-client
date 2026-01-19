/// Kuralit SDK for Flutter.
///
/// Exports the agent overlay UI template and WebSocket-backed controller.
library kuralit_sdk;

export 'templates/kuralit_ui_controller.dart'
    show
        KuralitUiController,
        KuralitUiEvent,
        KuralitUiTextEvent,
        KuralitUiProductsEvent,
        KuralitUiSttEvent,
        KuralitUiAudioLevelEvent,
        KuralitUiToolStatusEvent,
        KuralitUiConnectionEvent,
        KuralitUiErrorEvent;

export 'src/models/kuralit_product.dart' show KuralitProduct;

export 'src/services/kuralit_websocket_controller.dart'
    show
        KuralitWebSocketController,
        KuralitWebSocket,
        KuralitWebSocketConfig;

// Export agent overlay template
export 'templates/agent_overlay/kuralit_agent_overlay.dart' show KuralitAgentOverlay, KuralitAnchor, KuralitTheme;

