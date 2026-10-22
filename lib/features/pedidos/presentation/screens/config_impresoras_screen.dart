import 'dart:convert';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../database/app_database.dart';
import '../../../../injection_container.dart';
import '../../../impresion/bluetooth_printer_service.dart';
import '../../../impresion/ticket_builder.dart';
import '../../../impresion/ticket_data.dart';
import '../../domain/entities/item_pedido.dart';

class ConfigImpresorasScreen extends StatefulWidget {
  const ConfigImpresorasScreen({super.key});

  @override
  State<ConfigImpresorasScreen> createState() => _ConfigImpresorasScreenState();
}

class _ConfigImpresorasScreenState extends State<ConfigImpresorasScreen> {
  final AppDatabase _db = sl<AppDatabase>();
  final BluetoothPrinterService _printerService = const BluetoothPrinterService();

  bool _loading = true;
  bool _escaneando = false;
  bool _calibrando = false;
  bool _imprimiendoPrueba = false;
  String _printerDeviceId = '';
  String _printerDeviceName = '';
  AnchoPapel _anchoPapel = AnchoPapel.mm58;
  List<DiscoveredPrinter> _encontrados = const [];

  @override
  void initState() {
    super.initState();
    _cargarYBuscar();
  }

  Future<void> _upsertConfig(String clave, String valor) async {
    final actual = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals(clave)))
        .getSingleOrNull();
    if (actual == null) {
      await _db
          .into(_db.configuracion)
          .insert(ConfiguracionCompanion.insert(clave: clave, valor: valor));
      return;
    }
    await (_db.update(_db.configuracion)..where((c) => c.clave.equals(clave)))
        .write(ConfiguracionCompanion(valor: drift.Value(valor)));
  }

  Future<String> _leerConfig(String clave, {String fallback = ''}) async {
    final row = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals(clave)))
        .getSingleOrNull();
    return row?.valor ?? fallback;
  }

  Future<void> _cargar() async {
    final deviceId = await _leerConfig('printer_device_id');
    final deviceName = await _leerConfig('printer_device_name');
    final anchoRaw = await _leerConfig('printer_paper_width', fallback: '32');
    final ancho = AnchoPapelX.desdeCaracteres(int.tryParse(anchoRaw) ?? 32);

    if (!mounted) return;
    setState(() {
      _printerDeviceId = deviceId;
      _printerDeviceName = deviceName;
      _anchoPapel = ancho;
      _loading = false;
    });

    // Conectar en segundo plano sin bloquear la interfaz con spinner
    if (deviceId.isNotEmpty) {
      _printerService.connect(deviceId);
    }
  }

  Future<void> _cargarYBuscar() async {
    await _cargar();
    await _buscarImpresoras();

    if (_printerDeviceId.isEmpty && _encontrados.isNotEmpty) {
      final vinculada = _encontrados.firstWhere(
        (p) => p.isBonded || p.name.toUpperCase().contains('PRINT') || p.name.toUpperCase().contains('POS'),
        orElse: () => _encontrados.first,
      );
      await _seleccionarImpresora(vinculada);
    }
  }

  Future<void> _conectarImpresora() async {
    if (_printerDeviceId.isEmpty) return;
    setState(() => _loading = true);
    try {
      final dev = await _printerService.connect(_printerDeviceId);
      final isConn = await _printerService.isConnected(_printerDeviceId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isConn || dev != null
                ? '¡Impresora $_printerDeviceName conectada (Luz azul fija)!'
                : 'No se pudo conectar a $_printerDeviceName. Asegúrate de encenderla.',
          ),
          backgroundColor: (isConn || dev != null) ? AppColors.success : AppColors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _buscarImpresoras() async {
    setState(() {
      _escaneando = true;
      _encontrados = const [];
    });

    try {
      final okPermisos = await _printerService.requestPermissions();
      if (!okPermisos && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Se requieren permisos de Bluetooth y Ubicación para detectar impresoras.',
            ),
          ),
        );
        return;
      }

      final resultados = await _printerService.scanPrinters();
      if (!mounted) return;
      setState(() => _encontrados = resultados);

      if (_encontrados.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No se encontraron impresoras. Asegúrate de encender la impresora y vincularla por Bluetooth.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _escaneando = false);
    }
  }

  Future<void> _seleccionarImpresora(DiscoveredPrinter item) async {
    final id = item.id;
    final nombre = item.name;

    await _upsertConfig('printer_device_id', id);
    await _upsertConfig('printer_device_name', nombre.isEmpty ? id : nombre);

    await _printerService.connect(id);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Impresora "$nombre" conectada y guardada como predeterminada.')),
    );
    await _cargar();
  }

  Future<void> _olvidarImpresora() async {
    await _upsertConfig('printer_device_id', '');
    await _upsertConfig('printer_device_name', '');
    await _cargar();
  }

  Future<void> _cambiarAnchoPapel(AnchoPapel ancho) async {
    await _upsertConfig('printer_paper_width', ancho.caracteresPorLinea.toString());
    setState(() => _anchoPapel = ancho);
  }

  Future<void> _calibrarYSincronizarImpresora() async {
    setState(() => _calibrando = true);
    try {
      final okPermisos = await _printerService.requestPermissions();
      if (!okPermisos && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Se requieren permisos de Bluetooth y Ubicación para calibrar.'),
            backgroundColor: AppColors.error,
          ),
        );
        return;
      }

      String targetId = _printerDeviceId.trim();
      String targetName = _printerDeviceName.trim();

      // Si no hay impresora seleccionada, buscar automáticamente dispositivos cercanos
      if (targetId.isEmpty) {
        final lista = await _printerService.scanPrinters();
        if (mounted) setState(() => _encontrados = lista);

        if (lista.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'No se detectó ninguna impresora Bluetooth. Enciéndela y verifica que tenga batería.',
              ),
              backgroundColor: AppColors.error,
            ),
          );
          return;
        }

        // Elegir la candidata más probable (vinculada o con nombre POS / Print)
        final candidata = lista.firstWhere(
          (p) =>
              p.isBonded ||
              p.name.toUpperCase().contains('PRINT') ||
              p.name.toUpperCase().contains('POS') ||
              p.name.toUpperCase().contains('M220') ||
              p.name.toUpperCase().contains('BT'),
          orElse: () => lista.first,
        );

        targetId = candidata.id;
        targetName = candidata.name.isNotEmpty ? candidata.name : candidata.id;
      }

      // Conectar y descubrir canales de comunicación (SPP / GATT UART)
      final device = await _printerService.connect(targetId);
      if (device == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No se pudo comunicar con "$targetName". Verifica que la luz azul esté encendida.',
            ),
            backgroundColor: AppColors.error,
          ),
        );
        return;
      }

      // Guardar en la base de datos como impresora predeterminada
      await _upsertConfig('printer_device_id', targetId);
      await _upsertConfig('printer_device_name', targetName);
      if (mounted) {
        setState(() {
          _printerDeviceId = targetId;
          _printerDeviceName = targetName;
        });
      }

      // Generar ticket de calibración con holgura verificada (1 cm inicio, >1.5 cm corte)
      final bytes = buildCalibrationTicketBytes(
        ancho: _anchoPapel,
        deviceName: targetName,
      );
      final exito = await _printerService.printBytes(device, bytes);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            exito
                ? '¡Impresora "$targetName" calibrada y sincronizada exitosamente!'
                : 'Conectada a "$targetName", pero no imprimió. Verifica el rollo de papel.',
          ),
          backgroundColor: exito ? AppColors.success : AppColors.error,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al calibrar: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _calibrando = false);
    }
  }

  Future<void> _imprimirTicketPrueba() async {
    if (_printerDeviceId.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Primero pulsa "Calibrar y Sincronizar" o selecciona una impresora.')),
      );
      return;
    }

    setState(() => _imprimiendoPrueba = true);
    try {
      final nombreNegocio = await _leerConfig('nombre_negocio', fallback: 'POSify');
      final ticketPrueba = TicketData(
        nombreNegocio: nombreNegocio,
        pedidoId: 101,
        numeroTurno: 1,
        tipo: 'mesa',
        referencia: 'Mesa 1',
        cliente: 'Cliente Prueba',
        mesero: 'POSify',
        items: const [
          ItemPedido(
            id: 1,
            pedidoId: 101,
            productoId: 1,
            nombreProducto: 'Carne al Barril 250g',
            precio: 25000,
            cantidad: 1,
            adicionales: ['Papas a la francesa'],
            nota: 'Término medio',
          ),
          ItemPedido(
            id: 2,
            pedidoId: 101,
            productoId: 2,
            nombreProducto: 'Gaseosa Postobón',
            precio: 5000,
            cantidad: 1,
            adicionales: [],
            nota: '',
          ),
        ],
        valorDomicilio: 0,
        cobrarDomicilio: false,
        estadoPedido: 'cerrado',
        fecha: DateTime.now(),
      );

      final bytes = await buildEscPosBytes(ticketPrueba, ancho: _anchoPapel);
      final device = await _printerService.connect(_printerDeviceId);
      final exito = device != null && await _printerService.printBytes(device, bytes);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            exito
                ? '¡Éxito! Factura de prueba impresa en $_printerDeviceName.'
                : 'No se pudo imprimir en $_printerDeviceName. Verifica conexión y papel.',
          ),
          backgroundColor: exito ? AppColors.success : AppColors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _imprimiendoPrueba = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Impresoras POS', style: TextStyle(color: Colors.white)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Impresora térmica predeterminada',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      if (_printerDeviceId.trim().isEmpty)
                        const Text(
                          'No hay ninguna impresora seleccionada todavía.',
                          style: TextStyle(color: AppColors.textMuted),
                        )
                      else
                        Row(
                          children: [
                            const Icon(Icons.print, color: AppColors.accent),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _printerDeviceName.isEmpty ? _printerDeviceId : _printerDeviceName,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _conectarImpresora,
                              icon: const Icon(Icons.bluetooth_connected, size: 16),
                              label: const Text('Conectar'),
                            ),
                            TextButton(
                              onPressed: _olvidarImpresora,
                              child: const Text('Olvidar'),
                            ),
                          ],
                        ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: (_calibrando || _imprimiendoPrueba) ? null : _calibrarYSincronizarImpresora,
                            icon: _calibrando
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.sync_alt),
                            label: Text(_calibrando ? 'Calibrando...' : 'Calibrar y Sincronizar Impresora'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.white,
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: (_calibrando || _imprimiendoPrueba) ? null : _imprimirTicketPrueba,
                            icon: _imprimiendoPrueba
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.receipt_long),
                            label: const Text('Imprimir Factura de Prueba'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Ancho de papel', style: TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      SegmentedButton<AnchoPapel>(
                        segments: AnchoPapel.values
                            .map((a) => ButtonSegment(value: a, label: Text(a.etiqueta)))
                            .toList(),
                        selected: {_anchoPapel},
                        onSelectionChanged: (s) => _cambiarAnchoPapel(s.first),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Dispositivos Bluetooth encontrados',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _escaneando ? null : _buscarImpresoras,
                      icon: _escaneando
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.bluetooth_searching),
                      label: Text(_escaneando ? 'Buscando...' : 'Buscar'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_encontrados.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      _escaneando
                          ? 'Buscando impresoras cercanas y vinculadas...'
                          : 'Toca "Buscar" para detectar impresoras Bluetooth disponibles.',
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  )
                else
                  ..._encontrados.map((item) {
                    final nombre = item.name.isNotEmpty ? item.name : item.id;
                    final esActual = item.id == _printerDeviceId;
                    final esVinculado = item.isBonded;

                    return Card(
                      color: esActual ? AppColors.accent.withValues(alpha: 0.12) : Colors.white,
                      child: ListTile(
                        leading: Icon(
                          Icons.print_outlined,
                          color: esVinculado ? AppColors.accent : null,
                        ),
                        title: Text(
                          nombre,
                          style: TextStyle(
                            fontWeight: esActual ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          esVinculado
                              ? 'Vinculada en el sistema (Paired)'
                              : (item.rssi != 0 ? 'Señal: ${item.rssi} dBm' : item.id),
                        ),
                        trailing: esActual
                            ? const Icon(Icons.check_circle, color: AppColors.accent)
                            : const Icon(Icons.chevron_right),
                        onTap: () => _seleccionarImpresora(item),
                      ),
                    );
                  }),
              ],
            ),
    );
  }
}

