package com.example.justice_chain

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.io.File

/**
 * Records evidence while Sakshya isn't on screen (step 6b): the phone is
 * locked or the app was swiped away. The Flutter camera plugin needs the app
 * on screen, so this records with CameraX itself, with no preview, window or
 * screen wake. ProtectionService (type camera|microphone) is what lets the
 * process use the camera and microphone in the background.
 *
 * If the camera can't be used (permission, another app, an OEM block, no
 * frames), it records audio only, so there is still evidence. Both are MP4
 * files, so the existing seal-and-upload path takes either.
 *
 * Main thread only. One recording at a time; [start] answers once, when the
 * clip is finished.
 */
@SuppressLint("MissingPermission") // checked in start() before any recording
object BackgroundRecorder : LifecycleOwner {
    private const val TAG = "SakshyaRecorder"

    /** Frames must arrive this soon, or the camera counts as unavailable. */
    private const val FIRST_FRAME_TIMEOUT_MS = 4000L

    private val registry = LifecycleRegistry(this).apply { currentState = Lifecycle.State.CREATED }
    override val lifecycle: Lifecycle get() = registry

    private val main = Handler(Looper.getMainLooper())
    private var onDone: ((Map<String, Any?>) -> Unit)? = null
    private var appContext: Context? = null
    private var maxSeconds = 0
    private var videoFile: File? = null
    private var video: Recording? = null
    private var gotFrames = false
    private var stopRequested = false
    private var audio: MediaRecorder? = null
    private var audioFile: File? = null
    private val stopAtLimit = Runnable { stop() }
    private val checkFrames = Runnable {
        if (video != null && !gotFrames) {
            Log.w(TAG, "No camera frames; falling back to audio")
            video?.stop() // finalizes with no data, which starts the audio fallback
        }
    }

    val isRecording get() = onDone != null

    /** Records up to [seconds]; [done] gets {path, kind: video|audio} or {error}. */
    fun start(context: Context, seconds: Int, done: (Map<String, Any?>) -> Unit) {
        if (onDone != null) {
            done(mapOf("error" to "already recording"))
            return
        }
        val app = context.applicationContext
        if (!granted(app, Manifest.permission.RECORD_AUDIO)) {
            done(mapOf("error" to "microphone permission missing"))
            return
        }
        onDone = done
        appContext = app
        stopRequested = false
        maxSeconds = seconds
        main.postDelayed(stopAtLimit, seconds * 1000L)
        if (granted(app, Manifest.permission.CAMERA)) startVideo(app) else startAudio(app)
    }

    /** Ends the recording early; [start]'s callback then gets the clip. */
    fun stop() {
        stopRequested = true
        main.removeCallbacks(stopAtLimit)
        main.removeCallbacks(checkFrames)
        when {
            video != null -> video?.stop() // answers from the Finalize event
            audio != null -> finishAudio()
        }
    }

    private fun startVideo(app: Context) {
        val future = ProcessCameraProvider.getInstance(app)
        future.addListener({
            try {
                val provider = future.get()
                val recorder = Recorder.Builder()
                    .setQualitySelector(
                        QualitySelector.from(Quality.HD, FallbackStrategy.lowerQualityOrHigherThan(Quality.SD)))
                    .build()
                val capture = VideoCapture.withOutput(recorder)
                provider.unbindAll()
                registry.currentState = Lifecycle.State.STARTED
                provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, capture)

                val file = File(app.cacheDir, "background_${System.currentTimeMillis()}.mp4")
                videoFile = file
                gotFrames = false
                video = capture.output
                    .prepareRecording(app, FileOutputOptions.Builder(file).build())
                    .withAudioEnabled()
                    .start(ContextCompat.getMainExecutor(app)) { event ->
                        when (event) {
                            is VideoRecordEvent.Status ->
                                if (event.recordingStats.numBytesRecorded > 0) gotFrames = true
                            is VideoRecordEvent.Finalize -> onVideoFinalized(event)
                        }
                    }
                main.postDelayed(checkFrames, FIRST_FRAME_TIMEOUT_MS)
                Log.i(TAG, "Background video recording started")
            } catch (e: Exception) {
                Log.w(TAG, "Camera unavailable ($e); recording audio instead")
                releaseCamera()
                startAudio(app)
            }
        }, ContextCompat.getMainExecutor(app))
    }

    private fun onVideoFinalized(event: VideoRecordEvent.Finalize) {
        val file = videoFile
        video = null
        videoFile = null
        releaseCamera()
        main.removeCallbacks(checkFrames)
        // Some errors (e.g. the camera taken away mid-way) still leave a
        // playable clip; keep anything that has data.
        if (file != null && file.exists() && file.length() > 0 &&
            event.error != VideoRecordEvent.Finalize.ERROR_NO_VALID_DATA) {
            if (event.hasError()) Log.w(TAG, "Video finalized with error ${event.error}; keeping the clip")
            finish(mapOf("path" to file.absolutePath, "kind" to "video"))
            return
        }
        file?.delete()
        if (stopRequested) return finish(mapOf("error" to "stopped before any video was recorded"))
        Log.w(TAG, "No video recorded (error ${event.error}); recording audio instead")
        val app = appContext ?: return finish(mapOf("error" to "no context"))
        startAudio(app)
    }

    private fun startAudio(app: Context) {
        val file = File(app.cacheDir, "background_${System.currentTimeMillis()}.mp4")
        try {
            @Suppress("DEPRECATION")
            val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(app) else MediaRecorder()
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioEncodingBitRate(96_000)
            recorder.setAudioSamplingRate(44_100)
            recorder.setOutputFile(file.absolutePath)
            recorder.prepare()
            recorder.start()
            audio = recorder
            audioFile = file
            Log.i(TAG, "Background audio recording started")
        } catch (e: Exception) {
            file.delete()
            finish(mapOf("error" to "audio recording failed: $e"))
        }
    }

    private fun finishAudio() {
        val recorder = audio ?: return
        val file = audioFile
        audio = null
        audioFile = null
        val stopped = try {
            recorder.stop()
            true
        } catch (e: RuntimeException) {
            false // stopped before any audio was written
        } finally {
            recorder.release()
        }
        if (stopped && file != null && file.length() > 0) {
            finish(mapOf("path" to file.absolutePath, "kind" to "audio"))
        } else {
            file?.delete()
            finish(mapOf("error" to "no audio recorded"))
        }
    }

    private fun releaseCamera() {
        registry.currentState = Lifecycle.State.CREATED
        val app = appContext ?: return
        try {
            ProcessCameraProvider.getInstance(app).get().unbindAll()
        } catch (e: Exception) {
            Log.w(TAG, "Camera unbind failed: $e")
        }
    }

    private fun finish(result: Map<String, Any?>) {
        main.removeCallbacks(stopAtLimit)
        main.removeCallbacks(checkFrames)
        val done = onDone
        onDone = null
        Log.i(TAG, "Background recording finished: $result")
        done?.invoke(result)
    }

    private fun granted(context: Context, permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}
