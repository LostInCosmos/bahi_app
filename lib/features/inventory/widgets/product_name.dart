import 'package:flutter/material.dart';

/// A product's name, with what tells it from the shop's other products of the
/// same name after it in a quieter colour — `PROMINENT CHARCOAL · 60GM`.
/// With no [qualifier] (the common case) it is a plain [Text] of the name:
/// `ProductIndex.qualifier(id)` supplies it only for a shared name.
class ProductName extends StatelessWidget {
  final String name;
  final String? qualifier;
  final TextStyle? style;
  final TextOverflow? overflow;
  final int? maxLines;

  const ProductName(this.name, {super.key, this.qualifier, this.style, this.overflow, this.maxLines});

  @override
  Widget build(BuildContext context) {
    final q = qualifier;
    if (q == null) return Text(name, style: style, overflow: overflow, maxLines: maxLines);
    final base = style ?? DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        text: name,
        children: [
          TextSpan(
            text: ' · $q',
            style: base.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
      style: style,
      overflow: overflow,
      maxLines: maxLines,
    );
  }
}
