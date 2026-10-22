package dev.tabmonitor

import org.json.JSONObject
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream

/** El protocolo de PROTOCOL.md: encabezado de 5 bytes (tipo, largo big-endian) y contenido. */
object Wire {
    const val VIDEO = 0x01
    const val HELLO = 0x10
    const val CONFIG = 0x11
    const val KEY = 0x12
    const val PING = 0x13
    const val PONG = 0x14
    const val STATS = 0x15

    const val HEADER_SIZE = 5
    const val MAX_PAYLOAD = 16 * 1024 * 1024

    fun message(type: Int, payload: ByteArray = ByteArray(0)): ByteArray {
        val out = ByteArray(HEADER_SIZE + payload.size)
        val n = payload.size
        out[0] = type.toByte()
        out[1] = (n ushr 24).toByte()
        out[2] = (n ushr 16).toByte()
        out[3] = (n ushr 8).toByte()
        out[4] = n.toByte()
        payload.copyInto(out, HEADER_SIZE)
        return out
    }

    // El JSON de la tablet se arma a mano para que salga en el orden de PROTOCOL.md
    // (JSONObject no garantiza el orden de las claves).

    /** Lo que la tablet cuenta de sí misma al conectar (ver PROTOCOL.md). */
    data class Hello(
        val w: Int, val h: Int, val dpi: Double, val model: String, val android: String, val id: String,
        val decoder: String, val maxW: Int, val maxH: Int, val maxFps: Int, val w60: Int, val h60: Int, val maxBitrate: Int,
    )

    fun hello(h: Hello): ByteArray =
        message(HELLO, ("{\"w\":${h.w},\"h\":${h.h},\"dpi\":${round1(h.dpi)},\"model\":${JSONObject.quote(h.model)}," +
            "\"android\":${JSONObject.quote(h.android)},\"id\":${JSONObject.quote(h.id)},\"decoder\":${JSONObject.quote(h.decoder)}," +
            "\"maxDecode\":{\"w\":${h.maxW},\"h\":${h.maxH},\"fps\":${h.maxFps},\"w60\":${h.w60},\"h60\":${h.h60}," +
            "\"bitrate\":${h.maxBitrate}}}").toByteArray())

    fun key(): ByteArray = message(KEY)

    fun ping(ts: Long): ByteArray = message(PING, "{\"ts\":$ts}".toByteArray())

    fun stats(fps: Double, latencyAvg: Double, latencyP95: Double, decodeMs: Double, dropped: Int): ByteArray =
        message(STATS, ("{\"fps\":${round1(fps)},\"latencyMs\":{\"avg\":${round1(latencyAvg)},\"p95\":${round1(latencyP95)}}," +
            "\"decodeMs\":${round1(decodeMs)},\"dropped\":$dropped}").toByteArray())

    private fun round1(x: Double): Double = Math.round(x * 10) / 10.0

    sealed class Incoming {
        /**
         * Unidades NAL con `00 00 00 01` adelante (los keyframes traen SPS y PPS), en
         * `data[offset until offset + length]`. [data] viene de un [BufferPool]: quien termine con
         * el frame llama a [release] y no lo vuelve a tocar.
         */
        class Video(val keyframe: Boolean, val captureMicros: Long, val data: ByteArray, val offset: Int, val length: Int,
                    private val pool: BufferPool? = null) : Incoming() {
            fun annexB(): ByteArray = data.copyOfRange(offset, offset + length)
            fun release() { pool?.give(data) }
        }
        data class Config(val codec: String, val w: Int, val h: Int, val fps: Int, val bitrate: Int) : Incoming()
        data class Pong(val ts: Long, val mac: Long) : Incoming()
    }

    class ProtocolException(message: String) : IOException(message)

    /**
     * Arreglos reutilizables para el video: a 60 fps, crear uno por frame (50–500 KB) le daba al
     * recolector decenas de MB por segundo y el visor usaba 57–70 % de un núcleo.
     */
    class BufferPool(private val max: Int = 8) {
        private val free = ArrayDeque<ByteArray>()

        /** Un arreglo de al menos [size] bytes. */
        @Synchronized fun take(size: Int): ByteArray {
            val i = free.indexOfFirst { it.size >= size }
            return if (i >= 0) free.removeAt(i) else ByteArray(maxOf(size, 256 * 1024))
        }

        @Synchronized fun give(buffer: ByteArray) {
            if (free.size < max) free.addLast(buffer)
        }
    }

    /** Lee mensajes de la Mac. Saltea los tipos que no conoce y los que solo manda la tablet. */
    class Reader(input: InputStream, private val pool: BufferPool? = null) {
        private val input = DataInputStream(input)

        /** Bloquea hasta el próximo mensaje; EOFException si la Mac cerró. */
        fun next(): Incoming {
            while (true) {
                val type = input.readUnsignedByte()
                val length = input.readInt()
                if (length < 0 || length > MAX_PAYLOAD) throw ProtocolException("mensaje de $length bytes")
                if (type == VIDEO) {
                    if (length < 9) throw ProtocolException("frame de video de $length bytes")
                    val flags = input.readUnsignedByte()
                    val micros = input.readLong()
                    val data = pool?.take(length - 9) ?: ByteArray(length - 9)
                    input.readFully(data, 0, length - 9)
                    return Incoming.Video(flags and 1 != 0, micros, data, 0, length - 9, pool)
                }
                val payload = ByteArray(length)
                input.readFully(payload)
                decode(type, payload)?.let { return it }
            }
        }
    }

    fun decode(type: Int, payload: ByteArray): Incoming? = when (type) {
        VIDEO -> {
            if (payload.size < 9) throw ProtocolException("frame de video de ${payload.size} bytes")
            var micros = 0L
            for (i in 1..8) micros = (micros shl 8) or (payload[i].toLong() and 0xFF)
            Incoming.Video(payload[0].toInt() and 1 != 0, micros, payload, 9, payload.size - 9)
        }
        CONFIG -> JSONObject(String(payload)).let {
            Incoming.Config(it.optString("codec"), it.getInt("w"), it.getInt("h"), it.optInt("fps", 60), it.optInt("bitrate"))
        }
        PONG -> JSONObject(String(payload)).let { Incoming.Pong(it.getLong("ts"), it.getLong("mac")) }
        else -> null
    }
}
