import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';

/// One bill's picture, loaded when the card is actually on screen.
///
/// Every bill used to keep its decoded photo on its `BatchItem` for as long
/// as the batch existed, and a restore fetched all of them at once. At a few
/// hundred bills that is the phone's memory gone, for pictures nobody is
/// looking at. `GridView` only builds visible cards, so loading here means
/// only those hold image data and Flutter's own `ImageCache` evicts the rest.
///
/// `ApiClient.fetchImage` serves from the on-device cache first, so scrolling
/// back to a bill is a disk read, not a download.
class BillThumbnail extends StatefulWidget {
  /// Null while the bill is still uploading and has no server path yet.
  final String? sourceImage;

  /// The bill itself failed, so a missing picture is not the interesting
  /// part — show the broken state immediately rather than a spinner.
  final bool failed;

  /// How to get the bytes. Defaults to the real client; injectable so the
  /// widget can be tested without a network.
  final Future<Uint8List> Function(String path)? loader;

  const BillThumbnail({
    super.key,
    required this.sourceImage,
    this.failed = false,
    this.loader,
  });

  @override
  State<BillThumbnail> createState() => _BillThumbnailState();
}

class _BillThumbnailState extends State<BillThumbnail> {
  Future<Uint8List?>? _load;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(BillThumbnail old) {
    super.didUpdateWidget(old);
    // A re-crop writes a new server path, so the old picture is stale.
    if (old.sourceImage != widget.sourceImage) _start();
  }

  void _start() {
    final path = widget.sourceImage;
    _load = path == null ? null : _fetch(path);
  }

  /// Never throws: a missing picture is shown as one, and must not take the
  /// card — or the bill — down with it.
  Future<Uint8List?> _fetch(String path) async {
    try {
      final load = widget.loader ?? ApiClient.instance.fetchImage;
      return await load(path);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _load;
    if (pending == null) {
      return widget.failed ? const _Broken() : const _Loading();
    }
    return FutureBuilder<Uint8List?>(
      future: pending,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return widget.failed ? const _Broken() : const _Loading();
        }
        final bytes = snap.data;
        if (bytes == null) return const _Broken();
        return LayoutBuilder(
          builder: (context, constraints) => Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            // Decode at the size actually drawn, not the size photographed.
            // A bill is ~1715x1927, which decodes to ~12.6 MB of bitmap;
            // `fit` only scales at paint time, so without this every visible
            // card holds a full-resolution image. Flutter's ImageCache caps
            // at ~100 MB, so a 3-across grid of them does not grow without
            // bound — it thrashes, evicting and re-decoding while you scroll.
            // At card size the same image is ~0.7 MB.
            //
            // `cacheWidth` never upscales, so a small image is untouched.
            cacheWidth: _decodeWidth(context, constraints),
          ),
        );
      },
    );
  }
}

/// Physical pixels across the card, or null when the width is unbounded and
/// there is nothing sensible to size against.
int? _decodeWidth(BuildContext context, BoxConstraints constraints) {
  final width = constraints.maxWidth;
  if (!width.isFinite || width <= 0) return null;
  return (width * MediaQuery.devicePixelRatioOf(context)).round();
}


class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Center(child: CircularProgressIndicator());
}

class _Broken extends StatelessWidget {
  const _Broken();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Icon(Icons.broken_image_outlined, size: 32, color: Colors.grey));
}
