package dev.tabmonitor

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * El visor: una SurfaceView a pantalla completa donde el Decoder dibuja el monitor virtual.
 * La conexión vive mientras existe la Surface; al salir de la app se corta y la Mac quita el monitor.
 * Un toque muestra u oculta las estadísticas.
 *
 * Enchufar y usar: la Mac lo abre por adb aunque la tablet esté bloqueada (showWhenLocked y
 * turnScreenOn en el manifiesto). La pantalla queda encendida solo mientras hay conexión, y si la
 * Mac no aparece en [IDLE_FINISH_MS] el visor se cierra para que la tablet vuelva a lo suyo.
 */
class MainActivity : Activity(), SurfaceHolder.Callback, Connection.Listener, Decoder.Listener {
    private lateinit var surfaceView: SurfaceView
    /** Estadísticas chicas arriba a la izquierda, con un toque. */
    private lateinit var statusText: TextView
    /** El cartel grande del centro: esperando, desconectado. */
    private lateinit var card: LinearLayout
    private lateinit var cardTitle: TextView
    private lateinit var cardDetail: TextView

    private var connection: Connection? = null
    private var decoder: Decoder? = null
    private val stats = Stats()
    @Volatile private var showStats = false
    @Volatile private var streaming = false
    private val main = Handler(Looper.getMainLooper())
    private val finishIfIdle = Runnable {
        Log.i(TAG, "sin la Mac por ${IDLE_FINISH_MS / 1000} s: se cierra el visor")
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        surfaceView = SurfaceView(this)
        statusText = TextView(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.argb(160, 0, 0, 0))
            textSize = 16f
            setPadding(24, 16, 24, 16)
        }
        cardTitle = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 34f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
        }
        cardDetail = TextView(this).apply {
            setTextColor(Color.argb(220, 255, 255, 255))
            textSize = 22f
            gravity = Gravity.CENTER
            setPadding(0, 24, 0, 0)
        }
        card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(72, 56, 72, 56)
            background = GradientDrawable().apply {
                setColor(Color.argb(230, 32, 32, 36))
                cornerRadius = 36f
            }
            addView(cardTitle)
            addView(cardDetail)
        }
        val center = FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT)
        center.gravity = Gravity.CENTER
        val fill = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        val corner = FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT)
        corner.gravity = Gravity.TOP or Gravity.START
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(surfaceView, fill)
            addView(statusText, corner)
            addView(card, center)
            setOnClickListener {
                showStats = !showStats
                updateOverlay(null)
            }
        }
        setContentView(root)
        surfaceView.holder.addCallback(this)
        showCard("Esperando a la Mac", "Abrí TabMonitor en la Mac y dejá el cable enchufado.")
        updateOverlay(null)
        main.postDelayed(finishIfIdle, IDLE_FINISH_MS)
        val filter = IntentFilter(USB_STATE)
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(usbState, filter, Context.RECEIVER_NOT_EXPORTED)
        else registerReceiver(usbState, filter)
    }

    override fun onDestroy() {
        main.removeCallbacks(finishIfIdle)
        unregisterReceiver(usbState)
        super.onDestroy()
    }

    /** Android avisa al instante cuando se desconecta el USB; adbd no cierra el socket. */
    private val usbState = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (!intent.getBooleanExtra("connected", true)) connection?.drop(Connection.REASON_UNPLUGGED)
        }
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
        showCard("Conectado", "Esperando la imagen…")
        runOnUiThread {
            main.removeCallbacks(finishIfIdle)
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    override fun onConfig(config: Wire.Incoming.Config) {
        Log.i(TAG, "config: $config")
        decoder?.configure(config.w, config.h)
    }

    override fun onVideo(frame: Wire.Incoming.Video) {
        stats.received(frame.length, frame.captureMicros, System.nanoTime(), connection?.clock?.offsetMillis())
        decoder?.submit(frame) ?: frame.release()
    }

    override fun onDisconnected(reason: String) {
        streaming = false
        showCard(reason, "Volvé a enchufar el cable o despertá la Mac.\nSi no, el visor se cierra solo en ${IDLE_FINISH_MS / 1000} segundos.")
        runOnUiThread {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            main.removeCallbacks(finishIfIdle)
            main.postDelayed(finishIfIdle, IDLE_FINISH_MS)
        }
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
            showCard(null, null)
        }
    }

    override fun onDecoded(decodeNanos: Long) = stats.decoded(decodeNanos)

    override fun onDropped(count: Int) = stats.dropped(count)

    // --- Overlay -----------------------------------------------------------------------------

    /** [status] reemplaza el texto; null muestra las estadísticas si están pedidas, o nada. */
    private fun updateOverlay(status: String?) = runOnUiThread {
        val text = status ?: if (showStats) stats.lastSummary else null
        statusText.text = text ?: ""
        statusText.visibility = if (text.isNullOrEmpty()) View.GONE else View.VISIBLE
    }

    /** El cartel del centro; null lo oculta. */
    private fun showCard(title: String?, detail: String?) = runOnUiThread {
        card.visibility = if (title == null) View.GONE else View.VISIBLE
        cardTitle.text = title ?: ""
        cardDetail.text = detail ?: ""
    }

    companion object {
        const val TAG = "TabMonitor"
        const val IDLE_FINISH_MS = 30_000L
        /** android.hardware.usb.action.USB_STATE: oculta en el SDK, pero es una difusión del sistema. */
        const val USB_STATE = "android.hardware.usb.action.USB_STATE"
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
    private val arrivals = ArrayList<Double>()
    private val decodes = ArrayList<Double>()
    @Volatile var lastSummary = ""
        private set

    @Synchronized fun reset() {
        since = System.nanoTime()
        rendered = 0; bytes = 0; dropped = 0
        latencies.clear(); decodes.clear(); arrivals.clear()
    }

    /** Llegada = hora en que se terminó de leer el frame, en el reloj de la Mac, menos captura. */
    @Synchronized fun received(size: Int, captureMicros: Long, arrivalNanos: Long, offsetMillis: Double?) {
        bytes += size
        if (offsetMillis != null) arrivals.add(arrivalNanos / 1e6 + offsetMillis - captureMicros / 1e3)
    }
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
        val arr = arrivals.sorted()
        val arrAvg = if (arr.isEmpty()) 0.0 else arr.average()
        val arrP95 = if (arr.isEmpty()) 0.0 else arr[minOf(arr.size - 1, arr.size * 95 / 100)]
        val fps = rendered / seconds
        val summary = String.format(java.util.Locale.ROOT,
            "%.1f fps, %.1f Mbps, latencia %.1f / p95 %.1f / máx %.1f ms, llegada %.1f / p95 %.1f ms, decode %.1f ms, descartados %d, ping %s ms",
            fps, bytes * 8 / seconds / 1e6, avg, p95, max, arrAvg, arrP95, decode, dropped, clock?.bestRttMillis()?.toString() ?: "—")
        val snap = Snapshot(fps, avg, p95, decode, dropped, summary)
        lastSummary = summary
        since = now
        rendered = 0; bytes = 0; dropped = 0
        latencies.clear(); decodes.clear(); arrivals.clear()
        return snap
    }
}
