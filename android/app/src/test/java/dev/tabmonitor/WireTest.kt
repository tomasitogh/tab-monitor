package dev.tabmonitor

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream

/** Los bytes de ejemplo de PROTOCOL.md; los tests de la Mac usan los mismos. */
class WireTest {
    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()
    private fun message(header: String, json: String) = hex(header) + json.toByteArray()

    @Test fun hello() {
        val expected = message("10 00 00 00 CB",
            """{"w":2560,"h":1600,"dpi":262.5,"model":"TB-J706F","android":"12","id":"3f9a0c1e","decoder":"OMX.qcom.video.decoder.avc","maxDecode":{"w":3840,"h":2160,"fps":60,"w60":2560,"h60":1600,"bitrate":100000000}}""")
        val hello = Wire.Hello(2560, 1600, 262.5, "TB-J706F", "12", "3f9a0c1e", "OMX.qcom.video.decoder.avc",
            3840, 2160, 60, 2560, 1600, 100_000_000)
        assertArrayEquals(expected, Wire.hello(hello))
    }

    @Test fun key() = assertArrayEquals(hex("12 00 00 00 00"), Wire.key())

    @Test fun ping() = assertArrayEquals(message("13 00 00 00 0D", """{"ts":123456}"""), Wire.ping(123456))

    @Test fun stats() {
        val expected = message("15 00 00 00 4B",
            """{"fps":59.8,"latencyMs":{"avg":38.2,"p95":51.0},"decodeMs":6.1,"dropped":0}""")
        assertArrayEquals(expected, Wire.stats(59.8, 38.2, 51.0, 6.1, 0))
    }

    @Test fun incoming() {
        val nal = hex("00 00 00 01 67 42 00 1F 00 00 00 01 68 CE 3C 80 00 00 00 01 65 88 84")
        val video = hex("01 00 00 00 20 01 00 00 00 00 00 0F 42 40") + nal
        val config = message("11 00 00 00 3E", """{"codec":"h264","w":2560,"h":1600,"fps":60,"bitrate":35000000}""")
        val unknown = hex("7F 00 00 00 02 AA BB")
        val pong = message("14 00 00 00 1A", """{"ts":123456,"mac":987654}""")
        val reader = Wire.Reader(ByteArrayInputStream(video + config + unknown + pong))

        val v = reader.next() as Wire.Incoming.Video
        assertTrue(v.keyframe)
        assertEquals(1_000_000L, v.captureMicros)
        assertArrayEquals(nal, v.annexB())
        assertEquals(Wire.Incoming.Config("h264", 2560, 1600, 60, 35_000_000), reader.next())
        assertEquals(Wire.Incoming.Pong(123456, 987654), reader.next())
    }

    @Test fun pooledBuffersAreReused() {
        val pool = Wire.BufferPool()
        val video = hex("01 00 00 00 0B 00 00 00 00 00 00 00 00 01 AA BB")
        val reader = Wire.Reader(ByteArrayInputStream(video + video), pool)
        val first = reader.next() as Wire.Incoming.Video
        assertArrayEquals(hex("AA BB"), first.annexB())
        first.release()
        val second = reader.next() as Wire.Incoming.Video
        assertTrue(first.data === second.data)
    }

    @Test(expected = Wire.ProtocolException::class)
    fun tooLarge() {
        Wire.Reader(ByteArrayInputStream(hex("01 01 00 00 01"))).next()
    }
}
