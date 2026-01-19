class KuralitProduct {
  final String id;
  final String title;
  final double? price;
  final String? imageUrl;

  const KuralitProduct({
    required this.id,
    required this.title,
    this.price,
    this.imageUrl,
  });

  static KuralitProduct? fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    final rawTitle = json['title'];
    if (rawId == null || rawTitle is! String || rawTitle.trim().isEmpty) {
      return null;
    }

    final id = rawId.toString();
    final title = rawTitle.trim();

    final rawPrice = json['price'];
    double? price;
    if (rawPrice is num) {
      price = rawPrice.toDouble();
    } else if (rawPrice is String) {
      price = double.tryParse(rawPrice);
    }

    final rawImage = json['image'];
    final imageUrl = rawImage is String && rawImage.trim().isNotEmpty ? rawImage.trim() : null;

    return KuralitProduct(id: id, title: title, price: price, imageUrl: imageUrl);
  }
}


