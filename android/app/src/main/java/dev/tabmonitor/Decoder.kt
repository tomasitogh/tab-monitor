package dev.tabmonitor

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.util.ArrayDeque

/**
 * H.264 con MediaCodec asíncrono sobre la Surface: cada frame decodificado va a la pantalla
 * apenas sale (releaseOutputBuffer(i, true)).
 *
 * Todo el estado vive en el hilo del codec. Los frames comprimidos no se pueden saltear (los que
 * siguen dependen de ellos): si se acumulan, se tiran todos y se pide un keyframe.
 */
class Decoder(private val surface: Surface, private val listener: Listener, private val forcedName: String? = null) {
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
            if (!frame.keyframe) return
            waitingForKeyframe = false
        }
        if (codec == null && !start(frame)) {
            waitingForKeyframe = true
            return
        }
        if (frame.keyframe) {
            // Un keyframe vuelve todo lo anterior innecesario.
            if (pending.isNotEmpty()) listener.onDropped(pending.size)
            pending.clear()
        }
        pending.add(frame)
        if (pending.size > MAX_PENDING) {
            Log.w(TAG, "el decoder no da abasto: se tiran ${pending.size} frames y se pide un keyframe")
            listener.onDropped(pending.size)
            pending.clear()
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
            if (frame.annexB.size > buffer.capacity()) {
                Log.e(TAG, "frame de ${frame.annexB.size} bytes no entra en ${buffer.capacity()}; se pide keyframe")
                freeInputs.addFirst(index)
                waitingForKeyframe = true
                listener.onKeyframeNeeded()
                return
            }
            buffer.clear()
            buffer.put(frame.annexB)
            queuedAt[frame.captureMicros] = System.nanoTime()
            codec.queueInputBuffer(index, 0, frame.annexB.size, frame.captureMicros, 0)
        }
    }

    /** Crea el codec con el SPS y el PPS del primer keyframe. */
    private fun start(keyframe: Wire.Incoming.Video): Boolean {
        val nals = splitNals(keyframe.annexB)
        val sps = nals.firstOrNull { nalType(it) == 7 }
        val pps = nals.firstOrNull { nalType(it) == 8 }
        if (sps == null || pps == null || width == 0) {
            Log.w(TAG, "keyframe sin SPS/PPS o sin config todavía")
            return false
        }
        Log.i(TAG, "SPS ${sps.joinToString("") { "%02x".format(it) }}")
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(START_CODE + sps))
            setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(START_CODE + pps))
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, width * height)   // un keyframe entra holgado
            setInteger(MediaFormat.KEY_PRIORITY, 0)                       // tiempo real
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            // Claves de Qualcomm: modo de baja latencia y salida en orden de decodificación, sin esperar
            // a llenar el DPB (el SPS de VideoToolbox declara 11 frames). Medido en la P11 Pro con
            // OMX.qcom: sin la segunda, el decoder retenía ~2 frames (37 ms a 52 fps, 400 ms a 3 fps).
            setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
        }
        return try {
            val codec = MediaCodec.createByCodecName(forcedName ?: decoderName(width, height))
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
            codec.releaseOutputBuffer(index, true)
            // La hora de mostrar es la de soltar el buffer: OnFrameRenderedListener no sirve en
            // c2.qti.avc.decoder (devuelve el PTS × 1000). El frame aparece en el vsync siguiente.
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
        pending.clear()
        queuedAt.clear()
    }

    companion object {
        const val TAG = "TabMonitor"
        /** Frames comprimidos esperando un buffer de entrada antes de rendirse y pedir keyframe. */
        const val MAX_PENDING = 3
        private val START_CODE = byteArrayOf(0, 0, 0, 1)

        private fun nalType(nal: ByteArray) = if (nal.isEmpty()) -1 else nal[0].toInt() and 0x1F

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

        /**
         * El OMX de Qualcomm si está; si no, el que elija Android. Medido en la P11 Pro (Android 11)
         * con un frame cada 100 ms: c2.qti.avc.decoder retiene cada frame hasta que llega el
         * siguiente (decode 125 ms) aunque el SPS diga 1 referencia y 0 de reordenamiento;
         * OMX.qcom.video.decoder.avc con vendor.qti-ext-dec-low-latency lo entrega en 19 ms.
         */
        fun decoderName(w: Int, h: Int): String {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            list.codecInfos.firstOrNull { it.name == "OMX.qcom.video.decoder.avc" }?.let { return it.name }
            return list.findDecoderForFormat(MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h))
                ?: "OMX.google.h264.decoder"
        }

        /** Lo que el decoder de AVC por hardware dice soportar, para el `hello`. */
        fun maxDecode(screenW: Int, screenH: Int): Triple<Int, Int, Int> {
            val info = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
                !info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) } &&
                    (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || info.isHardwareAccelerated)
            } ?: return Triple(screenW, screenH, 60)
            val caps: MediaCodecInfo.VideoCapabilities = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).videoCapabilities
            val fps = when {
                caps.areSizeAndRateSupported(screenW, screenH, 60.0) -> 60
                caps.isSizeSupported(screenW, screenH) -> caps.getSupportedFrameRatesFor(screenW, screenH).upper.toInt().coerceAtMost(60)
                else -> 0
            }
            return Triple(caps.supportedWidths.upper, caps.supportedHeights.upper, fps)
        }
    }
}
