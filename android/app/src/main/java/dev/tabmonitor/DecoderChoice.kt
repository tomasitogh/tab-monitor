package dev.tabmonitor

import android.content.Context
import android.graphics.ImageFormat
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.util.Locale

/**
 * Elige el decoder de H.264 con menos demora en esta tablet, probándolos.
 *
 * Lo que importa es si el decoder retiene frames: en la P11 Pro, c2.qti.avc.decoder entrega cada
 * frame recién cuando llega el siguiente (125 ms con un frame cada 100 ms) aunque el SPS diga 1
 * referencia, y OMX.qcom.video.decoder.avc lo entrega en 19 ms. No se puede saber por el nombre en
 * tablets que no medimos, así que se prueba cada decoder por hardware con un clip del encoder de
 * la Mac (assets/calibration.bin, ver CalibrationClip.swift): se le da un frame por vez y se mira
 * si sale antes de mandar el siguiente. El resultado se guarda por versión de Android y del visor.
 */
object DecoderChoice {
    private const val TAG = "TabMonitor"
    /** Frames del principio que no cuentan: el primero tarda más en cualquier decoder. */
    private const val WARMUP = 2
    /** Cuánto se espera cada frame antes de darlo por retenido. */
    private const val WAIT_MS = 100L
    /** Con tantos frames retenidos ya no hace falta seguir probando ese decoder. */
    private const val MAX_RETAINED = 3

    /** Cómo le fue a un decoder con el clip. */
    data class Trial(val name: String, val retained: Int, val medianMs: Double, val error: String? = null) {
        override fun toString() = if (error != null) "$name: $error"
            else String.format(Locale.ROOT, "%s: %d retenidos, %.1f ms", name, retained, medianMs)
    }

    /** El mejor: el que menos frames retiene y, entre esos, el más rápido. Los que fallaron no cuentan. */
    fun best(trials: List<Trial>): Trial? =
        trials.filter { it.error == null }.minWithOrNull(compareBy<Trial>({ it.retained }, { it.medianMs }))

    /**
     * El decoder elegido para esta tablet; la primera vez (o tras una actualización) prueba todos.
     * [onCalibrating] avisa que va a tardar. Bloquea: no llamarlo desde el hilo principal.
     */
    fun choose(context: Context, onCalibrating: () -> Unit): String {
        val prefs = context.getSharedPreferences("decoder", Context.MODE_PRIVATE)
        val version = context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode
        val key = "${Build.FINGERPRINT}|$version"
        val cached = prefs.getString("name", null)
        if (cached != null && prefs.getString("key", null) == key) {
            Log.i(TAG, "decoder elegido antes: $cached (${prefs.getString("summary", "")})")
            return cached
        }
        onCalibrating()
        val started = System.nanoTime()
        val clip = loadClip(context)
        val trials = candidates().map { trial(it, clip) }
        val chosen = best(trials)?.name ?: fallback()
        val summary = trials.joinToString("; ")
        Log.i(TAG, "decoders probados en ${(System.nanoTime() - started) / 1_000_000} ms: $summary; se elige $chosen")
        prefs.edit().putString("key", key).putString("name", chosen).putString("summary", summary).apply()
        return chosen
    }

    /** Los decoders de AVC por hardware (sin alias); si no hay, todos. */
    fun candidates(): List<String> {
        val all = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) } && !info.isAlias
        }
        val hardware = all.filter { it.isHardwareAccelerated && !it.isSoftwareOnly }
        return (hardware.ifEmpty { all }).map { it.name }
    }

    private fun fallback(): String =
        MediaCodecList(MediaCodecList.REGULAR_CODECS)
            .findDecoderForFormat(MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1920, 1080))
            ?: "OMX.google.h264.decoder"

    /**
     * Claves de baja latencia de cada fabricante (las mismas que usan otros clientes de streaming).
     * Se ponen solo en los decoders de ese fabricante.
     */
    fun applyLowLatency(name: String, format: MediaFormat) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        val n = name.lowercase(Locale.ROOT)
        when {
            n.contains("qcom") || n.contains("qti") -> {
                // Medido en la P11 Pro: lo que evita que retenga frames es OMX.qcom con un SPS de 1
                // referencia; picture-order no cambió nada medible, pero no molesta.
                format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
                format.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
            }
            n.contains("exynos") -> format.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1)
            n.contains("hisi") -> {
                format.setInteger("vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req", 1)
                format.setInteger("vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-rdy", -1)
            }
            n.contains("amlogic") -> format.setInteger("vendor.low-latency.enable", 1)
        }
    }

    /** Un MediaFormat para el primer keyframe de un stream, con SPS y PPS como csd. */
    fun format(name: String, w: Int, h: Int, keyframe: ByteArray): MediaFormat? {
        val nals = Decoder.splitNals(keyframe)
        val sps = nals.firstOrNull { it.isNotEmpty() && it[0].toInt() and 0x1F == 7 } ?: return null
        val pps = nals.firstOrNull { it.isNotEmpty() && it[0].toInt() and 0x1F == 8 } ?: return null
        val start = byteArrayOf(0, 0, 0, 1)
        return MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(start + sps))
            setByteBuffer("csd-1", java.nio.ByteBuffer.wrap(start + pps))
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, w * h)   // un keyframe entra holgado
            setInteger(MediaFormat.KEY_PRIORITY, 0)              // tiempo real
            applyLowLatency(name, this)
        }
    }

    private fun loadClip(context: Context): List<Wire.Incoming.Video> {
        val reader = Wire.Reader(context.assets.open("calibration.bin"))
        val frames = ArrayList<Wire.Incoming.Video>()
        while (true) {
            val msg = try { reader.next() } catch (_: java.io.EOFException) { break }
            if (msg is Wire.Incoming.Video) frames.add(msg)
        }
        return frames
    }

    /** Le da el clip de a un frame al decoder, con salida a una Surface como en la transmisión. */
    private fun trial(name: String, clip: List<Wire.Incoming.Video>): Trial {
        val w = 1280
        val h = 800
        val format = format(name, w, h, clip.first().annexB()) ?: return Trial(name, 0, 0.0, "clip sin SPS/PPS")
        val thread = HandlerThread("TabMonitor-calibration-out").apply { start() }
        val reader = ImageReader.newInstance(w, h, ImageFormat.PRIVATE, 4)
        reader.setOnImageAvailableListener({ it.acquireLatestImage()?.close() }, Handler(thread.looper))
        var codec: MediaCodec? = null
        return try {
            codec = MediaCodec.createByCodecName(name)
            codec.configure(format, reader.surface, null, 0)
            codec.start()
            val info = MediaCodec.BufferInfo()
            val delays = ArrayList<Double>()
            var retained = 0
            for ((i, frame) in clip.withIndex()) {
                val input = codec.dequeueInputBuffer(200_000)
                if (input < 0) return Trial(name, retained, 0.0, "sin buffer de entrada en el frame $i")
                val buffer = codec.getInputBuffer(input)!!
                buffer.clear()
                buffer.put(frame.data, frame.offset, frame.length)
                val pts = i * 16_667L
                val queued = System.nanoTime()
                codec.queueInputBuffer(input, 0, frame.length, pts, 0)
                var outMs: Double? = null
                while (outMs == null && System.nanoTime() - queued < WAIT_MS * 1_000_000) {
                    val out = codec.dequeueOutputBuffer(info, 2_000)
                    if (out >= 0) {
                        codec.releaseOutputBuffer(out, true)
                        if (info.presentationTimeUs == pts) outMs = (System.nanoTime() - queued) / 1e6
                    }
                }
                if (i >= WARMUP) {
                    if (outMs != null) delays.add(outMs) else retained++
                }
                if (retained >= MAX_RETAINED) break
            }
            delays.sort()
            Trial(name, retained, if (delays.isEmpty()) WAIT_MS.toDouble() else delays[delays.size / 2])
        } catch (e: Exception) {
            Trial(name, 0, 0.0, e.javaClass.simpleName + (e.message?.let { " $it" } ?: ""))
        } finally {
            codec?.let {
                try { it.stop() } catch (_: Exception) {}
                it.release()
            }
            reader.close()
            thread.quitSafely()
        }
    }

    /** Lo que dice soportar el decoder elegido, para el `hello`. */
    class Capabilities(val maxW: Int, val maxH: Int, val fps: Int, val w60: Int, val h60: Int, val bitrate: Int)

    fun capabilities(name: String, screenW: Int, screenH: Int): Capabilities {
        val info = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { it.name == name }
            ?: return Capabilities(screenW, screenH, 60, screenW, screenH, 0)
        val caps = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).videoCapabilities
        val fps = when {
            caps.areSizeAndRateSupported(screenW, screenH, 60.0) -> 60
            caps.isSizeSupported(screenW, screenH) -> caps.getSupportedFrameRatesFor(screenW, screenH).upper.toInt().coerceAtMost(60)
            else -> 0
        }
        val (w60, h60) = largestAt60(screenW, screenH) { w, h -> caps.areSizeAndRateSupported(w, h, 60.0) }
        return Capabilities(caps.supportedWidths.upper, caps.supportedHeights.upper, fps, w60, h60, caps.bitrateRange.upper)
    }

    /** Lo más grande con la proporción de la pantalla que [supported] acepta a 60 fps; 0×0 si nada. */
    fun largestAt60(screenW: Int, screenH: Int, supported: (Int, Int) -> Boolean): Pair<Int, Int> {
        var w = screenW / 2 * 2
        while (w >= 320) {
            val h = Math.round(w.toDouble() * screenH / screenW / 2).toInt() * 2
            if (supported(w, h)) return w to h
            w -= 16
        }
        return 0 to 0
    }
}
