import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/utils/money_formatter.dart';
import '../../../../database/app_database.dart';
import '../../../../injection_container.dart';
import '../../../impresion/bluetooth_printer_service.dart';
import '../../../impresion/ticket_builder.dart';
import '../../../impresion/ticket_data.dart';
import '../../../impresion/ticket_pdf.dart';
import 'config_impresoras_screen.dart';

/// Previsualiza un pedido como ticket y permite imprimirlo en una POS
/// térmica, exportarlo/imprimirlo como PDF o compartirlo por WhatsApp.
class TicketPreviewScreen extends StatefulWidget {
  final TicketData data;
  final bool modoCocinaInicial;

  const TicketPreviewScreen({
    super.key,
    required this.data,
    this.modoCocinaInicial = false,
  });

  @override
  State<TicketPreviewScreen> createState() => _TicketPreviewScreenState();
}

class _TicketPreviewScreenState extends State<TicketPreviewScreen> {
  final AppDatabase _db = sl<AppDatabase>();
  final BluetoothPrinterService _printerService =
      const BluetoothPrinterService();

  late bool _esModoCocina;
  late bool _impresoCliente;
  late bool _impresoCocina;
  bool _cargandoConfig = true;
  bool _accionEnCurso = false;
  String _printerDeviceId = '';
  String _printerDeviceName = '';
  AnchoPapel _anchoPapel = AnchoPapel.mm58;

  bool get _yaImpresoActual =>
      _esModoCocina ? _impresoCocina : _impresoCliente;

  @override
  void initState() {
    super.initState();
    _esModoCocina = widget.modoCocinaInicial;
    _impresoCliente = widget.data.impresoCliente;
    _impresoCocina = widget.data.impresoCocina;
    _cargarConfigImpresora();
    if (widget.data.items.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _mostrarAlertaSinProductos();
      });
    }
  }

  Future<void> _asegurarColumnasImpresion() async {
    try {
      await _db.customStatement(
        'ALTER TABLE pedidos ADD COLUMN impreso_cliente INTEGER NOT NULL DEFAULT 0',
      );
    } catch (_) {}
    try {
      await _db.customStatement(
        'ALTER TABLE pedidos ADD COLUMN impreso_cocina INTEGER NOT NULL DEFAULT 0',
      );
    } catch (_) {}
  }

  Future<void> _marcarComoImpreso({
    required bool esCocina,
    bool valor = true,
  }) async {
    await _asegurarColumnasImpresion();
    final col = esCocina ? 'impreso_cocina' : 'impreso_cliente';
    await _db.customStatement(
      'UPDATE pedidos SET $col = ? WHERE id = ?',
      [valor ? 1 : 0, widget.data.pedidoId],
    );
    if (!mounted) return;
    setState(() {
      if (esCocina) {
        _impresoCocina = valor;
      } else {
        _impresoCliente = valor;
      }
    });
  }

  Future<bool> _confirmarReimpresionSiYaImpreso() async {
    if (!_yaImpresoActual) return true;
    if (!mounted) return false;

    final tipoTexto = _esModoCocina
        ? 'la orden de cocina'
        : 'la factura para el cliente';
    final titulo = _esModoCocina
        ? 'Orden de cocina ya impresa'
        : 'Factura de cliente ya impresa';

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.print_rounded,
              color: _esModoCocina ? AppColors.comandaCocina : AppColors.primary,
              size: 26,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                titulo,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: Text(
          'Este documento (${widget.data.codigoTurno}) ya figura como impreso. '
          '¿Deseas volver a imprimir $tipoTexto?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor:
                  _esModoCocina ? AppColors.comandaCocina : AppColors.primary,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.replay_rounded, size: 18),
            label: const Text('Sí, volver a imprimir'),
          ),
        ],
      ),
    );

    return confirmar == true;
  }

  Future<void> _mostrarAlertaSinProductos() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: AppColors.comandaCocina,
              size: 28,
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Orden sin productos',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: const Text(
          'Esta orden de cocina no tiene productos registrados. '
          'Agrega productos al pedido antes de generar o imprimir la comanda.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Future<String> _leerConfig(String clave, {String fallback = ''}) async {
    final row = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals(clave)))
        .getSingleOrNull();
    return row?.valor ?? fallback;
  }

  Future<void> _cargarConfigImpresora() async {
    await _asegurarColumnasImpresion();
    final deviceId = await _leerConfig('printer_device_id');
    final deviceName = await _leerConfig('printer_device_name');
    final anchoRaw = await _leerConfig('printer_paper_width', fallback: '32');

    final rowPedido = await _db.customSelect(
      '''
      SELECT COALESCE(impreso_cliente, 0) AS impreso_cliente,
             COALESCE(impreso_cocina, 0) AS impreso_cocina
      FROM pedidos
      WHERE id = ?
      LIMIT 1
      ''',
      variables: [Variable<int>(widget.data.pedidoId)],
    ).getSingleOrNull();

    if (!mounted) return;
    setState(() {
      _printerDeviceId = deviceId;
      _printerDeviceName = deviceName;
      _anchoPapel = AnchoPapelX.desdeCaracteres(int.tryParse(anchoRaw) ?? 32);
      if (rowPedido != null) {
        _impresoCliente =
            ((rowPedido.data['impreso_cliente'] as int?) ?? 0) == 1;
        _impresoCocina =
            ((rowPedido.data['impreso_cocina'] as int?) ?? 0) == 1;
      }
      _cargandoConfig = false;
    });
  }

  Future<void> _imprimirEnTermica() async {
    if (widget.data.items.isEmpty) {
      await _mostrarAlertaSinProductos();
      return;
    }

    final continuar = await _confirmarReimpresionSiYaImpreso();
    if (!continuar) return;

    if (_printerDeviceId.trim().isEmpty) {
      if (!mounted) return;
      final irAConfigurar = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Sin impresora configurada'),
          content: const Text(
            'Aún no has conectado una impresora térmica. Puedes configurarla ahora o imprimir usando el diálogo del sistema.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Imprimir con el sistema'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Configurar impresora'),
            ),
          ],
        ),
      );

      if (irAConfigurar == true) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ConfigImpresorasScreen()),
        );
        await _cargarConfigImpresora();
        return;
      }

      await _imprimirConSistema(confirmado: true);
      return;
    }

    setState(() => _accionEnCurso = true);
    try {
      final bytes = _esModoCocina
          ? await buildEscPosCocinaBytes(widget.data, ancho: _anchoPapel)
          : await buildEscPosBytes(widget.data, ancho: _anchoPapel);
      final device = await _printerService.connect(_printerDeviceId);
      final exito =
          device != null && await _printerService.printBytes(device, bytes);

      if (!mounted) return;
      if (exito) {
        await _marcarComoImpreso(esCocina: _esModoCocina, valor: true);
        if (!mounted) return;
        final mensaje = _esModoCocina
            ? 'Comanda de cocina enviada a $_printerDeviceName (${widget.data.codigoTurno}). Marcada como ya impresa.'
            : 'Factura de cliente enviada a $_printerDeviceName. Marcada como ya impresa.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(mensaje)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No se pudo conectar a la impresora térmica. Se abrirá la impresión del sistema.',
            ),
          ),
        );
        await _imprimirConSistema(confirmado: true);
      }
    } finally {
      if (mounted) setState(() => _accionEnCurso = false);
    }
  }

  Future<void> _imprimirConSistema({bool confirmado = false}) async {
    if (widget.data.items.isEmpty) {
      await _mostrarAlertaSinProductos();
      return;
    }
    if (!confirmado) {
      final continuar = await _confirmarReimpresionSiYaImpreso();
      if (!continuar) return;
    }
    final impreso = await Printing.layoutPdf(
      onLayout: (format) async => _esModoCocina
          ? buildCocinaTicketPdf(widget.data)
          : buildTicketPdf(widget.data),
    );
    if (impreso || mounted) {
      await _marcarComoImpreso(esCocina: _esModoCocina, valor: true);
    }
  }

  Future<File> _generarArchivoPdf() async {
    final bytes = _esModoCocina
        ? await buildCocinaTicketPdf(widget.data)
        : await buildTicketPdf(widget.data);
    final dir = await getTemporaryDirectory();
    final prefijo = _esModoCocina ? 'cocina' : 'ticket';
    final nombre =
        '${prefijo}_${widget.data.codigoTurno}_${widget.data.pedidoId}.pdf';
    final file = File('${dir.path}/$nombre');
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<void> _compartirWhatsapp() async {
    if (widget.data.items.isEmpty) {
      await _mostrarAlertaSinProductos();
      return;
    }
    setState(() => _accionEnCurso = true);
    try {
      final file = await _generarArchivoPdf();
      if (!mounted) return;
      final texto = _esModoCocina
          ? 'Comanda de Cocina ${widget.data.codigoTurno} - ${widget.data.totalCantidadItems} platos'
          : 'Pedido ${widget.data.codigoTurno} - Total: ${formatMoney(widget.data.total)}';
      await Share.shareXFiles(
        [XFile(file.path)],
        text: texto,
      );
    } finally {
      if (mounted) setState(() => _accionEnCurso = false);
    }
  }

  Future<void> _exportarPdf() async {
    if (widget.data.items.isEmpty) {
      await _mostrarAlertaSinProductos();
      return;
    }
    setState(() => _accionEnCurso = true);
    try {
      await _imprimirConSistema(confirmado: false);
    } finally {
      if (mounted) setState(() => _accionEnCurso = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final textoTicket = _esModoCocina
        ? buildPlainCocinaTicket(data, ancho: _anchoPapel)
        : buildPlainTicket(data, ancho: _anchoPapel);

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          _esModoCocina ? 'Comanda para Cocina' : 'Factura para Cliente',
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: _cargandoConfig
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent))
          : SafeArea(
              child: Column(
                children: [
                  // Selector de Tipo de Impresión: Venta vs Cocina
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<bool>(
                        segments: [
                          ButtonSegment<bool>(
                            value: false,
                            icon: Icon(
                              _impresoCliente
                                  ? Icons.check_circle_rounded
                                  : Icons.receipt_long,
                              size: 18,
                            ),
                            label: Text(
                              _impresoCliente
                                  ? 'Factura Cliente (Impresa)'
                                  : 'Factura Cliente',
                            ),
                          ),
                          ButtonSegment<bool>(
                            value: true,
                            icon: Icon(
                              _impresoCocina
                                  ? Icons.check_circle_rounded
                                  : Icons.soup_kitchen_outlined,
                              size: 18,
                            ),
                            label: Text(
                              _impresoCocina
                                  ? 'Comanda Cocina (Impresa)'
                                  : 'Comanda Cocina',
                            ),
                          ),
                        ],
                        selected: {_esModoCocina},
                        onSelectionChanged: (value) {
                          if (value.first && data.items.isEmpty) {
                            _mostrarAlertaSinProductos();
                            return;
                          }
                          setState(() => _esModoCocina = value.first);
                        },
                      ),
                    ),
                  ),
                  // Indicador / Opción marcada de "Ya impreso"
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _marcarComoImpreso(
                        esCocina: _esModoCocina,
                        valor: !_yaImpresoActual,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: _yaImpresoActual
                              ? AppColors.success.withValues(alpha: 0.12)
                              : Colors.grey.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _yaImpresoActual
                                ? AppColors.success
                                : Colors.grey.shade400,
                            width: 1.2,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _yaImpresoActual
                                  ? Icons.check_box_rounded
                                  : Icons.check_box_outline_blank_rounded,
                              color: _yaImpresoActual
                                  ? AppColors.success
                                  : AppColors.textMuted,
                              size: 22,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _yaImpresoActual
                                    ? (_esModoCocina
                                        ? 'Ya impreso: Orden de cocina enviada'
                                        : 'Ya impreso: Factura de cliente enviada')
                                    : (_esModoCocina
                                        ? 'Pendiente por imprimir (Orden de cocina)'
                                        : 'Pendiente por imprimir (Factura cliente)'),
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  color: _yaImpresoActual
                                      ? AppColors.success
                                      : AppColors.textMuted,
                                ),
                              ),
                            ),
                            if (_yaImpresoActual)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: AppColors.success,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  'YA IMPRESO',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: Container(
                          width: 360,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 24),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.08),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _esModoCocina
                                    ? 'ORDEN DE COCINA'
                                    : data.nombreNegocio.toUpperCase(),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                  color: AppColors.primary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _esModoCocina
                                    ? '${data.referenciaONombreTipo} · Despacho'
                                    : data.tituloEstado,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: AppColors.textMuted, fontSize: 12),
                              ),
                              const SizedBox(height: 16),
                              Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 22, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: _esModoCocina
                                        ? AppColors.comandaCocina
                                        : AppColors.primary,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    data.codigoTurno,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 28,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              const Divider(),
                              Text(
                                textoTicket,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12.5,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(color: Colors.black12, blurRadius: 8)
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: _esModoCocina
                                      ? AppColors.comandaCocina
                                      : AppColors.primary,
                                ),
                                onPressed:
                                    _accionEnCurso ? null : _imprimirEnTermica,
                                icon: Icon(
                                  _yaImpresoActual
                                      ? Icons.replay_rounded
                                      : (_esModoCocina
                                          ? Icons.soup_kitchen_outlined
                                          : Icons.print),
                                ),
                                label: Text(
                                  _yaImpresoActual
                                      ? (_esModoCocina
                                          ? 'Volver a imprimir Comanda'
                                          : 'Volver a imprimir Factura')
                                      : (_esModoCocina
                                          ? 'Imprimir Comanda'
                                          : 'Imprimir en POS'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _accionEnCurso ? null : _exportarPdf,
                                icon: const Icon(Icons.picture_as_pdf_outlined),
                                label: Text(
                                  _yaImpresoActual ? 'Reimprimir PDF' : 'PDF',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed:
                                _accionEnCurso ? null : _compartirWhatsapp,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF25D366),
                              side: const BorderSide(color: Color(0xFF25D366)),
                            ),
                            icon: const Icon(Icons.share_outlined),
                            label: Text(_esModoCocina
                                ? 'Enviar Comanda por WhatsApp'
                                : 'Compartir por WhatsApp'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
