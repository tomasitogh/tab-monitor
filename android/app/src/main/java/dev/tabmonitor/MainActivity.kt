package dev.tabmonitor

import android.app.Activity
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView

/**
 * El visor: una SurfaceView a pantalla completa donde el Decoder dibuja el monitor virtual.
 * La conexión vive mientras existe la Surface; al salir de la app se corta y la Mac quita el monitor.
 * Un toque muestra u oculta las estadísticas.
 */
class MainActivity : Activity(), SurfaceHolder.Callback, Connection.Listener, Decoder.Listener {
    private lateinit var surfaceView: SurfaceView
    private lateinit var statusText: TextView

    private var connection: Connection? = null
    private var decoder: Decoder? = null
    private val stats = Stats()
    @Volatile private var showStats = false
    @Volatile private var streaming = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        surfaceView = SurfaceView(this)
        statusText = TextView(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.argb(160, 0, 0, 0))
            textSize = 16f
            setPadding(24, 16, 24, 16)
        }
        val fill = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        val corner = FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT)
        corner.gravity = Gravity.TOP or Gravity.START
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(surfaceView, fill)
            addView(statusText, corner)
            setOnClickListener {
                showStats = !showStats
                updateOverlay(null)
            }
        }
        setContentView(root)
        surfaceView.holder.addCallback(this)
        updateOverlay("Esperando a la Mac…")
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.apply {
                hide(WindowInsets.Type.systemBars())
                systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        }
    }

    // --- Surface: la conexión y el decoder existen mientras haya dónde dibujar ---------------

    override fun surfaceCreated(holder: SurfaceHolder) {
        // Diagnóstico: adb shell am start -n dev.tabmonitor/.MainActivity --es decoder OMX.qcom.video.decoder.avc
        decoder = Decoder(holder.surface, this, intent.getStringExtra("decoder"))
        val (w, h) = screenSize()
        val (maxW, maxH, maxFps) = Decoder.maxDecode(w, h)
        Log.i(TAG, "pantalla ${w}×$h, decoder hasta ${maxW}×$maxH, $maxFps fps a este tamaño")
        val hello = Wire.hello(w, h, Build.MODEL, Build.VERSION.RELEASE, maxW, maxH, maxFps)
        connection = Connection(hello, this)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        connection?.stop()
        connection = null
        decoder?.stop()
        decoder = null
        streaming = false
    }

    @Suppress("DEPRECATION")
    private fun screenSize(): Pair<Int, Int> {
        val (a, b) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            windowManager.maximumWindowMetrics.bounds.let { it.width() to it.height() }
        } else {
            android.util.DisplayMetrics().also { windowManager.defaultDisplay.getRealMetrics(it) }.let { it.widthPixels to it.heightPixels }
        }
        return maxOf(a, b) to minOf(a, b)   // siempre horizontal
    }

    // --- Connection.Listener (hilo de red) ---------------------------------------------------

    override fun onConnected() {
        stats.reset()
        updateOverlay("Conectado, esperando video…")
    }

    override fun onConfig(config: Wire.Incoming.Config) {
        Log.i(TAG, "config: $config")
        decoder?.configure(config.w, config.h)
    }

    override fun onVideo(frame: Wire.Incoming.Video) {
        stats.received(frame.annexB.size)
        decoder?.submit(frame)
    }

    override fun onDisconnected(reason: String) {
        streaming = false
        updateOverlay("Esperando a la Mac… ($reason)")
    }

    override fun collectStats(): ByteArray? {
        val snapshot = stats.snapshot(connection?.clock) ?: return null
        Log.i(TAG, "stats: ${snapshot.summary}")
        if (showStats) updateOverlay(null)
        return Wire.stats(snapshot.fps, snapshot.latencyAvg, snapshot.latencyP95, snapshot.decodeAvg, snapshot.dropped)
    }

    // --- Decoder.Listener (hilo del decoder) -------------------------------------------------

    override fun onKeyframeNeeded() {
        connection?.requestKeyframe()
    }

    override fun onRendered(captureMicros: Long, renderNanos: Long) {
        stats.rendered(captureMicros, renderNanos, connection?.clock?.offsetMillis())
        if (!streaming) {
            streaming = true
            updateOverlay(null)
        }
    }

    override fun onDecoded(decodeNanos: Long) = stats.decoded(decodeNanos)

    override fun onDropped(count: Int) = stats.dropped(count)

    // --- Overlay -----------------------------------------------------------------------------

    /** [status] reemplaza el texto; null muestra las estadísticas si están pedidas, o nada. */
    private fun updateOverlay(status: String?) = runOnUiThread {
        val text = status ?: if (showStats) stats.lastSummary else null
        statusText.text = text ?: ""
        statusText.visibility = if (text.isNullOrEmpty() || (streaming && status == null && !showStats)) View.GONE else View.VISIBLE
    }

    companion object {
        const val TAG = "TabMonitor"
    }
}

/** Contadores de los últimos 2 s, para `stats` y el texto en pantalla. */
class Stats {
    class Snapshot(val fps: Double, val latencyAvg: Double, val latencyP95: Double, val decodeAvg: Double,
                   val dropped: Int, val summary: String)

    private var since = System.nanoTime()
    private var rendered = 0
    private var bytes = 0L
    private var dropped = 0
    private val latencies = ArrayList<Double>()
    private val decodes = ArrayList<Double>()
    @Volatile var lastSummary = ""
        private set

    @Synchronized fun reset() {
        since = System.nanoTime()
        rendered = 0; bytes = 0; dropped = 0
        latencies.clear(); decodes.clear()
    }

    @Synchronized fun received(size: Int) { bytes += size }
    @Synchronized fun dropped(count: Int) { dropped += count }
    @Synchronized fun decoded(nanos: Long) { decodes.add(nanos / 1e6) }

    /** Latencia = hora en que se mostró, pasada al reloj de la Mac, menos hora de captura. */
    @Synchronized fun rendered(captureMicros: Long, renderNanos: Long, offsetMillis: Double?) {
        rendered++
        if (offsetMillis != null) latencies.add(renderNanos / 1e6 + offsetMillis - captureMicros / 1e3)
    }

    @Synchronized fun snapshot(clock: Clock?): Snapshot? {
        val now = System.nanoTime()
        val seconds = (now - since) / 1e9
        if (seconds <= 0) return null
        val lat = latencies.sorted()
        val avg = if (lat.isEmpty()) 0.0 else lat.average()
        val p95 = if (lat.isEmpty()) 0.0 else lat[minOf(lat.size - 1, lat.size * 95 / 100)]
        val max = lat.lastOrNull() ?: 0.0
        val decode = if (decodes.isEmpty()) 0.0 else decodes.average()
        val fps = rendered / seconds
        val summary = String.format(java.util.Locale.ROOT,
            "%.1f fps, %.1f Mbps, latencia %.1f / p95 %.1f / máx %.1f ms, decode %.1f ms, descartados %d, ping %s ms",
            fps, bytes * 8 / seconds / 1e6, avg, p95, max, decode, dropped, clock?.bestRttMillis()?.toString() ?: "—")
        val snap = Snapshot(fps, avg, p95, decode, dropped, summary)
        lastSummary = summary
        since = now
        rendered = 0; bytes = 0; dropped = 0
        latencies.clear(); decodes.clear()
        return snap
    }
}
