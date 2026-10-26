import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/api/api_client.dart';
import '../../invoice/data/invoice_api.dart';

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
/// The width asked of the server for a card's picture (DAS-105): a card is a
/// third of the screen, ~130 logical px, so 640 covers a 3× phone with room
/// to spare and is a tenth of the original's bytes. The server snaps to
/// 320/640/1280, so this must be one of those.
const kThumbnailWidth = 640;

class BillThumbnail extends StatefulWidget {
  /// Null while the bill is still uploading and has no server path yet.
  final String? sourceImage;

  /// Bumped when the admin rotates this bill's photo (DAS-72) — passed to
  /// the default loader so a rotated bill is refetched instead of showing
  /// the stale cached copy. See ApiClient.fetchImage.
  final int imageRev;

  /// The bill itself failed, so a missing picture is not the interesting
  /// part — show the broken state immediately rather than a spinner.
  final bool failed;

  /// How to get the bytes. Defaults to the real client; injectable so the
  /// widget can be tested without a network. Takes only the path — a custom
  /// loader (tests) has no need of [imageRev].
  final Future<Uint8List> Function(String path)? loader;

  /// The photo on this phone, for a bill that has no server path because it
  /// is waiting for the shopkeeper (to be cropped, or a multi-page bill not
  /// sent yet, DAS-131): shown instead of a spinner that would say "busy".
  final Future<Uint8List?> Function()? localPhoto;

  const BillThumbnail({
    super.key,
    required this.sourceImage,
    this.imageRev = 0,
    this.failed = false,
    this.loader,
    this.localPhoto,
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
    // A re-crop writes a new server path; a rotation bumps imageRev instead
    // of the path. Either makes the old picture stale.
    if (old.sourceImage != widget.sourceImage || old.imageRev != widget.imageRev) _start();
  }

  void _start() {
    final path = widget.sourceImage;
    final local = widget.localPhoto;
    _load = path != null ? _fetch(path) : (local == null ? null : _readLocal(local));
  }

  Future<Uint8List?> _readLocal(Future<Uint8List?> Function() read) async {
    try {
      return await read();
    } catch (_) {
      return null;
    }
  }

  /// Never throws: a missing picture is shown as one, and must not take the
  /// card — or the bill — down with it.
  Future<Uint8List?> _fetch(String path) async {
    try {
      final loader = widget.loader;
      if (loader != null) return await loader(path);
      return await ApiClient.instance.fetchImage(path, imageRev: widget.imageRev, width: kThumbnailWidth);
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
