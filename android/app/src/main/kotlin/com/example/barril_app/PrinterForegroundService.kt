package com.example.barril_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue

class PrinterForegroundService : Service() {

    companion object {
        private const val TAG = "PrinterService"
        private const val CHANNEL_ID = "printer_channel_v1"
        private const val NOTIFICATION_ID = 2001
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }

    inner class PrinterBinder : Binder() {
        fun getService(): PrinterForegroundService = this@PrinterForegroundService
    }
    private val binder = PrinterBinder()

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

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        try {
            val notification = buildNotification("Impresora lista para imprimir")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            Log.i(TAG, "PrinterForegroundService creado y en primer plano")
        } catch (e: Exception) {
            Log.e(TAG, "No se pudo iniciar startForeground con connectedDevice: ${e.message}", e)
        }
        startWorker()
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
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

    fun enqueuePrint(address: String, bytes: ByteArray, callback: (Boolean, String?) -> Unit) {
        printQueue.offer(PrintJob(address, bytes, callback))
        updateNotification("Imprimiendo ticket...")
        Log.d(TAG, "Job encolado para $address (${bytes.size} bytes), cola: ${printQueue.size}")
    }

    private fun startWorker() {
        workerRunning = true
        workerThread = Thread {
            Log.i(TAG, "Worker de impresión iniciado")
            while (workerRunning && !Thread.currentThread().isInterrupted) {
                try {
                    val job = printQueue.take()
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
            it.isDaemon = false
            it.name = "PrinterWorker"
            it.start()
        }
    }

    private fun processJob(job: PrintJob) {
        Log.d(TAG, "Procesando job para ${job.address} (${job.bytes.size} bytes)")
        acquireWakeLock(15000L)
        try {
            if (activeSocket?.isConnected != true || activeAddress != job.address) {
                Log.d(TAG, "Socket caído, reconectando a ${job.address}...")
                openSocket(job.address)
                updateNotification("Reconectando impresora...")
            }

            try {
                val out: OutputStream = activeSocket!!.outputStream
                out.write(job.bytes)
                out.flush()
            } catch (writeError: Exception) {
                Log.w(TAG, "Socket obsoleto al escribir (${writeError.message}), reabriendo SPP...")
                closeSocket()
                openSocket(job.address)
                val outRetry: OutputStream = activeSocket!!.outputStream
                outRetry.write(job.bytes)
                outRetry.flush()
            }

            Log.i(TAG, "✓ Job impreso exitosamente para ${job.address}")
            updateNotification("Ticket impreso correctamente ✓")
            job.callback(true, null)

        } catch (e: Exception) {
            Log.e(TAG, "✗ Error imprimiendo job para ${job.address}", e)
            closeSocket()
            updateNotification("Error al imprimir — reintentando conexión")
            job.callback(false, e.message ?: "Error de impresión")
        } finally {
            releaseWakeLock()
        }
    }

    private fun openSocket(address: String) {
        val adapter = BluetoothAdapter.getDefaultAdapter()
            ?: throw IllegalStateException("Bluetooth no disponible")
        adapter.cancelDiscovery()
        val device: BluetoothDevice = adapter.getRemoteDevice(address)

        // Si el dispositivo NO está vinculado en Android Classic (por ejemplo Printer_BBBB_BLE
        // cuyo módulo Classic es Printer_BC01 con PIN), NO tocar RFCOMM Classic para no disparar
        // el diálogo "¿Vincular con Printer_BC01?" ni el error de PIN.
        if (device.bondState != BluetoothDevice.BOND_BONDED) {
            throw IllegalStateException("Dispositivo $address no está vinculado por Bluetooth Classic; usar BLE GATT")
        }

        var socket: BluetoothSocket? = null
        try {
            Log.d(TAG, "Intentando socket inseguro (SPP UUID) para $address")
            socket = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
            socket.connect()
            Log.i(TAG, "Conectado vía Insecure SPP UUID")
        } catch (e1: Exception) {
            Log.w(TAG, "Fallo Insecure SPP: ${e1.message}")
            try { socket?.close() } catch (_: Exception) {}
            try {
                Log.d(TAG, "Intentando canal 1 inseguro por reflexión...")
                val method = device.javaClass.getMethod("createInsecureRfcommSocket", Int::class.javaPrimitiveType)
                socket = method.invoke(device, 1) as BluetoothSocket
                socket.connect()
                Log.i(TAG, "Conectado vía Canal 1 Inseguro")
            } catch (e2: Exception) {
                Log.w(TAG, "Fallo Canal Inseguro: ${e2.message}")
                try { socket?.close() } catch (_: Exception) {}
                try {
                    Log.d(TAG, "Intentando socket seguro (dispositivo ya vinculado)...")
                    socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
                    socket.connect()
                    Log.i(TAG, "Conectado vía Socket Seguro")
                } catch (e3: Exception) {
                    Log.w(TAG, "Fallo Socket Seguro: ${e3.message}")
                    try { socket?.close() } catch (_: Exception) {}
                    throw e3
                }
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

    private fun acquireWakeLock(timeoutMs: Long = 15000L) {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "barril_app::PrinterWakeLock"
                )
            }
            if (wakeLock?.isHeld == false) {
                wakeLock?.acquire(timeoutMs)
                Log.d(TAG, "WakeLock adquirido temporalmente ($timeoutMs ms)")
            }
        } catch (_: Exception) {}
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
                Log.d(TAG, "WakeLock liberado")
            }
        } catch (_: Exception) {}
    }

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

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Barril App — Impresora")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(pi)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun updateNotification(text: String) {
        try {
            val nm = getSystemService(NotificationManager::class.java)
            nm.notify(NOTIFICATION_ID, buildNotification(text))
        } catch (_: Exception) {}
    }
}
