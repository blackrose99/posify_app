package com.example.barril_app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val TAG = "POS_BT"
    private val CHANNEL = "com.example.barril_app/bluetooth_printer"

    // ── Referencia al Foreground Service ──────────────────────────────────
    private var printerService: PrinterForegroundService? = null
    private var serviceBound = false
    private val mainHandler = Handler(Looper.getMainLooper())

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val b = binder as? PrinterForegroundService.PrinterBinder
            printerService = b?.getService()
            serviceBound = true
            Log.i(TAG, "PrinterForegroundService vinculado a MainActivity")
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            printerService = null
            serviceBound = false
            Log.w(TAG, "PrinterForegroundService desvinculado inesperadamente — re-enlazando")
            bindPrinterService()  // intenta reconectar al servicio
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Ciclo de vida
    // ──────────────────────────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Arrancar y enlazar el servicio en primer plano
        startPrinterService()
        bindPrinterService()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBondedDevices" -> handleGetBondedDevices(result)
                    "connectPrinter"   -> handleConnect(call.argument("address"), result)
                    "isConnected"      -> handleIsConnected(call.argument("address"), result)
                    "disconnectPrinter"-> handleDisconnect(result)
                    "printViaClassicSpp" -> handlePrint(
                        call.argument("address"),
                        call.argument("bytes"),
                        result
                    )
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        // Desvinculamos el Binder pero NO detenemos el servicio:
        // el servicio sigue vivo en segundo plano para futuras impresiones.
        if (serviceBound) {
            unbindService(serviceConnection)
            serviceBound = false
        }
        super.onDestroy()
    }

    // ──────────────────────────────────────────────────────────────────────
    // Inicio y vinculación del Foreground Service
    // ──────────────────────────────────────────────────────────────────────

    private fun startPrinterService() {
        val intent = Intent(this, PrinterForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        Log.d(TAG, "PrinterForegroundService iniciado")
    }

    private fun bindPrinterService() {
        val intent = Intent(this, PrinterForegroundService::class.java)
        bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)
    }

    // ──────────────────────────────────────────────────────────────────────
    // Manejadores de MethodChannel
    // ──────────────────────────────────────────────────────────────────────

    private fun handleGetBondedDevices(result: MethodChannel.Result) {
        try {
            val adapter = BluetoothAdapter.getDefaultAdapter()
            if (adapter == null || !adapter.isEnabled) {
                Log.w(TAG, "getBondedDevices: Bluetooth desactivado")
                result.error("BLUETOOTH_DISABLED", "El Bluetooth está desactivado", null)
                return
            }
            val list = adapter.bondedDevices?.map { device ->
                mapOf("name" to (device.name ?: device.address), "address" to device.address)
            } ?: emptyList()
            Log.d(TAG, "getBondedDevices: ${list.size} dispositivos vinculados")
            result.success(list)
        } catch (e: Exception) {
            Log.e(TAG, "Error en getBondedDevices", e)
            result.error("ERROR_BONDED", e.message, null)
        }
    }

    private fun handleConnect(rawAddress: String?, result: MethodChannel.Result) {
        if (rawAddress.isNullOrEmpty()) {
            result.error("INVALID_ARGS", "Dirección nula", null)
            return
        }
        val address = resolveBondedAddress(rawAddress)
        Log.d(TAG, "connectPrinter → $address")

        val svc = printerService
        if (svc == null) {
            // Servicio todavía no vinculado: conectar en hilo propio y re-intentar bind
            Log.w(TAG, "Servicio no vinculado aún — intentando bind y conectando directamente")
            bindPrinterService()
            result.error("SERVICE_NOT_READY", "Servicio iniciándose, reintenta en un segundo", null)
            return
        }

        Thread {
            try {
                val ok = svc.connect(address)
                mainHandler.post {
                    if (ok) result.success(true)
                    else result.error("CONNECT_ERROR", "No se pudo conectar a $address", null)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error conectando a $address", e)
                mainHandler.post {
                    result.error("CONNECT_ERROR", e.message ?: "Error desconocido", null)
                }
            }
        }.start()
    }

    private fun handleIsConnected(rawAddress: String?, result: MethodChannel.Result) {
        val address = if (!rawAddress.isNullOrEmpty()) resolveBondedAddress(rawAddress) else null
        val connected = printerService?.isConnected(address) == true
        Log.d(TAG, "isConnected($address): $connected")
        result.success(connected)
    }

    private fun handleDisconnect(result: MethodChannel.Result) {
        printerService?.disconnect()
        Log.d(TAG, "disconnectPrinter invocado")
        result.success(true)
    }

    private fun handlePrint(rawAddress: String?, bytes: ByteArray?, result: MethodChannel.Result) {
        if (rawAddress.isNullOrEmpty() || bytes == null) {
            result.error("INVALID_ARGS", "Dirección o bytes nulos", null)
            return
        }
        val address = resolveBondedAddress(rawAddress)
        Log.d(TAG, "printViaClassicSpp → $address (${bytes.size} bytes)")

        val svc = printerService
        if (svc == null) {
            Log.w(TAG, "Servicio no vinculado — iniciando e intentando bind")
            startPrinterService()
            bindPrinterService()
            result.error("SERVICE_NOT_READY", "Servicio iniciándose, reintenta", null)
            return
        }

        // Encola el job — el worker del servicio lo procesará en background
        svc.enqueuePrint(address, bytes) { success, error ->
            mainHandler.post {
                if (success) {
                    Log.i(TAG, "Job impreso correctamente en $address")
                    result.success(true)
                } else {
                    Log.e(TAG, "Error en job de impresión: $error")
                    result.error("PRINT_ERROR", error ?: "Error de impresión", null)
                }
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Resolución de alias Bluetooth → MAC real
    // ──────────────────────────────────────────────────────────────────────

    private fun resolveBondedAddress(requestedAddress: String): String {
        try {
            val adapter = BluetoothAdapter.getDefaultAdapter() ?: return requestedAddress
            val bonded: Set<BluetoothDevice> = adapter.bondedDevices ?: return requestedAddress

            // 1. Coincidencia exacta por MAC
            for (dev in bonded) {
                if (dev.address.equals(requestedAddress, ignoreCase = true)) return dev.address
            }

            // 2. Coincidencia por nombre / alias _BLE
            val cleanReq = requestedAddress.replace("_BLE", "", ignoreCase = true).trim()
            for (dev in bonded) {
                val devName = dev.name ?: ""
                if (devName.isNotEmpty() &&
                    (devName.equals(cleanReq, ignoreCase = true) ||
                     cleanReq.contains(devName, ignoreCase = true) ||
                     devName.contains("M220", ignoreCase = true) ||
                     devName.contains("Phomemo", ignoreCase = true) ||
                     devName.contains("DIG-M220", ignoreCase = true))
                ) {
                    Log.i(TAG, "Mapeada '$requestedAddress' → '${dev.name}' (${dev.address})")
                    return dev.address
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error resolviendo dirección vinculada: ${e.message}")
        }
        return requestedAddress
    }
}
