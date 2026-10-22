package dev.tabmonitor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DecoderChoiceTest {
    private fun trial(name: String, retained: Int, ms: Double, error: String? = null) =
        DecoderChoice.Trial(name, retained, ms, error)

    /** Lo medido en la P11 Pro: c2.qti retiene y OMX.qcom no; tiene que ganar OMX.qcom. */
    @Test fun prefersNoRetention() {
        val trials = listOf(trial("c2.qti.avc.decoder", 3, 4.0), trial("OMX.qcom.video.decoder.avc", 0, 19.0))
        assertEquals("OMX.qcom.video.decoder.avc", DecoderChoice.best(trials)?.name)
    }

    @Test fun fasterWinsAmongEqualRetention() {
        val trials = listOf(trial("a", 0, 12.0), trial("b", 0, 7.5), trial("c", 1, 3.0))
        assertEquals("b", DecoderChoice.best(trials)?.name)
    }

    @Test fun failedTrialsDoNotCount() {
        val trials = listOf(trial("roto", 0, 0.0, "IllegalStateException"), trial("lento", 3, 100.0))
        assertEquals("lento", DecoderChoice.best(trials)?.name)
        assertNull(DecoderChoice.best(listOf(trial("roto", 0, 0.0, "error"))))
    }

    @Test fun largestAt60KeepsAspect() {
        // P11 Pro: entra la pantalla entera.
        assertEquals(2560 to 1600, DecoderChoice.largestAt60(2560, 1600) { _, _ -> true })
        // Un decoder que solo llega a 1920 de ancho a 60 fps.
        assertEquals(1920 to 1200, DecoderChoice.largestAt60(2560, 1600) { w, _ -> w <= 1920 })
        // S6 Lite (5:3).
        assertEquals(2000 to 1200, DecoderChoice.largestAt60(2000, 1200) { _, _ -> true })
        assertEquals(1600 to 960, DecoderChoice.largestAt60(2000, 1200) { w, h -> w * h <= 1600 * 960 })
        assertEquals(0 to 0, DecoderChoice.largestAt60(2000, 1200) { _, _ -> false })
    }
}
