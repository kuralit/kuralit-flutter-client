import 'package:flutter/material.dart';

import 'kuralit_ui_controller.dart';

/// Base class for all Kuralit templates
/// 
/// Provides a common interface for template widgets that can be
/// used with the Kuralit UI-only controller (no backend code).
abstract class KuralitBaseTemplate extends StatefulWidget {
  /// Controller implemented by the host app.
  final KuralitUiController controller;

  /// Optional session ID for this template instance.
  /// If null, templates may use [controller.sessionId] when needed.
  final String? sessionId;

  const KuralitBaseTemplate({
    Key? key,
    required this.controller,
    this.sessionId,
  }) : super(key: key);
}



