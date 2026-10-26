part of 'capture_screen.dart';

/// Getting bills in: the camera, the gallery, a PDF rendered to pages
/// (DAS-27), cropping, and the upload that hands each bill to the server.
/// Reading it from there is [_Watching]'s job.
///
/// It needs six things from the screen, declared here so the dependency is
/// written down rather than reached for.
mixin _Intake on State<CaptureScreen> {
  List<BatchItem> get _items;
  FolderController get _folders;
  BatchStore? get _store;
  Future<void> _persistBatch();
  Future<void> _processOne(BatchItem item);
  void _dropLocal(BatchItem item);

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
    // Fixed now, as in _addPhoto: the folder you were in when you picked
    // is the one these bills belong to.
    final folderId = _folders.currentId;
    final files = await ImagePicker().pickMultiImage(imageQuality: 95);
    if (files.isEmpty || !mounted) return;
    await _addPickedFiles(files, folderId);
  }

  /// Photos from the gallery, or recovered after Android took the app away
  /// (DAS-131). One file goes straight to the crop; several land on the grid
  /// waiting for their corners.
  Future<void> _addPickedFiles(List<XFile> files, int? folderId) async {
    final tenantId = _store?.tenantId;
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

  /// A photo the shopkeeper took while Android killed this app (DAS-131).
  ///
  /// On a phone short of memory the OS may end the app while the camera app
  /// is in front; the camera plugin keeps the photo, but it "is never
  /// returned to the original call" (its README) — it has to be asked for
  /// when the app starts again. Without this the shopkeeper took a photo
  /// and saw nothing happen. iOS never loses one this way and answers empty.
  /// Runs after the batch is restored, so the photo lands beside it, in the
  /// folder the screen opened in.
  Future<void> _recoverLostPhotos() async {
    if (!mounted || _store == null) return;
    final LostDataResponse lost;
    try {
      lost = await debugRetrieveLostData();
    } catch (_) {
      return; // no plugin (a test, a desktop build): nothing to recover
    }
    if (!mounted || lost.isEmpty) return;
    final files = lost.files;
    // Ended while photographing the next page of a bill (DAS-131): the photo
    // is that page, so it joins the unsent bill instead of starting another.
    final drafts = _items.where((i) => i.draft).toList();
    if (files != null && files.length == 1 && drafts.isNotEmpty) {
      context.say('Recovered the page you took before the app closed.');
      await _addRecoveredPage(drafts.last, files.single);
    } else if (files != null && files.isNotEmpty) {
      context.say(files.length == 1
          ? 'Recovered the photo you took before the app closed.'
          : 'Recovered ${files.length} photos picked before the app closed.');
      await _addPickedFiles(files, _folders.currentId);
    } else if (lost.exception != null) {
      context.say('The photo taken before the app closed could not be recovered.');
    }
  }

  /// A recovered photo as the next page of [draft]: crop it, add it, then
  /// ask what to do with the bill (Add another page, Send, Discard).
  Future<void> _addRecoveredPage(BatchItem draft, XFile file) async {
    final tenantId = _store?.tenantId;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final crop = await Navigator.of(context).push<CropResult>(
      MaterialPageRoute(
          builder: (_) => CropScreen(imageBytes: bytes, pageNumber: draft.pages.length + 1)),
    );
    if (crop != null && crop.corners.length == 4 && mounted) {
      final photoId = tenantId == null ? null : await PendingPhotoStore.save(tenantId, bytes);
      if (!mounted) return;
      setState(() => draft.pages.add(BatchItemPage(
            photoId: photoId,
            memoryBytes: photoId == null ? bytes : null,
            filename: file.name,
            corners: crop.corners.map((o) => Offset2D(o.dx, o.dy)).toList(),
            rotationDegrees: crop.rotationDegrees,
          )));
      await _persistBatch();
      if (!crop.addAnotherPage) {
        await _sendDraft(draft);
        return;
      }
      await _addPhoto(ImageSource.camera, into: draft);
    }
    if (mounted && draft.draft && _items.contains(draft)) await _openDraft(draft);
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

  /// Captures one or more photos for a single bill: after each crop, the
  /// shopkeeper can finish or tap "+ Add another page" to add pages to the
  /// SAME bill.
  ///
  /// The bill is in the batch from its first page (DAS-131), as a draft:
  /// every page is written to the device and the batch saved as its crop is
  /// confirmed, so Android ending the app while the camera is in front loses
  /// nothing taken so far. It goes to the server only on "Confirm bill";
  /// leaving the camera or the crop mid-bill keeps it as a card that says
  /// "N pages · not sent" ([_openDraft]). [into] continues such a bill.
  Future<void> _addPhoto(ImageSource source, {BatchItem? into}) async {
    final tenantId = _store?.tenantId;
    // Fixed now, not when the photo is done: the folder you were in when you
    // tapped capture is the one the bill belongs to.
    final folderId = into?.folderId ?? _folders.currentId;
    var item = into;
    while (true) {
      final file =
          await ImagePicker().pickImage(source: source, imageQuality: 95);
      if (file == null) break; // left the camera: whatever was taken is kept
      final bytes = await file.readAsBytes();
      if (!mounted) return;

      final cropResult = await Navigator.of(context).push<CropResult>(
        MaterialPageRoute(
            builder: (_) => CropScreen(
                imageBytes: bytes, pageNumber: (item?.pages.length ?? 0) + 1)),
      );
      if (cropResult == null || cropResult.corners.length != 4) break;

      final photoId = tenantId == null
          ? null
          : await PendingPhotoStore.save(tenantId, bytes);
      final page = BatchItemPage(
        photoId: photoId,
        // Kept in memory only if the disk write failed — this page then
        // can't survive a restart, exactly as before photos were saved.
        memoryBytes: photoId == null ? bytes : null,
        filename: file.name,
        corners: cropResult.corners.map((o) => Offset2D(o.dx, o.dy)).toList(),
        rotationDegrees: cropResult.rotationDegrees,
      );
      if (!mounted) return;
      final current = item;
      if (current == null) {
        final created = BatchItem(label: 'Photo ${_items.length + 1}', pages: [page])
          ..folderId = folderId
          ..status = BatchItemStatus.needsCrop
          ..draft = true;
        item = created;
        setState(() => _items.add(created));
      } else {
        setState(() => current.pages.add(page));
      }
      // Recorded before the next page is taken, so a kill keeps this one.
      await _persistBatch();

      if (!cropResult.addAnotherPage) {
        await _sendDraft(item!);
        return;
      }
    }
  }

  /// "Confirm bill": the draft goes to the server like any new bill.
  Future<void> _sendDraft(BatchItem item) async {
    if (!mounted) return;
    setState(() {
      item.draft = false;
      item.status = BatchItemStatus.preparing;
    });
    await _persistBatch();
    await _uploadAndExtract(item);
  }

  /// A multi-page bill not sent yet (DAS-131): the shopkeeper left the
  /// camera mid-bill, or Android ended the app. Add a page, send what is
  /// there, or discard it.
  Future<void> _openDraft(BatchItem item) async {
    final n = item.pages.length;
    final action = await showDialog<_DraftAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('This bill has ${plural(n, 'page')}'),
        content: const Text('It has not been sent yet.'),
        actionsAlignment: MainAxisAlignment.center,
        actionsOverflowDirection: VerticalDirection.down,
        actions: [
          OutlinedButton.icon(
            onPressed: () => Navigator.of(ctx).pop(_DraftAction.addPage),
            icon: const Icon(Icons.note_add_outlined),
            label: const Text('+ Add another page'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(_DraftAction.send),
            child: Text('Send ${plural(n, 'page')}'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_DraftAction.discard),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _DraftAction.addPage:
        await _addPhoto(ImageSource.camera, into: item);
        // Back to the same question with the new page count, unless the
        // last crop sent it.
        if (mounted && item.draft && _items.contains(item)) await _openDraft(item);
      case _DraftAction.send:
        await _sendDraft(item);
      case _DraftAction.discard:
        await _discardDraft(item);
    }
  }

  /// Asked first: a draft's photos exist nowhere but this phone.
  Future<bool> _discardDraft(BatchItem item) async {
    final ok = await showConfirmDialog(
      context,
      title: 'Discard this bill?',
      message: 'Its ${plural(item.pages.length, 'photo')} ${item.pages.length == 1 ? 'is' : 'are'} deleted from this phone.',
      confirmLabel: 'Discard',
      destructive: true,
    );
    if (!ok || !mounted) return false;
    _dropLocal(item);
    return true;
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

  /// Bills whose upload was cut because the app left the screen (DAS-131).
  /// They stay "preparing" with their photos on disk, and go up again the
  /// moment the app is back ([_resumePausedUploads]). In memory only: after a
  /// kill, `StartupAction.uploadAgain` does the same for every unuploaded bill.
  final List<BatchItem> _pausedUploads = [];

  /// The app is back on screen: send what was cut while it was away, one at a
  /// time, as a restart does.
  Future<void> _resumePausedUploads() async {
    if (_pausedUploads.isEmpty) return;
    final again = List<BatchItem>.of(_pausedUploads);
    _pausedUploads.clear();
    for (final item in again) {
      if (!mounted || !_items.contains(item)) continue;
      await _uploadAndExtract(item);
    }
  }

  Future<void> _uploadItem(BatchItem item) async {
    setState(() => item.status = BatchItemStatus.preparing);
    // Which time away this upload started in: a failure that arrives in a
    // later one (iOS reports a socket it closed while suspended only on the
    // first read after resume) was the platform's doing too.
    final away = AppForeground.awayCount;
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
      // Cut because the app left the screen (Android refuses a backgrounded
      // app's connections after 5 s): not a failure the shopkeeper should
      // see or have to retry. It stays "preparing" and goes up again on
      // return; a page the server already accepted is simply sent again
      // (preprocess answers with a path and keeps nothing else).
      if (!AppForeground.visible.value || AppForeground.awayCount != away) {
        if (!_pausedUploads.contains(item)) _pausedUploads.add(item);
        if (AppForeground.visible.value) unawaited(_resumePausedUploads());
        return;
      }
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
    // between leaves an unnamed photo (shown to crop on next start, to be
    // discarded), never a bill with neither its photo nor its upload.
    await _persistBatch();
    for (final page in uploadedPages) {
      final id = page.photoId;
      if (id != null) await PendingPhotoStore.delete(id);
    }
  }
}

enum _DraftAction { addPage, send, discard }
