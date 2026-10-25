package com.dastavez.bahi

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * One native call: saving a sale bill through the system's Save dialog (DAS-121).
 *
 * file_picker asks for a document of any type, so when a file of that name is
 * already in the folder Android names the new one `Bill-….pdf (1)` and the
 * extension breaks. Asking for `application/pdf` gets `Bill-… (1).pdf`. No
 * storage permission: the system writes where the shopkeeper picks.
 */
class MainActivity : FlutterActivity() {
    private var pendingBytes: ByteArray? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dastavez/save_pdf").setMethodCallHandler { call, result ->
            if (call.method != "save") return@setMethodCallHandler result.notImplemented()
            if (pendingResult != null) return@setMethodCallHandler result.error("busy", "A save is already open", null)
            pendingBytes = call.argument<ByteArray>("bytes")
            pendingResult = result
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/pdf"
                putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
            }
            startActivityForResult(intent, SAVE_PDF)
        }
    }

    @Deprecated("The Flutter embedding still delivers results here")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != SAVE_PDF) return super.onActivityResult(requestCode, resultCode, data)
        val result = pendingResult ?: return
        val bytes = pendingBytes
        pendingResult = null
        pendingBytes = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || bytes == null) return result.success(null)
        try {
            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
            result.success(uri.toString())
        } catch (e: Exception) {
            result.error("write_failed", e.message, null)
        }
    }

    private companion object {
        const val SAVE_PDF = 4121
    }
}
