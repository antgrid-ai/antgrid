package ai.radhaai.antgrid

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Android's share sheet has no "save to device" target, so a download
    // saves through the system's own Save-as screen (the Storage Access
    // Framework) instead. It needs no storage permission: the user picks the
    // place, and the picker grants write access to that one document.
    private var pendingSave: Pair<ByteArray, MethodChannel.Result>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SAVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "save") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingSave != null) {
                    result.error("busy", "A save is already open", null)
                    return@setMethodCallHandler
                }
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("bad_args", "No bytes to save", null)
                    return@setMethodCallHandler
                }
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = call.argument<String>("mimeType") ?: "application/octet-stream"
                    putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
                }
                pendingSave = bytes to result
                try {
                    startActivityForResult(intent, SAVE_REQUEST)
                } catch (e: Exception) {
                    // No picker (a stripped-down or work-profile device): left
                    // set, the pending save would answer "busy" to every save
                    // after this one.
                    pendingSave = null
                    result.error("no_picker", e.message, null)
                }
            }
    }

    @Deprecated("FlutterActivity is not a ComponentActivity; no result API replaces this")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != SAVE_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val (bytes, result) = pendingSave ?: return
        pendingSave = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(false)
            return
        }
        Thread {
            try {
                // Plain "w", not "wt": the document was just created empty, and
                // some third-party providers reject the truncate mode outright.
                contentResolver.openOutputStream(uri, "w").use { out ->
                    checkNotNull(out) { "No stream for $uri" }.write(bytes)
                }
                runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                runOnUiThread { result.error("write_failed", e.message, null) }
            }
        }.start()
    }

    private companion object {
        const val SAVE_CHANNEL = "ai.radhaai.antgrid/save_file"
        const val SAVE_REQUEST = 0x5A7E
    }
}
