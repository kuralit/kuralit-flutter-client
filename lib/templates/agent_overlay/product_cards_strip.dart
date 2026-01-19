import 'package:flutter/material.dart';

import '../../src/models/kuralit_product.dart';

class KuralitProductCardsStrip extends StatelessWidget {
  final String? title;
  final List<KuralitProduct> items;
  final String? followUpQuestion;
  final Set<String> selectedIds;
  final ValueChanged<String>? onToggleSelected;
  final bool isSelectable;

  const KuralitProductCardsStrip({
    super.key,
    required this.items,
    this.title,
    this.followUpQuestion,
    this.selectedIds = const <String>{},
    this.onToggleSelected,
    this.isSelectable = false,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null) ...[
          Text(
            title!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          height: 182,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final p = items[index];
              final selected = selectedIds.contains(p.id);
              return _ProductCard(
                product: p,
                isSelected: selected,
                isSelectable: isSelectable,
                onTap: onToggleSelected == null ? null : () => onToggleSelected!(p.id),
              );
            },
          ),
        ),
        if (followUpQuestion != null) ...[
          const SizedBox(height: 12),
          Text(
            followUpQuestion!,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.7),
            ),
          ),
        ],
      ],
    );
  }
}

class _ProductCard extends StatelessWidget {
  final KuralitProduct product;
  final bool isSelected;
  final bool isSelectable;
  final VoidCallback? onTap;

  const _ProductCard({
    required this.product,
    required this.isSelected,
    required this.isSelectable,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isSelected ? Colors.green.shade600 : Colors.black.withOpacity(0.08);
    final bg = isSelected ? Colors.green.withOpacity(0.06) : Colors.white;

    return Semantics(
      button: isSelectable,
      selected: isSelected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isSelectable ? onTap : null,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            width: 156,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor, width: isSelected ? 1.4 : 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.06),
                  blurRadius: 10,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 104,
                        child: product.imageUrl == null
                            ? Container(
                                color: Colors.grey.shade200,
                                child: const Icon(Icons.image_not_supported_outlined, size: 28),
                              )
                            : Image.network(
                                product.imageUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stack) {
                                  return Container(
                                    color: Colors.grey.shade200,
                                    child: const Icon(Icons.broken_image_outlined, size: 28),
                                  );
                                },
                                loadingBuilder: (context, child, progress) {
                                  if (progress == null) return child;
                                  return Container(
                                    color: Colors.grey.shade100,
                                    child: const Center(
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    ),
                                  );
                                },
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              product.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.15,
                              ),
                            ),
                            const SizedBox(height: 6),
                            if (product.price != null)
                              Text(
                                '₹ ${product.price!.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.green.shade700,
                                ),
                              )
                            else
                              Text(
                                'Price unavailable',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  if (isSelectable)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: isSelected ? Colors.green.shade600 : Colors.white.withOpacity(0.85),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected ? Colors.green.shade600 : Colors.black.withOpacity(0.12),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.10),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Icon(
                          isSelected ? Icons.check : Icons.add,
                          size: 14,
                          color: isSelected ? Colors.white : Colors.black.withOpacity(0.55),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


