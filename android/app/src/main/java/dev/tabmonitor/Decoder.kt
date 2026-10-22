package dev.tabmonitor

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.util.ArrayDeque

/**
 * H.264 con MediaCodec asíncrono sobre la Surface: cada frame decodificado va a la pantalla
 * apenas sale (releaseOutputBuffer con la hora actual).
 *
 * Todo el estado vive en el hilo del codec. Los frames comprimidos no se pueden saltear (los que
 * siguen dependen de ellos): si se acumulan, se tiran todos y se pide un keyframe.
 */
class Decoder(private val surface: Surface, private val listener: Listener, private val name: String) {
    interface Listener {
        /** Hay que pedirle un keyframe a la Mac. */
        fun onKeyframeNeeded()
        /** Un frame se mandó a la pantalla: hora de captura (µs, reloj de la Mac) y [System.nanoTime] de la tablet. */
        fun onRendered(captureMicros: Long, renderNanos: Long)
        fun onDecoded(decodeNanos: Long)
        fun onDropped(count: Int)
    }

    private val thread = HandlerThread("TabMonitor-decoder", android.os.Process.THREAD_PRIORITY_URGENT_DISPLAY).apply { start() }
    private val handler = Handler(thread.looper)

    private var codec: MediaCodec? = null
    private var width = 0
    private var height = 0
    private var waitingForKeyframe = true
    private val freeInputs = ArrayDeque<Int>()
    private val pending = ArrayDeque<Wire.Incoming.Video>()
    /** Hora de captura → System.nanoTime en que entró al decoder. */
    private val queuedAt = HashMap<Long, Long>()

    /** El tamaño que anunció la Mac en `config`. */
    fun configure(w: Int, h: Int) = handler.post {
        if (w == width && h == height && codec != null) return@post
        width = w
        height = h
        release()
        waitingForKeyframe = true
        listener.onKeyframeNeeded()
    }

    fun submit(frame: Wire.Incoming.Video) = handler.post { onFrame(frame) }

    fun stop() {
        handler.post { release() }
        thread.quitSafely()
    }

    private fun onFrame(frame: Wire.Incoming.Video) {
        if (waitingForKeyframe) {
            if (!frame.keyframe) return frame.release()
            waitingForKeyframe = false
        }
        if (codec == null && !start(frame)) {
            waitingForKeyframe = true
            return frame.release()
        }
        if (frame.keyframe) {
            // Un keyframe vuelve todo lo anterior innecesario.
            if (pending.isNotEmpty()) listener.onDropped(pending.size)
            dropPending()
        }
        pending.add(frame)
        if (pending.size > MAX_PENDING) {
            Log.w(TAG, "el decoder no da abasto: se tiran ${pending.size} frames y se pide un keyframe")
            listener.onDropped(pending.size)
            dropPending()
            waitingForKeyframe = true
            listener.onKeyframeNeeded()
            return
        }
        feed()
    }

    private fun feed() {
        val codec = codec ?: return
        while (pending.isNotEmpty() && freeInputs.isNotEmpty()) {
            val frame = pending.poll()!!
            val index = freeInputs.poll()!!
            val buffer = codec.getInputBuffer(index) ?: continue
            if (frame.length > buffer.capacity()) {
                Log.e(TAG, "frame de ${frame.length} bytes no entra en ${buffer.capacity()}; se pide keyframe")
                frame.release()
                freeInputs.addFirst(index)
                waitingForKeyframe = true
                listener.onKeyframeNeeded()
                return
            }
            buffer.clear()
            buffer.put(frame.data, frame.offset, frame.length)
            frame.release()
            queuedAt[frame.captureMicros] = System.nanoTime()
            codec.queueInputBuffer(index, 0, frame.length, frame.captureMicros, 0)
        }
    }

    /** Crea el codec con el SPS y el PPS del primer keyframe. */
    private fun start(keyframe: Wire.Incoming.Video): Boolean {
        val format = if (width == 0) null else DecoderChoice.format(name, width, height, keyframe.annexB())
        if (format == null) {
            Log.w(TAG, "keyframe sin SPS/PPS o sin config todavía")
            return false
        }
        return try {
            val codec = MediaCodec.createByCodecName(name)
            val lowLatencySupported = codec.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
            codec.setCallback(callback, handler)
            codec.configure(format, surface, null, 0)
            codec.start()
            this.codec = codec
            Log.i(TAG, "decoder ${codec.name} a ${width}×$height, FEATURE_LowLatency $lowLatencySupported")
            true
        } catch (e: Exception) {
            Log.e(TAG, "no se pudo crear el decoder", e)
            release()
            false
        }
    }

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
            if (codec !== this@Decoder.codec) return
            freeInputs.add(index)
            feed()
        }

        override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            if (codec !== this@Decoder.codec) return
            val now = System.nanoTime()
            queuedAt.remove(info.presentationTimeUs)?.let { listener.onDecoded(now - it) }
            // Con `true` la Surface toma el PTS (la hora de captura, en el reloj de la Mac) como hora
            // deseada de presentación; con la hora actual de la tablet se muestra cuanto antes y
            // SurfaceFlinger descarta el frame si llega otro antes del vsync.
            codec.releaseOutputBuffer(index, now)
            // La latencia se mide al soltar el buffer. OnFrameRenderedListener no sirve: en c2.qti
            // devuelve el PTS × 1000 y en OMX.qcom reporta ~20 ms después del present fence. Hasta
            // verse faltan ~25 ms más (dumpsys SurfaceFlinger --latency, docs/latency.md).
            listener.onRendered(info.presentationTimeUs, now)
        }

        override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
            if (codec !== this@Decoder.codec) return
            Log.e(TAG, "error del decoder (${e.diagnosticInfo}); se recrea", e)
            release()
            waitingForKeyframe = true
            listener.onKeyframeNeeded()
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            Log.i(TAG, "formato de salida: $format")
        }
    }

    private fun release() {
        codec?.let {
            try { it.stop() } catch (_: Exception) {}
            it.release()
        }
        codec = null
        freeInputs.clear()
        dropPending()
        queuedAt.clear()
    }

    private fun dropPending() {
        pending.forEach { it.release() }
        pending.clear()
    }

    companion object {
        const val TAG = "TabMonitor"
        /** Frames comprimidos esperando un buffer de entrada antes de rendirse y pedir keyframe. */
        const val MAX_PENDING = 3

        /** Las NAL de un buffer Annex B, sin el código de inicio. */
        fun splitNals(data: ByteArray): List<ByteArray> {
            val starts = ArrayList<Int>()   // primer byte de cada NAL
            var i = 0
            while (i + 3 <= data.size) {
                if (data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 1.toByte()) {
                    starts.add(i + 3)
                    i += 3
                } else i++
            }
            return starts.mapIndexed { n, s ->
                var end = if (n + 1 < starts.size) starts[n + 1] - 3 else data.size
                if (n + 1 < starts.size && end > s && data[end - 1] == 0.toByte()) end--   // código de 4 bytes
                data.copyOfRange(s, end)
            }
        }
    }
}
