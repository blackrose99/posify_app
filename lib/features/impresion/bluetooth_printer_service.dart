import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Canal de comunicación nativo con Android para soporte de Bluetooth Classic (SPP).
const MethodChannel _channel = MethodChannel('com.example.barril_app/bluetooth_printer');

/// Modelo de impresora descubierta o vinculada en el sistema.
class DiscoveredPrinter {
  final BluetoothDevice device;
  final String name;
  final String id;
  final int rssi;
  final bool isBonded;

  const DiscoveredPrinter({
    required this.device,
    required this.name,
    required this.id,
    required this.rssi,
    this.isBonded = false,
  });
}

/// Servicio reutilizable para descubrir, conectar e imprimir en impresoras
/// térmicas Bluetooth (soporta tanto Bluetooth Classic SPP como BLE GATT).
class BluetoothPrinterService {
  const BluetoothPrinterService();

  /// Solicita los permisos necesarios en Android/iOS para Bluetooth y Ubicación.
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final statusScan = await Permission.bluetoothScan.request();
      final statusConnect = await Permission.bluetoothConnect.request();
      await Permission.locationWhenInUse.request();

      if (statusScan.isDenied || statusConnect.isDenied) {
        debugPrint('Permisos de Bluetooth denegados por el usuario.');
        return false;
      }
    }
    return true;
  }

  /// Verifica si el adaptador Bluetooth está encendido y si no, intenta encenderlo (en Android).
  Future<bool> checkAndEnableBluetooth() async {
    try {
      final state = await FlutterBluePlus.adapterState.first;
      if (state != BluetoothAdapterState.on) {
        if (Platform.isAndroid) {
          try {
            await FlutterBluePlus.turnOn();
          } catch (e) {
            debugPrint('No se pudo activar Bluetooth automáticamente: $e');
          }
        }
        final newState = await FlutterBluePlus.adapterState.first;
        return newState == BluetoothAdapterState.on;
      }
      return true;
    } catch (e) {
      debugPrint('Error verificando estado de Bluetooth: $e');
      return false;
    }
  }

  /// Escanea dispositivos BLE cercanos y obtiene dispositivos ya vinculados (bonded) en el sistema.
  Future<List<DiscoveredPrinter>> scanPrinters({
    Duration timeout = const Duration(seconds: 6),
  }) async {
    await requestPermissions();
    await checkAndEnableBluetooth();

    final mapaDispositivos = <String, DiscoveredPrinter>{};

    // 1. Obtener dispositivos vinculados por Bluetooth Classic (SPP) desde Android
    if (Platform.isAndroid) {
      try {
        final List<dynamic>? bondedNative =
            await _channel.invokeMethod<List<dynamic>>('getBondedDevices');
        if (bondedNative != null) {
          for (final item in bondedNative) {
            if (item is Map) {
              final String name = (item['name'] as String?) ?? '';
              final String address = (item['address'] as String?) ?? '';
              if (address.isNotEmpty) {
                final dev = BluetoothDevice.fromId(address);
                mapaDispositivos[address] = DiscoveredPrinter(
                  device: dev,
                  name: name.isNotEmpty ? name : address,
                  id: address,
                  rssi: 0,
                  isBonded: true,
                );
              }
            }
          }
        }
      } catch (e) {
        debugPrint('Error obteniendo dispositivos vinculados nativos: $e');
      }
    }

    // 2. Obtener dispositivos vinculados via FlutterBluePlus
    try {
      final bondedList = await FlutterBluePlus.bondedDevices;
      for (final dev in bondedList) {
        final nombre = dev.platformName.isNotEmpty ? dev.platformName : dev.remoteId.str;
        if (!mapaDispositivos.containsKey(dev.remoteId.str)) {
          mapaDispositivos[dev.remoteId.str] = DiscoveredPrinter(
            device: dev,
            name: nombre,
            id: dev.remoteId.str,
            rssi: 0,
            isBonded: true,
          );
        }
      }
    } catch (e) {
      debugPrint('Error obteniendo dispositivos vinculados BLE: $e');
    }

    // 3. Detener escaneo previo e iniciar escaneo BLE para descubrir nuevos dispositivos
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }

    final sub = FlutterBluePlus.scanResults.listen((resultados) {
      for (final r in resultados) {
        final platformName = r.device.platformName;
        final advName = r.advertisementData.advName;
        String nombre = platformName.isNotEmpty ? platformName : advName;
        if (nombre.isEmpty) {
          nombre = r.device.remoteId.str;
        }

        final id = r.device.remoteId.str;
        final yaExiste = mapaDispositivos[id];

        // Omitir duplicados _BLE si ya tenemos el dispositivo vinculado nativo
        final baseName = nombre.replaceAll('_BLE', '').trim();
        final existeBonded = mapaDispositivos.values.any((p) => p.isBonded && (p.name == baseName || p.name.contains(baseName)));

        if (!existeBonded || (yaExiste != null && yaExiste.isBonded)) {
          mapaDispositivos[id] = DiscoveredPrinter(
            device: r.device,
            name: (yaExiste != null && yaExiste.name != yaExiste.id) ? yaExiste.name : nombre,
            id: id,
            rssi: r.rssi,
            isBonded: yaExiste?.isBonded ?? false,
          );
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      await FlutterBluePlus.isScanning.where((scanning) => !scanning).first;
    } catch (e) {
      debugPrint('Error durante el escaneo BLE: $e');
    } finally {
      await sub.cancel();
    }

    final lista = mapaDispositivos.values.toList();
    lista.sort((a, b) {
      if (a.isBonded && !b.isBonded) return -1;
      if (!a.isBonded && b.isBonded) return 1;
      return b.rssi.compareTo(a.rssi);
    });

    return lista;
  }

  /// Reconstruye un [BluetoothDevice] a partir de un remoteId guardado y abre la conexión serie persistente.
  Future<BluetoothDevice?> connect(String remoteId) async {
    if (remoteId.trim().isEmpty) return null;
    try {
      if (Platform.isAndroid) {
        final bool? ok = await _channel.invokeMethod<bool>('connectPrinter', {'address': remoteId});
        debugPrint('Resultado connectPrinter para $remoteId: $ok');
      }
      final device = BluetoothDevice.fromId(remoteId);
      try {
        if (!device.isConnected) {
          await device.connect(timeout: const Duration(seconds: 4), autoConnect: false);
          await device.requestMtu(512);
        }
      } catch (_) {}
      return device;
    } catch (e) {
      debugPrint('Error obteniendo dispositivo $remoteId: $e');
      return null;
    }
  }

  /// Consulta si la impresora seleccionada tiene un socket activo (luz azul fija).
  Future<bool> isConnected(String remoteId) async {
    if (remoteId.trim().isEmpty) return false;
    if (Platform.isAndroid) {
      try {
        final bool? res = await _channel.invokeMethod<bool>('isConnected', {'address': remoteId});
        return res ?? false;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// Cierra el socket nativo de impresión.
  Future<void> disconnect() async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('disconnectPrinter');
      } catch (_) {}
    }
  }

  /// Envía los [bytes] de impresión a la impresora. Intenta primero vía
  /// Bluetooth Classic (SPP socket RFCOMM) y si no aplica o falla, usa BLE GATT.
  Future<bool> printBytes(BluetoothDevice device, List<int> bytes) async {
    final address = device.remoteId.str;

    // 1. Intentar impresión por Bluetooth Classic (SPP) si estamos en Android
    if (Platform.isAndroid && address.isNotEmpty) {
      try {
        debugPrint('Intentando imprimir vía Bluetooth Classic (SPP) en $address...');
        final bool? exitoSpp = await _channel.invokeMethod<bool>('printViaClassicSpp', {
          'address': address,
          'bytes': Uint8List.fromList(bytes),
        });
        if (exitoSpp == true) {
          debugPrint('¡Impresión por Bluetooth Classic (SPP) exitosa!');
          return true;
        }
      } catch (e) {
        debugPrint('Falló impresión SPP Classic, intentando BLE GATT: $e');
      }
    }

    // 2. Fallback a BLE GATT
    return _printBytesBle(device, bytes);
  }

  Future<bool> _printBytesBle(BluetoothDevice device, List<int> bytes) async {
    try {
      if (!device.isConnected) {
        await device.connect(timeout: const Duration(seconds: 10), autoConnect: false);
        try {
          await device.requestMtu(512);
        } catch (_) {}
      }

      final servicios = await device.discoverServices();
      BluetoothCharacteristic? writable;
      for (final s in servicios) {
        for (final c in s.characteristics) {
          if (c.properties.write || c.properties.writeWithoutResponse) {
            writable = c;
            break;
          }
        }
        if (writable != null) break;
      }

      if (writable == null) {
        debugPrint('No se encontró característica de escritura BLE en ${device.platformName}');
        return false;
      }

      int maxChunk = 20;
      try {
        final mtu = device.mtuNow;
        if (mtu > 3) {
          maxChunk = (mtu - 3).clamp(20, 180);
        }
      } catch (_) {
        maxChunk = 20;
      }

      final bool withoutResponse = writable.properties.writeWithoutResponse;

      for (int i = 0; i < bytes.length; i += maxChunk) {
        final fin = (i + maxChunk < bytes.length) ? i + maxChunk : bytes.length;
        final chunk = bytes.sublist(i, fin);
        await writable.write(chunk, withoutResponse: withoutResponse);
        await Future.delayed(const Duration(milliseconds: 20));
      }

      return true;
    } catch (e, stack) {
      debugPrint('Error al imprimir por BLE: $e\n$stack');
      return false;
    }
  }
}


