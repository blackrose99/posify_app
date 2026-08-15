package com.example.barril_app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val TAG = "POS_BT"
    private val CHANNEL = "com.example.barril_app/bluetooth_printer"
    private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    @Volatile
    private var activeSocket: BluetoothSocket? = null
    private var activeAddress: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBondedDevices" -> {
                    try {
                        val adapter = BluetoothAdapter.getDefaultAdapter()
                        if (adapter == null || !adapter.isEnabled) {
                            Log.w(TAG, "getBondedDevices: Bluetooth desactivado")
                            result.error("BLUETOOTH_DISABLED", "El Bluetooth está desactivado", null)
                            return@setMethodCallHandler
                        }
                        val pairedDevices: Set<BluetoothDevice>? = adapter.bondedDevices
                        val list = mutableListOf<Map<String, String>>()
                        pairedDevices?.forEach { device ->
                            list.add(
                                mapOf(
                                    "name" to (device.name ?: device.address),
                                    "address" to device.address
                                )
                            )
                        }
                        Log.d(TAG, "getBondedDevices encontró ${list.size} dispositivos vinculados")
                        result.success(list)
                    } catch (e: Exception) {
                        Log.e(TAG, "Error en getBondedDevices", e)
                        result.error("ERROR_BONDED", e.message, null)
                    }
                }
                "connectPrinter" -> {
                    val rawAddress = call.argument<String>("address")
                    if (rawAddress.isNullOrEmpty()) {
                        Log.w(TAG, "connectPrinter: Dirección nula")
                        result.error("INVALID_ARGS", "Dirección nula", null)
                        return@setMethodCallHandler
                    }

                    val address = resolveBondedAddress(rawAddress)
                    Log.d(TAG, "connectPrinter solicitado para $rawAddress, usando dirección $address")

                    Thread {
                        try {
                            if (activeSocket != null && activeSocket!!.isConnected && activeAddress == address) {
                                Log.d(TAG, "Ya está conectado a $address")
                                runOnUiThread { result.success(true) }
                                return@Thread
                            }

                            closeActiveSocket()

                            val adapter = BluetoothAdapter.getDefaultAdapter()
                            if (adapter == null || !adapter.isEnabled) {
                                Log.w(TAG, "Bluetooth desactivado")
                                runOnUiThread { result.error("BLUETOOTH_DISABLED", "Bluetooth desactivado", null) }
                                return@Thread
                            }

                            adapter.cancelDiscovery()
                            val device: BluetoothDevice = adapter.getRemoteDevice(address)

                            var socket: BluetoothSocket? = null
                            try {
                                Log.d(TAG, "Intentando createInsecureRfcommSocketToServiceRecord para $address...")
                                socket = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
                                socket.connect()
                                Log.i(TAG, "¡Conectado exitosamente vía Insecure SPP Record!")
                            } catch (e1: Exception) {
                                Log.w(TAG, "Fallo 1 (Insecure Record): ${e1.message}")
                                try {
                                    Log.d(TAG, "Intentando canal 1 inseguro por reflexión...")
                                    val method = device.javaClass.getMethod("createInsecureRfcommSocket", Int::class.javaPrimitiveType)
                                    socket = method.invoke(device, 1) as BluetoothSocket
                                    socket.connect()
                                    Log.i(TAG, "¡Conectado exitosamente vía Canal 1 Inseguro!")
                                } catch (e2: Exception) {
                                    Log.w(TAG, "Fallo 2 (Canal 1 Inseguro): ${e2.message}")
                                    try {
                                        Log.d(TAG, "Intentando socket seguro...")
                                        socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
                                        socket.connect()
                                        Log.i(TAG, "¡Conectado exitosamente vía Socket Seguro!")
                                    } catch (e3: Exception) {
                                        Log.e(TAG, "Fallo 3 (Socket Seguro): ${e3.message}")
                                        throw e1
                                    }
                                }
                            }

                            activeSocket = socket
                            activeAddress = address
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            Log.e(TAG, "Error final conectando a $address", e)
                            closeActiveSocket()
                            runOnUiThread { result.error("CONNECT_ERROR", e.message ?: "Error al conectar", null) }
                        }
                    }.start()
                }
                "isConnected" -> {
                    val rawAddress = call.argument<String>("address")
                    val address = if (!rawAddress.isNullOrEmpty()) resolveBondedAddress(rawAddress) else null
                    val isConn = activeSocket != null && activeSocket!!.isConnected && (address == null || activeAddress == address)
                    Log.d(TAG, "isConnected para $address: $isConn")
                    result.success(isConn)
                }
                "disconnectPrinter" -> {
                    Log.d(TAG, "disconnectPrinter invocado")
                    closeActiveSocket()
                    result.success(true)
                }
                "printViaClassicSpp" -> {
                    val rawAddress = call.argument<String>("address")
                    val bytes = call.argument<ByteArray>("bytes")

                    if (rawAddress.isNullOrEmpty() || bytes == null) {
                        Log.w(TAG, "printViaClassicSpp: Parámetros inválidos")
                        result.error("INVALID_ARGS", "Dirección o bytes nulos", null)
                        return@setMethodCallHandler
                    }

                    val address = resolveBondedAddress(rawAddress)
                    Log.d(TAG, "printViaClassicSpp enviando ${bytes.size} bytes a $address")
                    Thread {
                        try {
                            if (activeSocket == null || !activeSocket!!.isConnected || activeAddress != address) {
                                Log.d(TAG, "Re-conectando socket para impresión en $address")
                                val adapter = BluetoothAdapter.getDefaultAdapter()
                                if (adapter == null || !adapter.isEnabled) {
                                    runOnUiThread { result.error("BLUETOOTH_DISABLED", "Bluetooth desactivado", null) }
                                    return@Thread
                                }

                                adapter.cancelDiscovery()
                                val device: BluetoothDevice = adapter.getRemoteDevice(address)

                                var socket: BluetoothSocket? = null
                                try {
                                    socket = device.createInsecureRfcommSocketToServiceRecord(SPP_UUID)
                                    socket.connect()
                                } catch (e1: Exception) {
                                    try {
                                        val method = device.javaClass.getMethod("createInsecureRfcommSocket", Int::class.javaPrimitiveType)
                                        socket = method.invoke(device, 1) as BluetoothSocket
                                        socket.connect()
                                    } catch (e2: Exception) {
                                        socket = device.createRfcommSocketToServiceRecord(SPP_UUID)
                                        socket.connect()
                                    }
                                }
                                activeSocket = socket
                                activeAddress = address
                            }

                            val outputStream: OutputStream = activeSocket!!.outputStream

                            // ── PRE-FLUSH: Resetea el firmware antes de cada job ───────────────
                            // La DIG-M220 cachea la "longitud de formulario" internamente.
                            // Enviamos reset + modo continuo + detención de motor y esperamos
                            // 300ms para que el firmware procese el cambio de modo antes del job.
                            val preFlush = byteArrayOf(
                                0x1B, 0x40,              // ESC @ — Reset total del firmware
                                0x1F, 0x11, 0x0B,        // Modo papel: CONTINUO (no Label/Gap)
                                0x1F.toByte(), 0xF0.toByte(), 0x03, 0x00  // Motor stop (limpiar estado previo)
                            )
                            Log.d(TAG, "Enviando pre-flush de modo continuo (${preFlush.size} bytes)...")
                            outputStream.write(preFlush)
                            outputStream.flush()
                            Thread.sleep(300) // Espera crítica: el firmware necesita ~250-300ms para cambiar de modo

                            // ── JOB PRINCIPAL ─────────────────────────────────────────────────
                            outputStream.write(bytes)
                            outputStream.flush()
                            Log.i(TAG, "¡Bytes impresos y enviados a $address exitosamente (${bytes.size} bytes)!")

                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            Log.e(TAG, "Error imprimiendo bytes en $address", e)
                            closeActiveSocket()
                            runOnUiThread { result.error("PRINT_ERROR", e.message ?: "Error enviando impresión", null) }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun resolveBondedAddress(requestedAddress: String): String {
        try {
            val adapter = BluetoothAdapter.getDefaultAdapter() ?: return requestedAddress
            val bonded = adapter.bondedDevices ?: return requestedAddress

            // 1. Si la dirección solicitada coincide exactamente con una vinculada por MAC
            for (dev in bonded) {
                if (dev.address.equals(requestedAddress, ignoreCase = true)) {
                    return dev.address
                }
            }

            // 2. Si no coincide por MAC, buscar coincidencia por nombre o limpia de _BLE
            val cleanReq = requestedAddress.replace("_BLE", "", ignoreCase = true).trim()
            for (dev in bonded) {
                val devName = dev.name ?: ""
                if (devName.isNotEmpty()) {
                    if (devName.equals(cleanReq, ignoreCase = true) ||
                        cleanReq.contains(devName, ignoreCase = true) ||
                        devName.contains("M220", ignoreCase = true) ||
                        devName.contains("Phomemo", ignoreCase = true) ||
                        devName.contains("DIG-M220", ignoreCase = true)) {
                        Log.i(TAG, "Mapeada la dirección '$requestedAddress' a la impresora vinculada '${dev.name}' (${dev.address})")
                        return dev.address
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error resolviendo dirección vinculada: ${e.message}")
        }
        return requestedAddress
    }

    private fun closeActiveSocket() {
        try {
            if (activeSocket != null) {
                Log.d(TAG, "Cerrando activeSocket para $activeAddress")
                activeSocket?.close()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error cerrando socket", e)
        }
        activeSocket = null
        activeAddress = null
    }

    override fun onDestroy() {
        closeActiveSocket()
        super.onDestroy()
    }
}
