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

  const BillThumbnail({super.key, required this.sourceImage, this.failed = false});

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
      return await ApiClient.instance.fetchImage(path);
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
        return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
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
