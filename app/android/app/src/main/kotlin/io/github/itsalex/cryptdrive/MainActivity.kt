package io.github.itsalex.cryptdrive

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        dropUnreadableSharedStreams(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        dropUnreadableSharedStreams(intent)
        super.onNewIntent(intent)
    }

    // receive_sharing_intent copies shared streams without catching errors: one unreadable URI would crash the app.
    private fun dropUnreadableSharedStreams(intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_SEND -> {
                val uri = intent.streamUri()
                if (uri != null && !canRead(uri)) intent.removeExtra(Intent.EXTRA_STREAM)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = intent.streamUris() ?: return
                val readable = uris.filterTo(ArrayList()) { canRead(it) }
                if (readable.size != uris.size) intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM, readable)
            }
        }
    }

    private fun Intent.streamUri(): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(Intent.EXTRA_STREAM)
        }

    private fun Intent.streamUris(): ArrayList<Uri>? =
        if (Build.VERSION.SDK_INT >= 33) {
            getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }

    private fun canRead(uri: Uri): Boolean =
        try {
            contentResolver.openInputStream(uri)?.close()
            true
        } catch (error: Exception) {
            Log.w("CryptDrive", "Ignoring unreadable shared file $uri: $error")
            false
        }
}
