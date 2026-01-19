import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../base_template.dart';
import '../kuralit_ui_controller.dart';
import 'product_cards_strip.dart';
import '../../src/services/kuralit_websocket_controller.dart';

/// Defines the visual styling for Kuralit components.
/// Defaults to a neutral, brand-safe "Quiet" theme.
class KuralitTheme {
  final Color surfaceColor;
  final Color textPrimary;
  final Color textSecondary;
  final Color accentColor;
  final Color iconNeutral;
  final Color dividerColor;
  final double cornerRadius;
  final String? fontFamily;
  final bool showLogo;

  const KuralitTheme({
    this.surfaceColor = const Color(0xFFFFFFFF),
    this.textPrimary = const Color(0xFF0F172A), // Slate 900
    this.textSecondary = const Color(0xFF475569), // Slate 600
    this.accentColor = const Color(0xFF16A34A), // Green 600
    this.iconNeutral = const Color(0xFF64748B), // Slate 500
    this.dividerColor = const Color(0x0F000000), // Black 6%
    this.cornerRadius = 24.0,
    this.fontFamily,
    this.showLogo = true,
  });
}

/// Level 1: Anchor
/// A minimal, quiet entry point for the assistant.
class KuralitAnchor extends StatelessWidget {
  final KuralitUiController controller;
  final KuralitTheme theme;
  final String label;

  const KuralitAnchor({
    Key? key,
    required this.controller,
    this.theme = const KuralitTheme(),
    this.label = "Ask for help",
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => KuralitAgentOverlay.show(context, controller: controller, theme: theme),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: theme.surfaceColor,
          borderRadius: BorderRadius.circular(theme.cornerRadius),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_none_rounded, color: theme.iconNeutral, size: 24),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
                fontFamily: theme.fontFamily,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Level 2 & 3: Assist & Focus Overlay
class KuralitAgentOverlay extends KuralitBaseTemplate {
  final KuralitTheme theme;

  const KuralitAgentOverlay({
    Key? key,
    required KuralitUiController controller,
    String? sessionId,
    this.theme = const KuralitTheme(),
  }) : super(key: key, controller: controller, sessionId: sessionId);

  static void show(
    BuildContext context, {
    required KuralitUiController controller,
    String? sessionId,
    KuralitTheme theme = const KuralitTheme(),
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: true,
      builder: (context) => Padding(
         padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
         child: KuralitAgentOverlay(controller: controller, sessionId: sessionId, theme: theme),
      ),
    );
  }

  @override
  State<KuralitAgentOverlay> createState() => _KuralitAgentOverlayState();
}

class _KuralitAgentOverlayState extends State<KuralitAgentOverlay>
    with TickerProviderStateMixin {
  
  // Logic State
  bool _isConnected = false;
  bool _isAgentActive = false;
  StreamSubscription<KuralitUiEvent>? _eventSubscription;
  bool _isRecording = false;
  String? _serverSessionId;

  // Conversation (Option A): last 10 turns per overlay session.
  final List<_OverlayMessage> _messages = <_OverlayMessage>[];
  final ScrollController _messagesScrollController = ScrollController();

  bool _isProcessingTool = false;
  String? _processingToolName;
  String? _toolStatusText; // transient row above input
  final Set<String> _selectedProductIds = <String>{};
  
  // Input mode state
  _InputMode _mode = _InputMode.voice;

  // Text Input State (text mode only)
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();

  // Animation / Visuals
  Timer? _amplitudeTimer;
  Timer? _toolStatusHideTimer;
  double _audioLevel = 0.0; // 0.0 to 1.0
  late AnimationController _waveController;

  // UI Mode State
  bool _isFocusMode = false;

  // Mic mode STT (Phase 2): show interim live; final becomes a user bubble.
  String? _liveSttText;

  @override
  void initState() {
    super.initState();
    _setupEventListener();
    
    // Wave controller for listening state only
    _waveController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2000)
    );
  }

  void _setupEventListener() {
    _eventSubscription = widget.controller.events.listen((event) {
      if (!mounted) return;

      if (event is KuralitUiTextEvent) {
        _appendAssistantText(event.text);
      } else if (event is KuralitUiProductsEvent) {
        _appendAssistantProducts(event);
      } else if (event is KuralitUiToolStatusEvent) {
        _toolStatusHideTimer?.cancel();
        _toolStatusHideTimer = null;

        final statusLower = event.status.trim().toLowerCase();
        final isCompleted = statusLower == 'done' || statusLower == 'completed';

        setState(() {
          _isProcessingTool = !isCompleted;
          _processingToolName = event.toolName;
          _toolStatusText = '${event.toolName} • ${event.status}';
        });

        if (isCompleted) {
          _toolStatusHideTimer = Timer(const Duration(seconds: 5), () {
            if (!mounted) return;
            setState(() {
              _toolStatusText = null;
            });
          });
        }
      } else if (event is KuralitUiConnectionEvent) {
        setState(() {
          _isConnected = event.isConnected;
          _serverSessionId = event.sessionId;
        });

        // Mic-only behavior: if we lose connection while recording, stop and show toast.
        if (!event.isConnected && _mode == _InputMode.voice && _isRecording) {
          unawaited(_stopAgent());
          _liveSttText = null;
          final messenger = ScaffoldMessenger.maybeOf(context);
          messenger?.hideCurrentSnackBar();
          messenger?.showSnackBar(
            const SnackBar(
              content: Text('Connection lost — tap mic to start again'),
              duration: Duration(milliseconds: 1400),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else if (event is KuralitUiSttEvent) {
        // Mic-only: show interim transcript live; final transcript becomes a user bubble.
        if (_mode != _InputMode.voice) return;

        final t = event.text.trim();
        if (t.isEmpty) return;

        if (event.isFinal) {
          setState(() {
            _liveSttText = null;
          });
          _appendUserText(t);
          _showAssistantTyping();
        } else {
          setState(() {
            _liveSttText = t;
          });
        }
      } else if (event is KuralitUiAudioLevelEvent) {
        // Mic-only: drive waveform based on real mic loudness.
        if (_mode != _InputMode.voice || !_isRecording) return;
        setState(() {
          _audioLevel = event.level.clamp(0.0, 1.0);
        });
      } else if (event is KuralitUiErrorEvent) {
        _toolStatusHideTimer?.cancel();
        _toolStatusHideTimer = null;
        setState(() {
          _isProcessingTool = false;
          _processingToolName = null;
          _toolStatusText = null;
        });
        _appendSystemMessage(event.message);
      }
    });
    _isConnected = widget.controller.isConnected;
    _serverSessionId = widget.controller.sessionId;
  }

  String get _currentSessionId =>
      _serverSessionId ?? widget.sessionId ?? widget.controller.sessionId ?? '';

  void _sendText(String text) {
    final q = text.trim();
    if (q.isEmpty) return;

    _appendUserText(q);
    _showAssistantTyping();

    // If user selected product cards, enrich the question with structured context.
    final lastProductsIndex =
        _messages.lastIndexWhere((m) => m.type == _OverlayMessageType.assistantProducts);
    final lastProducts = lastProductsIndex == -1 ? null : _messages[lastProductsIndex].products;
    final selectedIds = _selectedProductIds.toList();
    selectedIds.sort((a, b) {
      final ai = int.tryParse(a);
      final bi = int.tryParse(b);
      if (ai != null && bi != null) return ai.compareTo(bi);
      return a.compareTo(b);
    });

    final selectedIdsDisplay = selectedIds.map((id) {
      final asInt = int.tryParse(id);
      return asInt != null ? asInt.toString() : '"$id"';
    }).join(', ');

    final effectiveQuestion = (lastProducts != null && selectedIds.isNotEmpty)
        ? [
            'In the shown options,',
            'Follow-up question asked: ${lastProducts.followUpQuestion ?? ''}',
            'User selected: [$selectedIdsDisplay]',
            'Answered as: $q',
          ].join('\n')
        : q;

    widget.controller.sendText(effectiveQuestion);

    if (_selectedProductIds.isNotEmpty) {
      setState(() {
        _selectedProductIds.clear();
      });
    }

    _textController.clear();
    // Keep focus in text mode.
    if (_mode == _InputMode.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _textFocusNode.requestFocus();
      });
    } else {
      _textFocusNode.unfocus();
    }
  }

  void _appendUserText(String text) {
    setState(() {
      _isAgentActive = true;
      _messages.add(_OverlayMessage.userText(text));
      _trimToLast10Turns();
    });
    _scrollToBottom();
  }

  void _appendAssistantText(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    setState(() {
      _isAgentActive = true;
      _isProcessingTool = false;
      _hideAssistantTyping();
      _messages.add(_OverlayMessage.assistantText(t));
      _trimToLast10Turns();
    });
    _scrollToBottom();
  }

  void _appendAssistantProducts(KuralitUiProductsEvent event) {
    if (event.items.isEmpty) return;
    setState(() {
      _isAgentActive = true;
      _isProcessingTool = false;
      _hideAssistantTyping();
      _selectedProductIds.clear();
      _messages.add(_OverlayMessage.assistantProducts(event));
      _trimToLast10Turns();
    });
    _scrollToBottom();
  }

  void _appendSystemMessage(String message) {
    final t = message.trim();
    if (t.isEmpty) return;
    setState(() {
      _hideAssistantTyping();
      _messages.add(_OverlayMessage.system(t));
      _trimToLast10Turns();
    });
    _scrollToBottom();
  }


  void _resetConversationForNewSession() {
    if (!mounted) return;

    _toolStatusHideTimer?.cancel();
    _toolStatusHideTimer = null;

    setState(() {
      _hideAssistantTyping();
      _messages.clear();
      _isProcessingTool = false;
      _processingToolName = null;
      _toolStatusText = null;
      _selectedProductIds.clear();
      _liveSttText = null;
      _isAgentActive = false;
    });

    // Subtle UX: floating toast instead of a red system chip.
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('New conversation'),
        duration: Duration(milliseconds: 900),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showAssistantTyping() {
    setState(() {
      // Ensure only one typing indicator exists at the end.
      _messages.removeWhere((m) => m.type == _OverlayMessageType.assistantTyping);
      _messages.add(_OverlayMessage.assistantTyping());
    });
    _scrollToBottom();
  }

  void _hideAssistantTyping() {
    _messages.removeWhere((m) => m.type == _OverlayMessageType.assistantTyping);
  }

  void _trimToLast10Turns() {
    // Keep last 10 turns. We store user+assistant as individual nodes: cap at 20 nodes.
    const maxNodes = 20;
    // Do not count the typing indicator toward the cap.
    int nonTypingCount() =>
        _messages.where((m) => m.type != _OverlayMessageType.assistantTyping).length;

    while (nonTypingCount() > maxNodes) {
      final idx = _messages.indexWhere(
        (m) => m.type != _OverlayMessageType.assistantTyping,
      );
      if (idx < 0) break;
      _messages.removeAt(idx);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_messagesScrollController.hasClients) return;
      _messagesScrollController.animateTo(
        _messagesScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  void _switchToTextMode() {
    if (_mode == _InputMode.text) return;
    _stopAgent(); // stop recording if any
    setState(() {
      _mode = _InputMode.text;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _textFocusNode.requestFocus();
    });
  }

  void _switchToVoiceMode() {
    if (_mode == _InputMode.voice) return;
    _textFocusNode.unfocus();
    setState(() {
      _mode = _InputMode.voice;
    });
  }

  Future<void> _startAgent() async {
    if (_isRecording) return;
    
    // Ensure voice is primary UI.
    _switchToVoiceMode();

    try {
      await widget.controller.connect();
    } catch (e) {
      debugPrint("Failed to start audio: $e");
      return;
    }

    setState(() {
      _isRecording = true;
      _isAgentActive = true;
      _audioLevel = 0.0;
    });

    HapticFeedback.selectionClick();
    _waveController.repeat(reverse: true);
    
    try {
      await widget.controller.startMic();
    } catch (e) {
      // Error handling is done by the controller
    }
  }

  Future<void> _stopAgent() async {
    if (!_isRecording) return;
    
    HapticFeedback.selectionClick();
    _waveController.stop();
    _waveController.reset();

    setState(() {
      _isRecording = false;
      _audioLevel = 0.0;
      _liveSttText = null;
    });
    await widget.controller.stopMic();
  }

  @override
  void dispose() {
    _stopAgent();
    _textController.dispose();
    _textFocusNode.dispose();
    _eventSubscription?.cancel();
    _waveController.dispose();
    _amplitudeTimer?.cancel();
    _toolStatusHideTimer?.cancel();
    _messagesScrollController.dispose();
    super.dispose();
  }

  void _toggleSelectedProduct(String id) {
    setState(() {
      if (_selectedProductIds.contains(id)) {
        _selectedProductIds.remove(id);
      } else {
        _selectedProductIds.add(id);
      }
    });
    HapticFeedback.selectionClick();
  }

  // --- UI Builders ---

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final screenHeight = MediaQuery.of(context).size.height;
    
    // Level 2 (Assist) vs Level 3 (Focus)
    // If typing, we might want to ensure enough height, but usually keyboard pushes up.
    final targetHeight = _isFocusMode ? screenHeight * 0.92 : screenHeight * 0.55;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
      height: targetHeight,
      decoration: BoxDecoration(
        color: theme.surfaceColor,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(theme.cornerRadius),
          topRight: Radius.circular(theme.cornerRadius),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12), // Darker, more specific shadow
            offset: const Offset(0, -6),           // Top-edge focus
            blurRadius: 24,                        // Soft spread
          ),
        ],
        // Premium touch: Faint white highlight on top
        border: Border(
           top: BorderSide(
              color: Colors.white.withOpacity(0.6), 
              width: 1
           )
        ),
      ),
      child: Stack(
        children: [
           // Optional Glass Gradient at top
           Positioned(
             top: 0, left: 0, right: 0, height: 80,
             child: IgnorePointer(
               child: Container(
                 decoration: BoxDecoration(
                   gradient: LinearGradient(
                     begin: Alignment.topCenter,
                     end: Alignment.bottomCenter,
                     colors: [
                       theme.surfaceColor.withOpacity(0.95),
                       theme.surfaceColor.withOpacity(0.0),
                     ],
                   ),
                   borderRadius: BorderRadius.only(
                     topLeft: Radius.circular(theme.cornerRadius),
                     topRight: Radius.circular(theme.cornerRadius),
                   ),
                 ),
               ),
             ),
           ),

          Column(
            children: [
              // 1. Header (Minimal)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Left: Logo (Subtle)
                    // Configurable via theme
                    if (theme.showLogo)
                      Opacity(
                        opacity: 0.8,
                        child: Row(
                          children: [
                             Icon(Icons.eco, size: 18, color: theme.iconNeutral),
                             const SizedBox(width: 8),
                             Text(
                               "Kuralit",
                               style: TextStyle(
                                 color: theme.textSecondary,
                                 fontWeight: FontWeight.w600,
                                 fontSize: 14,
                               ),
                             ),
                          ],
                        ),
                      )
                    else
               const SizedBox(width: 40),

                    // Center: Grab Handle
                    Expanded(
                      child: Center(
                        child: Container(
                          width: 32, height: 4,
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),

                    // Right: Focus Toggle
                    // Hide while in text mode to reduce clutter.
                    if (_mode == _InputMode.voice)
                      GestureDetector(
                        onTap: () => setState(() => _isFocusMode = !_isFocusMode),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            _isFocusMode ? Icons.unfold_less : Icons.unfold_more,
                            color: theme.iconNeutral.withOpacity(0.8),
                            size: 24,
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 32),
                  ],
                ),
              ),

              // 2. Main Content (Option A: chat history)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: _buildConversation(theme),
                      ),

                      if (_isProcessingTool && _processingToolName != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '${_processingToolName!} • working…',
                            style: TextStyle(
                              color: theme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        )
                      else if (_toolStatusText != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _toolStatusText!,
                            style: TextStyle(
                              color: theme.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        )
                      else
                        const SizedBox(height: 8),

                      // Mic mode transcript (Phase 2): interim text shown live.
                      if (_mode == _InputMode.voice && _liveSttText != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.04),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.black.withOpacity(0.06)),
                          ),
                          child: Text(
                            _liveSttText!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: theme.textPrimary.withOpacity(0.85),
                              fontSize: 13,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ],

                      // Voice visual (only in voice mode)
                      if (_mode == _InputMode.voice) ...[
                        SizedBox(height: _isRecording ? 12 : 6),
                        SizedBox(
                          height: _isRecording ? 48 : 0,
                          child: _isRecording ? _buildWaveform(theme) : null,
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // 3. Bottom Controls (voice-first; text bar only after keyboard tap)
              Padding(
                padding: EdgeInsets.fromLTRB(24, 14, 24, MediaQuery.of(context).padding.bottom + 18),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    final isEnteringText = child.key == const ValueKey('textBar');
                    final begin = isEnteringText ? const Offset(-1.0, 0.0) : const Offset(0.0, 0.0);
                    return SlideTransition(
                      position: Tween<Offset>(begin: begin, end: Offset.zero).animate(animation),
                      child: FadeTransition(opacity: animation, child: child),
                    );
                  },
                  child: _mode == _InputMode.text
                      ? _buildTextInputBar(theme, key: const ValueKey('textBar'))
                      : _buildVoiceControls(theme, key: const ValueKey('voiceControls')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConversation(KuralitTheme theme) {
    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Ask anything',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _mode == _InputMode.voice ? 'Voice is primary. Tap keyboard to type.' : 'Type a question to start',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.textSecondary.withOpacity(0.7),
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _messagesScrollController,
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final m = _messages[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: _buildMessageBubble(theme, m),
        );
      },
    );
  }

  Widget _buildMessageBubble(KuralitTheme theme, _OverlayMessage msg) {
    switch (msg.type) {
      case _OverlayMessageType.userText:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: theme.accentColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.accentColor.withOpacity(0.18)),
            ),
            child: Text(
              msg.text!,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 15,
                height: 1.2,
              ),
            ),
          ),
        );
      case _OverlayMessageType.assistantText:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.black.withOpacity(0.06)),
            ),
            child: Text(
              msg.text!,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 15,
                height: 1.2,
              ),
            ),
          ),
        );
      case _OverlayMessageType.assistantProducts:
        final lastProductsIndex =
            _messages.lastIndexWhere((m) => m.type == _OverlayMessageType.assistantProducts);
        final isActiveProducts =
            lastProductsIndex != -1 && identical(_messages[lastProductsIndex], msg);

        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.03),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.black.withOpacity(0.05)),
            ),
            child: KuralitProductCardsStrip(
              title: msg.products!.title,
              items: msg.products!.items,
              followUpQuestion: msg.products!.followUpQuestion,
              isSelectable: isActiveProducts,
              selectedIds: isActiveProducts ? _selectedProductIds : const <String>{},
              onToggleSelected: isActiveProducts ? _toggleSelectedProduct : null,
            ),
          ),
        );
      case _OverlayMessageType.assistantTyping:
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.04),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.black.withOpacity(0.06)),
            ),
            child: const _TypingDots(),
          ),
        );
      case _OverlayMessageType.system:
        return Align(
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.red.withOpacity(0.18)),
            ),
            child: Text(
              msg.text!,
              style: TextStyle(
                color: Colors.red.shade700,
                fontSize: 12,
              ),
            ),
          ),
        );
    }
  }

  Widget _buildVoiceControls(KuralitTheme theme, {required Key key}) {
    return Row(
      key: key,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        GestureDetector(
          onTap: _switchToTextMode,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.keyboard,
              color: theme.iconNeutral,
              size: 26,
              semanticLabel: "Type message",
            ),
          ),
        ),
        GestureDetector(
          onTap: () {
            if (_isRecording) _stopAgent();
            else _startAgent();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 72,
            width: 72,
            decoration: BoxDecoration(
              color: _isRecording ? theme.accentColor : theme.surfaceColor,
              shape: BoxShape.circle,
              border: Border.all(
                color: _isRecording ? Colors.transparent : theme.dividerColor,
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: _isRecording
                      ? theme.accentColor.withOpacity(0.3)
                      : Colors.black.withOpacity(0.05),
                  blurRadius: _isRecording ? 20 : 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(
              _isRecording ? Icons.mic : Icons.mic_none,
              size: 32,
              color: _isRecording ? Colors.white : theme.textPrimary,
            ),
          ),
        ),
        SizedBox(
          width: 48,
          child: IconButton(
            icon: Icon(Icons.keyboard_arrow_down, color: theme.iconNeutral, size: 32),
            onPressed: () {
              _stopAgent();
              Navigator.of(context).pop();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTextInputBar(KuralitTheme theme, {required Key key}) {
    return Row(
      key: key,
      children: [
        // Separate mic button (left of the bar) for switching back to voice.
        _CircleActionButton(
          icon: Icons.mic_none_rounded,
          iconColor: theme.iconNeutral,
          tooltip: 'Switch to voice',
          onTap: () async {
            // Switch back to voice UI and start a fresh backend session.
            _switchToVoiceMode();
            if (widget.controller is KuralitWebSocketController) {
              await (widget.controller as KuralitWebSocketController).startNewSession();
              _resetConversationForNewSession();
            } else {
              await widget.controller.connect();
            }
          },
        ),
        const SizedBox(width: 12),

        // Input bar
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.black.withOpacity(0.06)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: TextField(
              controller: _textController,
              focusNode: _textFocusNode,
              decoration: InputDecoration(
                hintText: 'Type your question',
                hintStyle: TextStyle(color: theme.textSecondary.withOpacity(0.6)),
                border: InputBorder.none,
                isDense: true,
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: _sendText,
            ),
          ),
        ),
        const SizedBox(width: 12),

        // Send button (separate, right of bar)
        _CircleActionButton(
          icon: Icons.send_rounded,
          iconColor: theme.accentColor,
          tooltip: 'Send',
          onTap: () => _sendText(_textController.text),
        ),

        const SizedBox(width: 10),

        // Dismiss chevron (far right)
        IconButton(
          icon: Icon(Icons.keyboard_arrow_down, color: theme.iconNeutral),
          onPressed: () {
            _stopAgent();
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  Widget _buildWaveform(KuralitTheme theme) {
     final level = _audioLevel.clamp(0.0, 1.0);
     return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(5, (index) {
           return AnimatedBuilder(
             animation: _waveController,
             builder: (context, child) {
                // Use real mic level + a gentle animation so it feels alive.
                final phase = index * 0.9;
                final pulse = (math.sin((_waveController.value * math.pi * 2) + phase) * 0.5 + 0.5);
                final base = 6.0;
                final amp = 6.0 + (28.0 * level);
                final height = base + amp * (0.30 + 0.70 * pulse);
                
                return AnimatedContainer(
                   duration: const Duration(milliseconds: 120),
                   width: 5,
                   height: height.clamp(5, 40),
                   margin: const EdgeInsets.symmetric(horizontal: 4),
                   decoration: BoxDecoration(
                     color: theme.accentColor.withOpacity(0.8),
                     borderRadius: BorderRadius.circular(10),
                   ),
                );
             },
           );
        }),
     );
  }
}

enum _InputMode { voice, text }

enum _OverlayMessageType {
  userText,
  assistantText,
  assistantProducts,
  assistantTyping,
  system,
}

class _OverlayMessage {
  final _OverlayMessageType type;
  final String? text;
  final KuralitUiProductsEvent? products;

  const _OverlayMessage._({
    required this.type,
    this.text,
    this.products,
  });

  factory _OverlayMessage.userText(String text) =>
      _OverlayMessage._(type: _OverlayMessageType.userText, text: text);

  factory _OverlayMessage.assistantText(String text) =>
      _OverlayMessage._(type: _OverlayMessageType.assistantText, text: text);

  factory _OverlayMessage.assistantProducts(KuralitUiProductsEvent products) =>
      _OverlayMessage._(type: _OverlayMessageType.assistantProducts, products: products);

  factory _OverlayMessage.assistantTyping() =>
      const _OverlayMessage._(type: _OverlayMessageType.assistantTyping);

  factory _OverlayMessage.system(String text) =>
      _OverlayMessage._(type: _OverlayMessageType.system, text: text);
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value; // 0..1
        int active = (t * 3).floor() % 3;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final opacity = i == active ? 1.0 : 0.35;
            return Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(opacity),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}

class _CircleActionButton extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String? tooltip;
  final VoidCallback onTap;

  const _CircleActionButton({
    required this.icon,
    required this.iconColor,
    required this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black.withOpacity(0.06)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Icon(icon, color: iconColor, size: 24),
      ),
    );

    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}
