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
 */
class Connection(private val hello: ByteArray, private val listener: Listener) {
    interface Listener {
        fun onConnected()
        fun onConfig(config: Wire.Incoming.Config)
        fun onVideo(frame: Wire.Incoming.Video)
        fun onDisconnected(reason: String)
        /** Los stats de los últimos 2 s, para mandarlos y mostrarlos. */
        fun collectStats(): ByteArray?
    }

    val clock = Clock()

    @Volatile private var running = true
    @Volatile private var socket: Socket? = null
    @Volatile private var out: OutputStream? = null
    private var timers: ScheduledExecutorService? = null

    private val thread = Thread({ loop() }, "TabMonitor-net").apply {
        priority = Thread.MAX_PRIORITY
        start()
    }

    fun stop() {
        running = false
        try { socket?.close() } catch (_: IOException) {}
        thread.interrupt()
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
            try {
                socket.tcpNoDelay = true
                socket.receiveBufferSize = 1 shl 20
                socket.connect(InetSocketAddress("127.0.0.1", PORT), 1000)
                this.socket = socket
                out = BufferedOutputStream(socket.getOutputStream())
                Log.i(TAG, "conectado a la Mac")
                clock.reset()
                listener.onConnected()
                send(hello)
                startTimers()

                val reader = Wire.Reader(socket.getInputStream())
                while (running) {
                    when (val msg = reader.next()) {
                        is Wire.Incoming.Video -> listener.onVideo(msg)
                        is Wire.Incoming.Config -> listener.onConfig(msg)
                        is Wire.Incoming.Pong -> clock.onPong(msg.ts, Clock.nowMillis(), msg.mac)
                    }
                }
            } catch (e: IOException) {
                val reason = if (e is EOFException) "la Mac cerró la conexión" else e.message ?: e.toString()
                if (this.socket != null) {
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
        }
    }

    private fun stopTimers() {
        timers?.shutdownNow()
        timers = null
    }

    companion object {
        const val TAG = "TabMonitor"
        const val PORT = 8081
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
