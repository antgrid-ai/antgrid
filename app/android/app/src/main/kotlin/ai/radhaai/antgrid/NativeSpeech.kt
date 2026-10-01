package ai.radhaai.antgrid

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The OS on-device recognizer behind lib/voice/android_speech_engine.dart.
 *
 * Only createOnDeviceSpeechRecognizer is ever used: the default recognizer may
 * send audio to a server, and the Dart side reports this engine as on-device.
 *
 * A recognizer ends a session at the first pause, so one dictation spans many
 * sessions. Text from finished sessions accumulates in [committed] and every
 * event carries the whole utterance, which keeps Dart unaware of segmenting.
 */
class NativeSpeech(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "ai.radhaai.antgrid/speech")
    private val events = EventChannel(messenger, "ai.radhaai.antgrid/speech/events")
    private var sink: EventChannel.EventSink? = null
    private var recognizer: SpeechRecognizer? = null

    private var capture = 0
    private var language = "en-US"
    private var listening = false
    private var stopping = false
    private val committed = mutableListOf<String>()
    private var current = ""

    /** Some recognizers drop their final result on stopListening; Stop must still end. */
    private val finishTimeout = Runnable { finish() }

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val lang = call.argument<String>("language") ?: language
        when (call.method) {
            "status" -> status(lang, result)
            "download" -> download(lang, result)
            "start" -> {
                start(call.argument<Int>("capture")!!, lang)
                result.success(null)
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            "cancel" -> {
                cancel()
                result.success(null)
            }
            "dispose" -> {
                dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun onDeviceAvailable() =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    private fun recognizer(): SpeechRecognizer =
        recognizer ?: SpeechRecognizer.createOnDeviceSpeechRecognizer(context).also {
            it.setRecognitionListener(listener)
            recognizer = it
        }

    private fun intent(lang: String) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang)
    }

    private fun status(lang: String, result: MethodChannel.Result) {
        if (!onDeviceAvailable()) {
            result.success(mapOf("onDevice" to false))
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(mapOf("onDevice" to true, "state" to "unknown", "language" to lang))
            return
        }
        var answered = false
        fun answer(state: String, tag: String = lang) {
            if (answered) return
            answered = true
            result.success(mapOf("onDevice" to true, "state" to state, "language" to tag))
        }
        recognizer().checkRecognitionSupport(
            intent(lang),
            context.mainExecutor,
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    val installed = match(support.installedOnDeviceLanguages, lang)
                    val pending = match(support.pendingOnDeviceLanguages, lang)
                    val supported = match(support.supportedOnDeviceLanguages, lang)
                    when {
                        installed != null -> answer("installed", installed)
                        pending != null -> answer("pending", pending)
                        supported != null -> answer("downloadable", supported)
                        else -> answer("unsupported")
                    }
                }

                // Google's Speech Services has been seen to report an error and
                // then the real result, so an error only stands if nothing follows.
                override fun onError(error: Int) {
                    main.postDelayed({ answer("unknown") }, 500)
                }
            },
        )
    }

    /** An exact tag wins; otherwise any installed variant of the same language. */
    private fun match(tags: List<String>, lang: String): String? =
        tags.firstOrNull { it.equals(lang, ignoreCase = true) }
            ?: tags.firstOrNull {
                it.substringBefore('-').equals(lang.substringBefore('-'), ignoreCase = true)
            }

    private fun download(lang: String, result: MethodChannel.Result) {
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> {
                recognizer().triggerModelDownload(
                    intent(lang),
                    context.mainExecutor,
                    object : ModelDownloadListener {
                        override fun onProgress(completedPercent: Int) =
                            send("download", "progress" to completedPercent)

                        override fun onSuccess() = send("download", "done" to true)

                        override fun onScheduled() = send("download", "scheduled" to true)

                        override fun onError(error: Int) = send("download", "error" to error)
                    },
                )
                result.success("listening")
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
                recognizer().triggerModelDownload(intent(lang))
                result.success("scheduled")
            }
            else -> result.success("unsupported")
        }
    }

    private fun start(id: Int, lang: String) {
        main.removeCallbacks(finishTimeout)
        recognizer?.cancel()
        capture = id
        language = lang
        committed.clear()
        current = ""
        listening = true
        stopping = false
        listen()
    }

    private fun listen() {
        val i = intent(language).apply {
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // Ask for one session that outlasts pauses. Recognizers that do not
                // support segmented sessions ignore this and end at the first pause,
                // which the listener answers by starting the next session.
                putExtra(
                    RecognizerIntent.EXTRA_SEGMENTED_SESSION,
                    RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS,
                )
                // Read as Integer by Android System Intelligence; a Long is ignored.
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 120_000)
            }
        }
        recognizer().startListening(i)
    }

    private fun stop() {
        if (!listening || stopping) return
        stopping = true
        recognizer?.stopListening()
        main.postDelayed(finishTimeout, 3000)
    }

    private fun cancel() {
        main.removeCallbacks(finishTimeout)
        listening = false
        stopping = false
        recognizer?.cancel()
        committed.clear()
        current = ""
    }

    fun dispose() {
        cancel()
        recognizer?.destroy()
        recognizer = null
    }

    private fun commit() {
        if (current.isNotBlank()) committed += current.trim()
        current = ""
    }

    private fun text() = (committed + current.trim()).filter { it.isNotEmpty() }.joinToString(" ")

    /** A session ended on its own: keep going unless the user asked to stop. */
    private fun sessionEnded() {
        commit()
        if (!listening) return
        if (stopping) {
            finish()
        } else {
            // Restarting from inside a callback can race the recognizer's own teardown.
            main.post { if (listening && !stopping) listen() }
        }
    }

    private fun finish() {
        main.removeCallbacks(finishTimeout)
        if (!listening) return
        commit()
        listening = false
        stopping = false
        send("final", "text" to text())
    }

    private fun fail(error: Int) {
        main.removeCallbacks(finishTimeout)
        if (!listening) return
        listening = false
        stopping = false
        recognizer?.cancel()
        send("error", "code" to error, "text" to text())
    }

    private fun send(type: String, vararg fields: Pair<String, Any>) {
        sink?.success(mapOf("type" to type, "capture" to capture) + fields)
    }

    private fun best(results: Bundle?): String? =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}

        // Android System Intelligence delivers an utterance's final text as a
        // partial after this and leaves onResults empty, so nothing commits here.
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            if (!listening) return
            best(partialResults)?.let {
                current = it
                send("partial", "text" to text())
            }
        }

        override fun onResults(results: Bundle?) {
            if (!listening) return
            best(results)?.takeIf { it.isNotBlank() }?.let { current = it }
            sessionEnded()
        }

        override fun onSegmentResults(segmentResults: Bundle) {
            if (!listening) return
            best(segmentResults)?.takeIf { it.isNotBlank() }?.let { current = it }
            commit()
            send("partial", "text" to text())
        }

        override fun onEndOfSegmentedSession() {
            if (listening) sessionEnded()
        }

        override fun onError(error: Int) {
            if (!listening) return
            when {
                error == SpeechRecognizer.ERROR_NO_MATCH ||
                    error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> sessionEnded()
                // stopListening can surface as a client error with the text
                // already delivered as partials.
                stopping && error == SpeechRecognizer.ERROR_CLIENT -> finish()
                else -> fail(error)
            }
        }
    }
}
