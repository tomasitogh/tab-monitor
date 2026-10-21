package dev.tabmonitor

import android.util.Log
import java.io.BufferedOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * El socket a la Mac (127.0.0.1:8081, que `adb reverse` lleva por el cable). Reintenta cada
 * segundo hasta que la Mac escuche; al conectar manda `hello`, después `ping` cada 1 s y `stats`
 * cada 2 s (PROTOCOL.md).
 *
 * Al desenchufar el cable, `adbd` no cierra el socket: la conexión parece viva y la imagen queda
 * congelada. Por eso se corta si no llega nada en [SILENCE_MILLIS] (el pong llega cada segundo
 * aunque la pantalla esté quieta), y el visor la corta al instante con [drop] cuando Android avisa
 * que se desconectó el USB.
 */
class Connection(private val hello: ByteArray, private val listener: Listener) {
    interface Listener {
        /** Llegó el primer mensaje de la Mac: no alcanza con conectar, `adbd` acepta sin cable. */
        fun onConnected()
        fun onConfig(config: Wire.Incoming.Config)
        fun onVideo(frame: Wire.Incoming.Video)
        fun onDisconnected(reason: String)
        /** Los stats de los últimos 2 s, para mandarlos y mostrarlos. */
        fun collectStats(): ByteArray?
    }

    val clock = Clock()
    private val pool = Wire.BufferPool()

    @Volatile private var running = true
    @Volatile private var socket: Socket? = null
    @Volatile private var out: OutputStream? = null
    private var timers: ScheduledExecutorService? = null
    @Volatile private var lastReceived = 0L
    @Volatile private var dropReason: String? = null

    private val thread = Thread({ loop() }, "TabMonitor-net").apply {
        priority = Thread.MAX_PRIORITY
        start()
    }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: IOException) {}
        thread.interrupt()
    }

    /** Corta la conexión actual (después se reintenta como siempre). */
    fun drop(reason: String) {
        val socket = socket ?: return
        dropReason = reason
        try { socket.close() } catch (_: IOException) {}
    }

    fun requestKeyframe() = send(Wire.key())

    private fun send(bytes: ByteArray) {
        val out = out ?: return
        try {
            synchronized(out) {
                out.write(bytes)
                out.flush()
            }
        } catch (e: IOException) {
            try { socket?.close() } catch (_: IOException) {}
        }
    }

    private fun loop() {
        while (running) {
            val socket = Socket()
            var connected = false
            try {
                socket.tcpNoDelay = true
                socket.receiveBufferSize = 1 shl 20
                socket.connect(InetSocketAddress("127.0.0.1", PORT), 1000)
                this.socket = socket
                out = BufferedOutputStream(socket.getOutputStream())
                clock.reset()
                lastReceived = Clock.nowMillis()
                send(hello)
                startTimers()

                val reader = Wire.Reader(socket.getInputStream(), pool)
                while (running) {
                    val msg = reader.next()
                    lastReceived = Clock.nowMillis()
                    if (!connected) {
                        connected = true
                        Log.i(TAG, "conectado a la Mac")
                        listener.onConnected()
                    }
                    when (msg) {
                        is Wire.Incoming.Video -> listener.onVideo(msg)
                        is Wire.Incoming.Config -> listener.onConfig(msg)
                        is Wire.Incoming.Pong -> clock.onPong(msg.ts, Clock.nowMillis(), msg.mac)
                    }
                }
            } catch (e: IOException) {
                val reason = dropReason ?: if (e is EOFException) REASON_CLOSED else e.message ?: e.toString()
                dropReason = null
                if (connected) {
                    Log.i(TAG, "desconectado: $reason")
                    listener.onDisconnected(reason)
                }
            } finally {
                stopTimers()
                out = null
                this.socket = null
                try { socket.close() } catch (_: IOException) {}
            }
            if (running) try { Thread.sleep(1000) } catch (_: InterruptedException) {}
        }
    }

    private fun startTimers() {
        timers = Executors.newSingleThreadScheduledExecutor().apply {
            scheduleWithFixedDelay({ send(Wire.ping(Clock.nowMillis())) }, 0, 1, TimeUnit.SECONDS)
            scheduleWithFixedDelay({ listener.collectStats()?.let(::send) }, 2, 2, TimeUnit.SECONDS)
            scheduleWithFixedDelay({
                if (Clock.nowMillis() - lastReceived > SILENCE_MILLIS) drop(REASON_SILENT)
            }, SILENCE_MILLIS, 500, TimeUnit.MILLISECONDS)
        }
    }

    private fun stopTimers() {
        timers?.shutdownNow()
        timers = null
    }

    companion object {
        const val TAG = "TabMonitor"
        const val PORT = 8081
        const val SILENCE_MILLIS = 3000L
        const val REASON_UNPLUGGED = "Se desenchufó el cable"
        const val REASON_SILENT = "La Mac no responde: puede estar dormida"
        const val REASON_CLOSED = "TabMonitor se cerró en la Mac"
    }
}

/**
 * Pasa horas de la tablet al reloj de la Mac con ping/pong: desfase = mac − (envío + recepción)/2,
 * tomando el de menor ida y vuelta de las últimas muestras (PROTOCOL.md).
 */
class Clock {
    private data class Sample(val rttMillis: Long, val offsetMillis: Double)
    private val samples = ArrayDeque<Sample>()

    @Synchronized fun reset() = samples.clear()

    @Synchronized fun onPong(sentMillis: Long, receivedMillis: Long, macMillis: Long) {
        samples.addLast(Sample(receivedMillis - sentMillis, macMillis - (sentMillis + receivedMillis) / 2.0))
        while (samples.size > 10) samples.removeFirst()
    }

    /** Desfase en ms (mac − tablet), o null si todavía no hubo pong. */
    @Synchronized fun offsetMillis(): Double? = samples.minByOrNull { it.rttMillis }?.offsetMillis

    @Synchronized fun bestRttMillis(): Long? = samples.minOfOrNull { it.rttMillis }

    companion object {
        /** El reloj de la tablet: monotónico, la misma base que el OnFrameRenderedListener. */
        fun nowMillis(): Long = System.nanoTime() / 1_000_000
    }
}
