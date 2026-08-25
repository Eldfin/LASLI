package de.lasli.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread
import kotlin.math.max

class TimestampedAudioCapture(
    private val context: Context,
) : EventChannel.StreamHandler {
    companion object {
        private const val SAMPLE_RATE = 16000
        private const val READ_FRAMES = 320
        private const val NANOS_PER_SECOND = 1_000_000_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var eventSink: EventChannel.EventSink? = null
    @Volatile private var running = false
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    @Synchronized
    fun start() {
        if (running) return
        if (ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            throw SecurityException("Mikrofonberechtigung fehlt.")
        }

        val minimumBytes = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minimumBytes <= 0) {
            throw IllegalStateException("AudioRecord-Puffer konnte nicht bestimmt werden.")
        }
        val recorder = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            max(minimumBytes * 2, READ_FRAMES * 4),
        )
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            throw IllegalStateException("AudioRecord konnte nicht initialisiert werden.")
        }

        recorder.startRecording()
        if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            recorder.release()
            throw IllegalStateException("AudioRecord wurde nicht gestartet.")
        }
        audioRecord = recorder
        running = true
        captureThread = thread(
            start = true,
            isDaemon = true,
            name = "lasli-timestamped-audio",
        ) {
            captureLoop(recorder)
        }
    }

    @Synchronized
    fun stop() {
        running = false
        val recorder = audioRecord
        audioRecord = null
        try {
            recorder?.stop()
        } catch (_: IllegalStateException) {
        }
        try {
            captureThread?.join(750)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        captureThread = null
        recorder?.release()
    }

    private fun captureLoop(recorder: AudioRecord) {
        val samples = ShortArray(READ_FRAMES)
        var framesRead = 0L
        try {
            while (running) {
                val count = recorder.read(
                    samples,
                    0,
                    samples.size,
                    AudioRecord.READ_BLOCKING,
                )
                if (count <= 0) {
                    if (running) sendError("AUDIO_READ_FAILED", "AudioRecord.read: $count")
                    break
                }

                val chunkStartFrame = framesRead
                framesRead += count.toLong()
                val firstSampleTimeNs = firstSampleTimeNs(
                    recorder,
                    chunkStartFrame,
                    count,
                )
                val bytes = ByteBuffer.allocate(count * 2)
                    .order(ByteOrder.LITTLE_ENDIAN)
                for (index in 0 until count) bytes.putShort(samples[index])
                val payload = bytes.array()
                mainHandler.post {
                    if (running) {
                        eventSink?.success(
                            mapOf(
                                "pcm" to payload,
                                "firstSampleTimeNs" to firstSampleTimeNs,
                                "deliveryTimeNs" to System.nanoTime(),
                                "sampleRate" to SAMPLE_RATE,
                            ),
                        )
                    }
                }
            }
        } catch (error: Exception) {
            if (running) sendError("AUDIO_CAPTURE_FAILED", error.message ?: error.toString())
        }
    }

    private fun firstSampleTimeNs(
        recorder: AudioRecord,
        chunkStartFrame: Long,
        frameCount: Int,
    ): Long {
        val nowNs = System.nanoTime()
        val timestamp = AudioTimestamp()
        val status = recorder.getTimestamp(
            timestamp,
            AudioTimestamp.TIMEBASE_MONOTONIC,
        )
        if (status == AudioRecord.SUCCESS) {
            val frameDelta = timestamp.framePosition - chunkStartFrame
            val candidate = timestamp.nanoTime -
                frameDelta * NANOS_PER_SECOND / SAMPLE_RATE
            if (candidate in (nowNs - 2L * NANOS_PER_SECOND)..(nowNs + 100_000_000L)) {
                return candidate
            }
        }
        return nowNs - frameCount.toLong() * NANOS_PER_SECOND / SAMPLE_RATE
    }

    private fun sendError(code: String, message: String) {
        mainHandler.post {
            eventSink?.error(code, message, null)
        }
    }
}
