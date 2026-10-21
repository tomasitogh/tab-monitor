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

    fun hello(w: Int, h: Int, model: String, android: String, maxW: Int, maxH: Int, maxFps: Int): ByteArray =
        message(HELLO, ("{\"w\":$w,\"h\":$h,\"model\":${JSONObject.quote(model)},\"android\":${JSONObject.quote(android)}," +
            "\"maxDecode\":{\"w\":$maxW,\"h\":$maxH,\"fps\":$maxFps}}").toByteArray())

    fun key(): ByteArray = message(KEY)

    fun ping(ts: Long): ByteArray = message(PING, "{\"ts\":$ts}".toByteArray())

    fun stats(fps: Double, latencyAvg: Double, latencyP95: Double, decodeMs: Double, dropped: Int): ByteArray =
        message(STATS, ("{\"fps\":${round1(fps)},\"latencyMs\":{\"avg\":${round1(latencyAvg)},\"p95\":${round1(latencyP95)}}," +
            "\"decodeMs\":${round1(decodeMs)},\"dropped\":$dropped}").toByteArray())

    private fun round1(x: Double): Double = Math.round(x * 10) / 10.0

    sealed class Incoming {
        /** [annexB] son unidades NAL con `00 00 00 01` adelante; los keyframes traen SPS y PPS. */
        class Video(val keyframe: Boolean, val captureMicros: Long, val annexB: ByteArray) : Incoming()
        data class Config(val codec: String, val w: Int, val h: Int, val fps: Int, val bitrate: Int) : Incoming()
        data class Pong(val ts: Long, val mac: Long) : Incoming()
    }

    class ProtocolException(message: String) : IOException(message)

    /** Lee mensajes de la Mac. Saltea los tipos que no conoce y los que solo manda la tablet. */
    class Reader(input: InputStream) {
        private val input = DataInputStream(input)

        /** Bloquea hasta el próximo mensaje; EOFException si la Mac cerró. */
        fun next(): Incoming {
            while (true) {
                val type = input.readUnsignedByte()
                val length = input.readInt()
                if (length < 0 || length > MAX_PAYLOAD) throw ProtocolException("mensaje de $length bytes")
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
            Incoming.Video(payload[0].toInt() and 1 != 0, micros, payload.copyOfRange(9, payload.size))
        }
        CONFIG -> JSONObject(String(payload)).let {
            Incoming.Config(it.optString("codec"), it.getInt("w"), it.getInt("h"), it.optInt("fps", 60), it.optInt("bitrate"))
        }
        PONG -> JSONObject(String(payload)).let { Incoming.Pong(it.getLong("ts"), it.getLong("mac")) }
        else -> null
    }
}
