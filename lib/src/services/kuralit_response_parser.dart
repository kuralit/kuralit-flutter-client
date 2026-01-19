import '../../templates/kuralit_ui_controller.dart';
import '../models/kuralit_product.dart';

/// Parses a server `response` message and returns a typed UI event.
///
/// Supports:
/// - Plain text: `data.text`
/// - Product entity: `data.entity_type == "product"`
KuralitUiEvent? parseKuralitResponseMessage(Map<String, dynamic> msg) {
  final data = msg['data'];
  if (data is! Map) return null;

  final d = data.cast<String, dynamic>();

  final text = d['text'];
  if (text is String && text.trim().isNotEmpty) {
    return KuralitUiTextEvent(text.trim(), isPartial: false);
  }

  final entityType = d['entity_type'];
  if (entityType == 'product') {
    final rawItems = d['items'];
    final items = <KuralitProduct>[];
    if (rawItems is List) {
      for (final it in rawItems) {
        if (it is Map) {
          final p = KuralitProduct.fromJson(it.cast<String, dynamic>());
          if (p != null) items.add(p);
        }
      }
    }

    if (items.isEmpty) return null;

    final rawTitle = d['title'];
    final title =
        rawTitle is String && rawTitle.trim().isNotEmpty ? rawTitle.trim() : null;

    final rawFollowUp = d['follow_up_question'];
    final followUp = rawFollowUp is String && rawFollowUp.trim().isNotEmpty
        ? rawFollowUp.trim()
        : null;

    return KuralitUiProductsEvent(
      title: title,
      items: items,
      followUpQuestion: followUp,
    );
  }

  return null;
}


