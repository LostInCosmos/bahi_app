import 'package:flutter/material.dart';

/// A lazy list whose top part (a search box and its filters) floats: it
/// leaves with the list as it scrolls down and comes back the moment it
/// scrolls up, so the rows get the screen (a third of it with the keyboard
/// up) and the search is one flick away (the user, 2026-11-13). Used by
/// Inventory and Sell.
///
/// [floating] is the floating part; [itemCount] / [itemBuilder] are the rest,
/// built as they scroll into view.
class FloatingHeaderList extends StatelessWidget {
  final List<Widget> floating;
  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;

  /// Around the whole list; the floating part takes the top and sides.
  final EdgeInsets padding;

  const FloatingHeaderList({
    super.key,
    required this.floating,
    required this.itemCount,
    required this.itemBuilder,
    required this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverFloatingHeader(
          snapMode: FloatingHeaderSnapMode.scroll,
          child: ColoredBox(
            // Opaque, so rows do not show through it as it comes back.
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Padding(
              padding: EdgeInsets.fromLTRB(padding.left, padding.top, padding.right, 0),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: floating),
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, padding.bottom),
          sliver: SliverList.builder(itemCount: itemCount, itemBuilder: itemBuilder),
        ),
      ],
    );
  }
}
