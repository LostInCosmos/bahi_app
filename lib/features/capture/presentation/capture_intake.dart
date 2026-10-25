part of 'capture_screen.dart';

/// Getting bills in: the camera, the gallery, a PDF rendered to pages
/// (DAS-27), cropping, and the upload that hands each bill to the server.
/// Reading it from there is [_Watching]'s job.
///
/// It needs five things from the screen, declared here so the dependency is
/// written down rather than reached for.
mixin _Intake on State<CaptureScreen> {
  List<BatchItem> get _items;
  FolderController get _folders;
  BatchStore? get _store;
  Future<void> _persistBatch();
  Future<void> _processOne(BatchItem item);

  /// Non-null while a PDF is being rendered (DAS-27).
  String? _pdfProgress;

  /// Several bills picked from the gallery at once (DAS-25).
  ///
  /// Each becomes an ordinary bill straight away — saved here, shown on
  /// the grid, waiting for its corners. No separate tray and no second
  /// kind of record, so folders, filtering, persistence and resume all
  /// work on them without knowing they arrived in a batch.
  ///
  /// Nothing is uploaded yet: the shopkeeper taps one, chooses its
  /// corners, and only then does it go to preprocessing.
  ///
  /// The camera stays one at a time. A camera cannot multi-select
  /// anyway, and someone photographing a single bill sees no change.
  Future<void> _pickManyFromGallery() async {
    final tenantId = _store?.tenantId;
    // Fixed now, as in _addPhoto: the folder you were in when you picked
    // is the one these bills belong to.
    final folderId = _folders.currentId;
    final files = await ImagePicker().pickMultiImage(imageQuality: 95);
    if (files.isEmpty || !mounted) return;

    // One file is the old single-bill flow, unchanged — straight to the
    // crop rather than onto the grid.
    if (files.length == 1) {
      await _addPickedFile(files.first, folderId);
      return;
    }

    final made = <BatchItem>[];
    for (final file in files) {
      final bytes = await file.readAsBytes();
      // Written to the device as it is picked, before any cropping:
      // these bytes exist nowhere else.
      final photoId = tenantId == null
          ? null
          : await PendingPhotoStore.save(tenantId, bytes);
      made.add(BatchItem(
        label: 'Photo ${_items.length + made.length + 1}',
        pages: [
          BatchItemPage(
            photoId: photoId,
            memoryBytes: photoId == null ? bytes : null,
            filename: file.name,
            corners: const [], // chosen when the shopkeeper crops it
            rotationDegrees: 0,
          )
        ],
      )
        ..status = BatchItemStatus.needsCrop
        ..folderId = folderId);
    }
    if (!mounted) return;
    setState(() => _items.addAll(made));
    // Recorded before anything else, so being killed keeps the stack.
    await _persistBatch();
  }

  /// One file from the gallery: the original single-bill flow, kept
  /// exactly as it was so nothing changes for someone uploading one
  /// bill. Crop first, then save, then upload.
  Future<void> _addPickedFile(XFile file, int? folderId) async {
    final tenantId = _store?.tenantId;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final crop = await Navigator.of(context).push<CropResult>(
      MaterialPageRoute(
          builder: (_) => CropScreen(imageBytes: bytes, pageNumber: 1)),
    );
    if (crop == null || crop.corners.length != 4 || !mounted) return;

    final photoId =
        tenantId == null ? null : await PendingPhotoStore.save(tenantId, bytes);
    final item = BatchItem(label: 'Photo ${_items.length + 1}', pages: [
      BatchItemPage(
        photoId: photoId,
        memoryBytes: photoId == null ? bytes : null,
        filename: file.name,
        corners: crop.corners.map((o) => Offset2D(o.dx, o.dy)).toList(),
        rotationDegrees: crop.rotationDegrees,
      )
    ])
      ..folderId = folderId;
    if (!mounted) return;
    setState(() => _items.add(item));
    await _persistBatch();
    await _uploadAndExtract(item);
  }

  /// A PDF bill (DAS-27).
  ///
  /// Rendered to page images here, then sent straight on — NO crop
  /// screen. A PDF page is already flat and rectangular; there is
  /// nothing to drag corners around, and asking would be busywork.
  ///
  /// One document becomes ONE bill with N pages, which is what the
  /// extractor's multi-page path is for: every page reaches the model
  /// in a single call, so totals that continue across a page break are
  /// read together. Whether a document might be several separate
  /// invoices is the open question on DAS-27 — silently guessing would
  /// be worse than defaulting to one.
  Future<void> _pickPdf() async {
    final tenantId = _store?.tenantId;
    final folderId = _folders.currentId;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;

    final name = picked!.files.single.name;
    setState(() => _pdfProgress = 'Reading $name…');
    try {
      final rendered = await renderPdf(
        path,
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _pdfProgress = 'Reading $name — page $done of $total');
          }
        },
      );
      if (rendered.isEmpty || !mounted) return;

      final pages = <BatchItemPage>[];
      for (var i = 0; i < rendered.length; i++) {
        final r = rendered[i];
        final photoId = tenantId == null
            ? null
            : await PendingPhotoStore.save(tenantId, r.bytes);
        pages.add(BatchItemPage(
          photoId: photoId,
          memoryBytes: photoId == null ? r.bytes : null,
          filename:
              '${name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '')}-p${i + 1}.jpg',
          // The whole page. A rendered PDF page needs no crop, and
          // anything less would cut the bill's edges off.
          corners: [
            const Offset2D(0, 0),
            Offset2D(r.width, 0),
            Offset2D(r.width, r.height),
            Offset2D(0, r.height),
          ],
          rotationDegrees: 0,
        ));
      }
      if (!mounted) return;
      final item = BatchItem(label: name, pages: pages)..folderId = folderId;
      setState(() {
        _items.add(item);
        _pdfProgress = null;
      });
      await _persistBatch();
      await _uploadAndExtract(item);
    } catch (e) {
      if (!mounted) return;
      // A page cap or an unreadable file is the shopkeeper's problem to
      // act on, not a silent no-op that looks like the app ignored them.
      setState(() => _pdfProgress = null);
      context.say(e is TooManyPdfPages ? e.toString() : 'Could not read $name');
    }
  }

  /// Open the crop for a bill picked from the gallery and still waiting.
  ///
  /// The bill already exists and its photo is already on disk, so this
  /// only fills in the corners and starts the work — it must not write
  /// a second copy of the photo.
  Future<void> _cropPending(BatchItem item) async {
    final page = item.pages.first;
    final bytes = page.memoryBytes ??
        (page.photoId == null
            ? null
            : await PendingPhotoStore.read(page.photoId!));
    if (!mounted) return;
    if (bytes == null) {
      setState(() => item.markFailed('that photo is no longer on this device'));
      await _persistBatch();
      return;
    }
    final crop = await Navigator.of(context).push<CropResult>(
      MaterialPageRoute(
          builder: (_) => CropScreen(imageBytes: bytes, pageNumber: 1)),
    );
    if (crop == null || crop.corners.length != 4 || !mounted) return;
    setState(() {
      item.pages[0] = BatchItemPage(
        photoId: page.photoId,
        memoryBytes: page.memoryBytes,
        filename: page.filename,
        corners: crop.corners.map((o) => Offset2D(o.dx, o.dy)).toList(),
        rotationDegrees: crop.rotationDegrees,
      );
      item.status = BatchItemStatus.preparing;
    });
    await _persistBatch();
    await _uploadAndExtract(item);
  }

  /// Captures one or more photos for a single bill: after each crop, the user
  /// can finish or tap "+ Add another page" to add pages to the SAME bill.
  /// Each photo is written to the device as soon as its crop is confirmed.
  Future<void> _addPhoto(ImageSource source) async {
    final tenantId = _store?.tenantId;
    // Fixed now, not when the photo is done: the folder you were in when you
    // tapped capture is the one the bill belongs to.
    final folderId = _folders.currentId;
    final pages = <BatchItemPage>[];
    while (true) {
      final file =
          await ImagePicker().pickImage(source: source, imageQuality: 95);
      if (file == null) {
        if (pages.isEmpty) return;
        break; // cancelled a continuation page — keep what's already queued
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;

      final cropResult = await Navigator.of(context).push<CropResult>(
        MaterialPageRoute(
            builder: (_) =>
                CropScreen(imageBytes: bytes, pageNumber: pages.length + 1)),
      );
      if (cropResult == null || cropResult.corners.length != 4) {
        if (pages.isEmpty) return;
        break;
      }

      final photoId = tenantId == null
          ? null
          : await PendingPhotoStore.save(tenantId, bytes);
      pages.add(BatchItemPage(
        photoId: photoId,
        // Kept in memory only if the disk write failed — this page then
        // can't survive a restart, exactly as before photos were saved.
        memoryBytes: photoId == null ? bytes : null,
        filename: file.name,
        corners: cropResult.corners.map((o) => Offset2D(o.dx, o.dy)).toList(),
        rotationDegrees: cropResult.rotationDegrees,
      ));

      if (!cropResult.addAnotherPage) break;
    }
    if (!mounted) return;

    final item = BatchItem(label: 'Photo ${_items.length + 1}', pages: pages)
      ..folderId = folderId;
    setState(() => _items.add(item));
    // Recorded before the upload starts, so a logout mid-upload still finds
    // this bill next time.
    await _persistBatch();
    await _uploadAndExtract(item);
  }

  /// Uploads the bill's photos, then starts extraction without waiting for
  /// it — so the add buttons are free again immediately.
  Future<void> _uploadAndExtract(BatchItem item) async {
    await _uploadItem(item);
    // Not for a bill discarded while its photos were going up (DAS-115).
    if (mounted && item.status == BatchItemStatus.ready && _items.contains(item)) {
      unawaited(_processOne(item));
    }
  }

  Future<void> _uploadItem(BatchItem item) async {
    setState(() => item.status = BatchItemStatus.preparing);
    final List<String> sourceImages;
    try {
      sourceImages = [];
      for (final page in item.pages) {
        final bytes = await page.loadBytes();
        if (bytes == null) {
          throw StateError(
              'This photo is no longer on the device — please delete it and capture the bill again.');
        }
        sourceImages.add(await ApiClient.instance.preprocess(
          imageBytes: bytes,
          filename: page.filename,
          corners: page.corners,
          rotationDegrees: page.rotationDegrees,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => item.markFailed('Upload failed: $e'));
      await _persistBatch();
      return;
    }
    // A screen disposed mid-upload leaves its photos on the device for the
    // next screen to upload again, rather than recording a result it can no
    // longer show.
    if (!mounted) return;

    final uploadedPages = item.pages;
    setState(() {
      item.sourceImages = sourceImages;
      item.pages = [];
      item.status = BatchItemStatus.ready;
      item.errorMessage = null;
    });
    // Save the server paths BEFORE deleting the local photos: a kill in
    // between leaves an orphan file (swept on next start), never a bill with
    // neither its photo nor its upload.
    await _persistBatch();
    for (final page in uploadedPages) {
      final id = page.photoId;
      if (id != null) await PendingPhotoStore.delete(id);
    }
  }
}
