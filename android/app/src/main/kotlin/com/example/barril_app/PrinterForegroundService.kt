package com.example.barril_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue

/**
 * Foreground Service que mantiene el socket Bluetooth SPP activo y procesa
 * trabajos de impresión aunque la app esté en segundo plano o minimizada.
 *
 * Arquitectura:
 * - Un hilo trabajador bloquea en printQueue.take() esperando jobs
 * - Cada job se ejecuta con pre-flush del firmware (modo papel continuo)
 * - WakeLock evita que el CPU duerma durante la impresión
 * - Notificación persistente (requerida por Android para foreground services)
 */
class PrinterForegroundService : Service() {

    companion object {
        private const val TAG = "PrinterService"
        private const val CHANNEL_ID = "printer_channel_v1"
        private const val NOTIFICATION_ID = 2001
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }

    // ── Binder para que MainActivity se comunique con el servicio ──────────
    inner class PrinterBinder : Binder() {
        fun getService(): PrinterForegroundService = this@PrinterForegroundService
    }
    private val binder = PrinterBinder()

    // ── Estado interno ─────────────────────────────────────────────────────
    data class PrintJob(
        val address: String,
        val bytes: ByteArray,
        val callback: (success: Boolean, error: String?) -> Unit
    )

    private val printQueue = LinkedBlockingQueue<PrintJob>()

    @Volatile private var activeSocket: BluetoothSocket? = null
    @Volatile private var activeAddress: String? = null
    @Volatile private var workerRunning = false
    private var workerThread: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null

    // ──────────────────────────────────────────────────────────────────────
    // Ciclo de vida del Service
    // ──────────────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Impresora lista para imprimir"))
        acquireWakeLock()
        startWorker()
        Log.i(TAG, "PrinterForegroundService creado y en primer plano")
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // START_STICKY: el SO vuelve a lanzar el servicio si lo mata
        return START_STICKY
    }

    override fun onDestroy() {
        Log.i(TAG, "PrinterForegroundService destruido")
        workerRunning = false
        workerThread?.interrupt()
        releaseWakeLock()
        closeSocket()
        super.onDestroy()
    }

    // ──────────────────────────────────────────────────────────────────────
    // API pública (llamada desde MainActivity a través del Binder)
    // ──────────────────────────────────────────────────────────────────────

    fun connect(address: String): Boolean {
        return try {
            if (activeSocket?.isConnected == true && activeAddress == address) {
                Log.d(TAG, "Ya conectado a $address")
                return true
            }
            closeSocket()
            openSocket(address)
            updateNotification("Conectado a la impresora")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error conectando a $address", e)
            false
        }
    }

    fun isConnected(address: String? = null): Boolean {
        val socketOk = activeSocket?.isConnected == true
        return if (address == null) socketOk else socketOk && activeAddress == address
    }

    fun disconnect() {
        closeSocket()
        updateNotification("Impresora desconectada")
    }

    /**
     * Encola un job de impresión. El hilo trabajador lo procesará aunque la
     * app esté en segundo plano. El callback se ejecuta en el hilo del worker.
     */
    fun enqueuePrint(address: String, bytes: ByteArray, callback: (Boolean, String?) -> Unit) {
        printQueue.offer(PrintJob(address, bytes, callback))
        updateNotification("Imprimiendo ticket...")
        Log.d(TAG, "Job encolado para $address (${bytes.size} bytes), cola: ${printQueue.size}")
    }

    // ──────────────────────────────────────────────────────────────────────
    // Hilo trabajador de impresión
    // ──────────────────────────────────────────────────────────────────────

    private fun startWorker() {
        workerRunning = true
        workerThread = Thread {
            Log.i(TAG, "Worker de impresión iniciado")
            while (workerRunning && !Thread.currentThread().isInterrupted) {
                try {
                    val job = printQueue.take()   // bloquea hasta que llegue un job
                    processJob(job)
                } catch (e: InterruptedException) {
                    Log.d(TAG, "Worker interrumpido, saliendo")
                    break
                } catch (e: Exception) {
                    Log.e(TAG, "Error inesperado en worker", e)
                }
            }
            Log.i(TAG, "Worker de impresión terminado")
        }.also {
            it.isDaemon = false     // hilo NO daemon: el SO no lo mata en background
            it.name = "PrinterWorker"
            it.start()
        }
    }

    private fun processJob(job: PrintJob) {
        Log.d(TAG, "Procesando job para ${job.address} (${job.bytes.size} bytes)")
        try {
            // Reconectar si el socket se cerró mientras estaba en background
            if (activeSocket?.isConnected != true || activeAddress != job.address) {
                Log.d(TAG, "Socket caído, reconectando a ${job.address}...")
                openSocket(job.address)
                updateNotification("Reconectando impresora...")
            }

            val out: OutputStream = activeSocket!!.outputStream

            // ── JOB PRINCIPAL (Generado dinámicamente en Dart con ESC/POS puro) ──
            out.write(job.bytes)
            out.flush()

            Log.i(TAG, "✓ Job impreso exitosamente para ${job.address}")
            updateNotification("Ticket impreso correctamente ✓")
            job.callback(true, null)

        } catch (e: Exception) {
            Log.e(TAG, "✗ Error imprimiendo job para ${job.address}", e)
            closeSocket()
            updateNotification("Error al imprimir — reintentando conexión")
            job.callback(false, e.message ?: "Error de impresión")
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Gestión del socket Bluetooth SPP
    // ──────────────────────────────────────────────────────────────────────

    private fun openSocket(address: String) {
        val adapter = BluetoothAdapter.getDefaultAdapter()
            ?: throw IllegalStateException("Bluetooth no disponible")
        adapter.cancelDiscovery()
        val device: BluetoothDevice = adapter.getRemoteDevice(address)

        var socket: BluetoothSocket? = null
        try {
            Log.d(TAG, "Intentando socket inseguro (SPP UUID) para $address")
            socket = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
            socket.connect()
            Log.i(TAG, "Conectado vía Insecure SPP UUID")
        } catch (e1: Exception) {
            Log.w(TAG, "Fallo Insecure SPP: ${e1.message}")
            try {
                Log.d(TAG, "Intentando canal 1 inseguro por reflexión...")
                val method = device.javaClass.getMethod("createInsecureRfcommSocket", Int::class.javaPrimitiveType)
                socket = method.invoke(device, 1) as BluetoothSocket
                socket.connect()
                Log.i(TAG, "Conectado vía Canal 1 Inseguro")
            } catch (e2: Exception) {
                Log.w(TAG, "Fallo Canal Inseguro: ${e2.message}")
                Log.d(TAG, "Intentando socket seguro como último recurso...")
                socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
                socket.connect()
                Log.i(TAG, "Conectado vía Socket Seguro")
            }
        }
        activeSocket = socket
        activeAddress = address
        Log.i(TAG, "Socket abierto y activo para $address")
    }

    private fun closeSocket() {
        try { activeSocket?.close() } catch (_: Exception) {}
        activeSocket = null
        activeAddress = null
        Log.d(TAG, "Socket cerrado")
    }

    // ──────────────────────────────────────────────────────────────────────
    // WakeLock — evita que el CPU duerma durante impresión en background
    // ──────────────────────────────────────────────────────────────────────

    private fun acquireWakeLock() {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "barril_app::PrinterWakeLock"
        ).apply {
            acquire(60 * 60 * 1000L)   // máximo 1 hora; se libera en onDestroy
        }
        Log.d(TAG, "WakeLock adquirido")
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
                Log.d(TAG, "WakeLock liberado")
            }
        } catch (_: Exception) {}
    }

    // ──────────────────────────────────────────────────────────────────────
    // Notificación persistente
    // ──────────────────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Servicio de Impresión",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Mantiene la conexión con la impresora térmica en segundo plano"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): android.app.Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // NotificationCompat funciona en todas las versiones de API de forma uniforme
        return androidx.core.app.NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Barril App — Impresora")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)  // ícono disponible en todas las API
            .setContentIntent(pi)
            .setOngoing(true)          // no se puede deslizar para cerrar
            .setPriority(androidx.core.app.NotificationCompat.PRIORITY_LOW)
            .setCategory(androidx.core.app.NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun updateNotification(text: String) {
        try {
            val nm = getSystemService(NotificationManager::class.java)
            nm.notify(NOTIFICATION_ID, buildNotification(text))
        } catch (_: Exception) {}
    }
}
