import 'dart:io';
import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:intl/intl.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/utils/money_formatter.dart';
import '../../../../database/app_database.dart';
import '../../../../injection_container.dart';
import '../../../impresion/bluetooth_printer_service.dart';
import '../../../impresion/ticket_data.dart';
import '../../domain/entities/item_pedido.dart';
import 'ticket_preview_screen.dart';

String _formatMoney(num value) => formatMoney(value);

class JornadaHistorialScreen extends StatefulWidget {
  final int jornadaId;
  final String jornadaNombre;

  const JornadaHistorialScreen({
    super.key,
    required this.jornadaId,
    required this.jornadaNombre,
  });

  @override
  State<JornadaHistorialScreen> createState() => _JornadaHistorialScreenState();
}

class _JornadaHistorialScreenState extends State<JornadaHistorialScreen> {
  final AppDatabase _db = sl<AppDatabase>();

  bool _loading = true;
  String _filtroEstado = 'todos';
  String _query = '';
  List<_PedidoHistorial> _pedidos = const [];
  _ResumenVentas _resumen = const _ResumenVentas();

  Future<String> _leerConfig(String clave, {String fallback = ''}) async {
    final row = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals(clave)))
        .getSingleOrNull();
    return row?.valor ?? fallback;
  }

  final BluetoothPrinterService _printerService =
      const BluetoothPrinterService();

  Future<bool> _imprimirDirectoBluetooth(String contenido) async {
    final deviceId = await _leerConfig('printer_device_id');
    if (deviceId.trim().isEmpty) return false;

    final device = await _printerService.connect(deviceId);
    if (device == null) return false;

    final bytes = <int>[
      0x1B, 0x40, // ESC @ (Reset printer)
      ...utf8.encode('$contenido\n\n\n\n'),
    ];
    return _printerService.printBytes(device, bytes);
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _loading = true);

    final pedidosRows = await _db.customSelect(
      '''
      SELECT id, tipo, estado, referencia, cliente, mesero, valor_domicilio,
             COALESCE(numero_turno, 0) AS numero_turno,
             COALESCE(medio_pago, '') AS medio_pago
      FROM pedidos
      WHERE jornada_id = ?
      ORDER BY id DESC
      ''',
      variables: [Variable<int>(widget.jornadaId)],
    ).get();

    final pedidos = <_PedidoHistorial>[];
    for (final row in pedidosRows) {
      final data = row.data;
      final pedidoId = data['id'] as int;

      final stat = await _db.customSelect(
        '''
        SELECT COALESCE(COUNT(id), 0) AS items_count,
               COALESCE(SUM(precio * cantidad), 0) AS subtotal
        FROM items_pedido
        WHERE pedido_id = ?
        ''',
        variables: [Variable<int>(pedidoId)],
      ).getSingle();

      final subtotal = (stat.data['subtotal'] as num?)?.toDouble() ?? 0;
      final domicilio = (data['valor_domicilio'] as num?)?.toDouble() ?? 0;
      final tipo = (data['tipo'] as String?) ?? 'mesa';
      final total = subtotal + (tipo == 'domicilio' ? domicilio : 0);

      pedidos.add(
        _PedidoHistorial(
          id: pedidoId,
          tipo: tipo,
          estado: (data['estado'] as String?) ?? 'abierto',
          referencia: ((data['referencia'] as String?) ?? '').trim(),
          cliente: ((data['cliente'] as String?) ?? '').trim(),
          mesero: ((data['mesero'] as String?) ?? '').trim(),
          itemsCount: (stat.data['items_count'] as int?) ?? 0,
          subtotal: subtotal,
          domicilio: domicilio,
          total: total,
          numeroTurno: (data['numero_turno'] as int?) ?? 0,
          medioPago: ((data['medio_pago'] as String?) ?? '').trim(),
        ),
      );
    }

    final cerrados = pedidos.where((p) => p.estado == 'cerrado').toList();
    final cancelados = pedidos.where((p) => p.estado == 'cancelado').toList();
    final totalProductos =
        cerrados.fold<double>(0, (sum, p) => sum + p.subtotal);
    final totalDomicilios = cerrados
        .where((p) => p.tipo == 'domicilio')
        .fold<double>(0, (sum, p) => sum + p.domicilio);
    final totalGeneral = totalProductos + totalDomicilios;
    final totalCancelados =
        cancelados.fold<double>(0, (sum, p) => sum + p.total);

    // Desglose de ventas por medio de pago
    double totalEfectivo = 0;
    int cantEfectivo = 0;
    double totalTransferencia = 0;
    int cantTransferencia = 0;
    final detalleTransferencias = <String, double>{};
    final cantTransferencias = <String, int>{};

    for (final p in cerrados) {
      final medio = p.medioPago.trim();
      if (medio.isEmpty || medio.toLowerCase().contains('efectivo')) {
        totalEfectivo += p.total;
        cantEfectivo++;
      } else {
        totalTransferencia += p.total;
        cantTransferencia++;
        final tag = medio
            .replaceAll('Transferencia', '')
            .replaceAll('(', '')
            .replaceAll(')', '')
            .replaceAll('-', '')
            .trim();
        final key = tag.isNotEmpty ? tag : 'General';
        detalleTransferencias[key] = (detalleTransferencias[key] ?? 0) + p.total;
        cantTransferencias[key] = (cantTransferencias[key] ?? 0) + 1;
      }
    }

    if (!mounted) return;
    setState(() {
      _pedidos = pedidos;
      _resumen = _ResumenVentas(
        totalProductos: totalProductos,
        totalDomicilios: totalDomicilios,
        totalGeneral: totalGeneral,
        totalCancelados: cancelados.length,
        totalCanceladosMonto: totalCancelados,
        totalPedidos: pedidos.length,
        totalCerrados: cerrados.length,
        totalEfectivo: totalEfectivo,
        cantEfectivo: cantEfectivo,
        totalTransferencia: totalTransferencia,
        cantTransferencia: cantTransferencia,
        detalleTransferencias: detalleTransferencias,
        cantTransferencias: cantTransferencias,
      );
      _loading = false;
    });
  }

  Future<void> _verTicket(_PedidoHistorial pedido) async {
    if (pedido.itemsCount <= 0) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Sin productos en el pedido'),
          content: const Text(
              'Este pedido no tiene productos registrados para mostrar en el ticket.'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Entendido'),
            ),
          ],
        ),
      );
      return;
    }

    final itemsRows = await (_db.select(_db.itemsPedido)
          ..where((i) => i.pedidoId.equals(pedido.id)))
        .get();

    final items = itemsRows
        .map(
          (row) => ItemPedido(
            id: row.id,
            pedidoId: row.pedidoId,
            productoId: row.productoId,
            nombreProducto: row.nombreProducto,
            precio: row.precio,
            cantidad: row.cantidad,
            adicionales: () {
              try {
                final decoded = jsonDecode(row.adicionales);
                if (decoded is List) {
                  return decoded.map((e) => e.toString()).toList();
                }
              } catch (_) {}
              return <String>[];
            }(),
            nota: row.nota,
          ),
        )
        .toList();

    final nombreNegocio =
        await _leerConfig('nombre_negocio', fallback: 'POSify');

    final data = TicketData(
      nombreNegocio: nombreNegocio,
      pedidoId: pedido.id,
      numeroTurno: pedido.numeroTurno,
      tipo: pedido.tipo,
      referencia: pedido.referencia,
      cliente: pedido.cliente,
      mesero: pedido.mesero,
      items: items,
      valorDomicilio: pedido.domicilio,
      cobrarDomicilio: pedido.domicilio > 0,
      estadoPedido: pedido.estado,
      fecha: DateTime.now(),
      medioPago: pedido.medioPago,
    );

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TicketPreviewScreen(data: data)),
    );
  }

  Future<String> _construirInformePosTexto() async {
    final filas = await _db.customSelect(
      '''
      SELECT i.nombre_producto AS producto,
             COALESCE(SUM(i.cantidad), 0) AS cantidad,
             COALESCE(SUM(i.precio * i.cantidad), 0) AS total
      FROM items_pedido i
      JOIN pedidos p ON p.id = i.pedido_id
      WHERE p.jornada_id = ? AND p.estado = 'cerrado'
      GROUP BY i.nombre_producto
      ORDER BY cantidad DESC
      ''',
      variables: [Variable<int>(widget.jornadaId)],
    ).get();

    final resumenDomicilios = await _db.customSelect(
      '''
      SELECT COALESCE(COUNT(*), 0) AS pedidos_cerrados,
             COALESCE(SUM(valor_domicilio), 0) AS total_domicilios
      FROM pedidos
      WHERE jornada_id = ? AND estado = 'cerrado' AND tipo = 'domicilio'
      ''',
      variables: [Variable<int>(widget.jornadaId)],
    ).getSingle();

    final resumenCancelados = await _db.customSelect(
      '''
      SELECT COALESCE(COUNT(*), 0) AS pedidos_cancelados,
             COALESCE(SUM(
               COALESCE((
                 SELECT SUM(i.precio * i.cantidad)
                 FROM items_pedido i
                 WHERE i.pedido_id = p.id
               ), 0) + p.valor_domicilio
             ), 0) AS total_cancelados
      FROM pedidos p
      WHERE p.jornada_id = ? AND p.estado = 'cancelado'
      ''',
      variables: [Variable<int>(widget.jornadaId)],
    ).getSingle();

    final totalProductos = filas.fold<double>(
      0,
      (sum, row) => sum + ((row.data['total'] as num?)?.toDouble() ?? 0),
    );
    final totalDomicilios =
        (resumenDomicilios.data['total_domicilios'] as num?)?.toDouble() ?? 0;
    final totalGeneral = totalProductos + totalDomicilios;
    final pedidosCancelados =
        (resumenCancelados.data['pedidos_cancelados'] as int?) ?? 0;
    final totalCancelados =
        (resumenCancelados.data['total_cancelados'] as num?)?.toDouble() ?? 0;

    final detalleRows = await _db.customSelect(
      '''
      SELECT i.nombre_producto AS producto,
             COALESCE(SUM(i.cantidad), 0) AS cantidad,
             i.precio AS precio,
             COALESCE(NULLIF(TRIM(i.adicionales), ''), '[]') AS adicionales,
             TRIM(COALESCE(i.nota, '')) AS nota
      FROM items_pedido i
      JOIN pedidos p ON p.id = i.pedido_id
      WHERE p.jornada_id = ? AND p.estado = 'cerrado'
      GROUP BY i.producto_id,
               i.nombre_producto,
               i.precio,
               COALESCE(NULLIF(TRIM(i.adicionales), ''), '[]'),
               TRIM(COALESCE(i.nota, ''))
      ORDER BY i.nombre_producto ASC, i.precio ASC
      ''',
      variables: [Variable<int>(widget.jornadaId)],
    ).get();

    final buffer = StringBuffer();
    buffer.writeln('INFORME POS - ${widget.jornadaNombre}');
    buffer.writeln(
        'Fecha: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}');
    buffer.writeln('----------------------------------------');
    if (filas.isEmpty) {
      buffer.writeln('Sin ventas cerradas en esta jornada.');
    } else {
      for (final row in filas) {
        final producto = (row.data['producto'] as String?) ?? 'Producto';
        final cantidad = (row.data['cantidad'] as int?) ?? 0;
        final total = (row.data['total'] as num?)?.toDouble() ?? 0;
        buffer.writeln('$cantidad x $producto = ${_formatMoney(total)}');
      }
    }
    buffer.writeln('----------------------------------------');
    buffer.writeln('TOTAL PRODUCTOS VENDIDOS: ${_formatMoney(totalProductos)}');
    buffer.writeln('TOTAL DOMICILIOS: ${_formatMoney(totalDomicilios)}');
    buffer.writeln('----------------------------------------');
    buffer.writeln('VENTAS POR MEDIO DE PAGO:');
    buffer.writeln(
        '  • Efectivo: ${_formatMoney(_resumen.totalEfectivo)} (${_resumen.cantEfectivo} pedidos)');
    buffer.writeln(
        '  • Transferencias: ${_formatMoney(_resumen.totalTransferencia)} (${_resumen.cantTransferencia} pedidos)');
    if (_resumen.detalleTransferencias.isNotEmpty) {
      for (final entry in _resumen.detalleTransferencias.entries) {
        final cant = _resumen.cantTransferencias[entry.key] ?? 1;
        buffer.writeln(
            '    - ${entry.key}: ${_formatMoney(entry.value)} ($cant pedidos)');
      }
    }
    buffer.writeln('----------------------------------------');
    buffer.writeln(
        'CANCELADOS (informativo): $pedidosCancelados pedido(s) - ${_formatMoney(totalCancelados)}');
    buffer.writeln('TOTAL GENERAL: ${_formatMoney(totalGeneral)}');
    buffer.writeln('----------------------------------------');
    buffer.writeln('DETALLE DE ITEMS Y OBSERVACIONES');
    if (detalleRows.isEmpty) {
      buffer.writeln('Sin detalle de items.');
    } else {
      for (final row in detalleRows) {
        final producto = (row.data['producto'] as String?) ?? 'Producto';
        final cantidad = (row.data['cantidad'] as int?) ?? 0;
        final precio = (row.data['precio'] as num?)?.toDouble() ?? 0;
        final nota = ((row.data['nota'] as String?) ?? '').trim();

        final adicionalesRaw =
            ((row.data['adicionales'] as String?) ?? '[]').trim();
        List<String> adicionales = const [];
        try {
          final parsed = jsonDecode(adicionalesRaw);
          if (parsed is List) {
            adicionales = parsed.map((e) => e.toString()).toList();
          }
        } catch (_) {
          adicionales = const [];
        }

        buffer.writeln('$cantidad x $producto (${_formatMoney(precio)})');
        if (adicionales.isNotEmpty) {
          buffer.writeln('  Etiquetas: ${adicionales.join(', ')}');
        }
        if (nota.isNotEmpty) {
          buffer.writeln('  Nota: $nota');
        }
      }
    }

    return buffer.toString();
  }

  Future<void> _descargarInformePos() async {
    final contenido = await _construirInformePosTexto();

    final dir = await getTemporaryDirectory();
    final safeName =
        widget.jornadaNombre.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final path = '${dir.path}/informe_pos_${safeName}_${widget.jornadaId}.txt';
    final file = File(path);
    await file.writeAsString(contenido);

    if (!mounted) return;
    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'Informe POS de ${widget.jornadaNombre}',
    );
  }

  Future<void> _descargarInformeCsv() async {
    final filas = <List<dynamic>>[
      [
        'jornada_id',
        'jornada_nombre',
        'pedido_id',
        'estado',
        'tipo',
        'referencia',
        'cliente',
        'mesero',
        'medio_pago',
        'items',
        'subtotal',
        'domicilio',
        'total',
      ],
    ];

    for (final p in _pedidos) {
      filas.add([
        widget.jornadaId,
        widget.jornadaNombre,
        p.id,
        p.estado,
        p.tipo,
        p.referencia,
        p.cliente,
        p.mesero,
        p.medioPago.isNotEmpty ? p.medioPago : 'Efectivo',
        p.itemsCount,
        p.subtotal.toStringAsFixed(2),
        p.domicilio.toStringAsFixed(2),
        p.total.toStringAsFixed(2),
      ]);
    }

    filas.add([]);
    filas.add(['RESUMEN DE VENTAS POR MEDIO DE PAGO']);
    filas.add(['Efectivo', _resumen.totalEfectivo.toStringAsFixed(2), '${_resumen.cantEfectivo} pedidos']);
    filas.add(['Transferencias', _resumen.totalTransferencia.toStringAsFixed(2), '${_resumen.cantTransferencia} pedidos']);
    filas.add(['TOTAL GENERAL', _resumen.totalGeneral.toStringAsFixed(2), '${_resumen.totalCerrados} pedidos']);

    final contenido = const ListToCsvConverter().convert(filas);
    final dir = await getTemporaryDirectory();
    final safeName =
        widget.jornadaNombre.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final path = '${dir.path}/informe_pos_${safeName}_${widget.jornadaId}.csv';
    final file = File(path);
    await file.writeAsString(contenido);

    if (!mounted) return;
    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'Informe CSV (compatible con Excel) de ${widget.jornadaNombre}',
    );
  }

  Future<void> _imprimirInformePos() async {
    final contenido = await _construirInformePosTexto();

    final impresoBluetooth = await _imprimirDirectoBluetooth(contenido);
    if (impresoBluetooth) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Informe enviado por Bluetooth a la impresora conectada.'),
        ),
      );
      return;
    }

    await Printing.layoutPdf(
      onLayout: (format) async {
        final doc = pw.Document();
        doc.addPage(
          pw.MultiPage(
            build: (context) => [
              pw.Text(
                contenido,
                style: pw.TextStyle(
                  font: pw.Font.courier(),
                  fontSize: 10,
                ),
              ),
            ],
          ),
        );
        return doc.save();
      },
    );
  }

  Future<void> _eliminarJornada() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar jornada'),
        content: Text(
          '¿Estás seguro de eliminar la "${widget.jornadaNombre}"? Esta acción borrará permanentemente la jornada y todos sus pedidos e ítems asociados.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sí, eliminar'),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    await _db.transaction(() async {
      await _db.customStatement(
        'DELETE FROM items_pedido WHERE pedido_id IN (SELECT id FROM pedidos WHERE jornada_id = ?)',
        [widget.jornadaId],
      );
      await _db.customStatement(
        'DELETE FROM pedidos WHERE jornada_id = ?',
        [widget.jornadaId],
      );
      await _db.customStatement(
        'DELETE FROM jornadas WHERE id = ?',
        [widget.jornadaId],
      );
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Jornada eliminada correctamente.')),
    );
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final pedidosFiltrados = _pedidos.where((p) {
      final coincideEstado =
          _filtroEstado == 'todos' || p.estado == _filtroEstado;
      final texto =
          '${p.referencia} ${p.cliente} ${p.mesero} ${p.id}'.toLowerCase();
      final coincideQuery =
          _query.trim().isEmpty || texto.contains(_query.toLowerCase());
      return coincideEstado && coincideQuery;
    }).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          'Historial ${widget.jornadaNombre}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Opciones de informe',
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) {
              switch (value) {
                case 'imprimir':
                  _imprimirInformePos();
                  break;
                case 'csv':
                  _descargarInformeCsv();
                  break;
                case 'txt':
                  _descargarInformePos();
                  break;
                case 'eliminar':
                  _eliminarJornada();
                  break;
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'imprimir',
                child: Text('Imprimir informe'),
              ),
              PopupMenuItem<String>(
                value: 'csv',
                child: Text('Descargar CSV (Excel)'),
              ),
              PopupMenuItem<String>(
                value: 'txt',
                child: Text('Descargar TXT'),
              ),
              PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'eliminar',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, color: AppColors.error, size: 20),
                    SizedBox(width: 8),
                    Text('Eliminar jornada',
                        style: TextStyle(color: AppColors.error)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _ResumenCard(
                            label: 'Productos vendidos',
                            value: _resumen.totalProductos,
                          ),
                          const SizedBox(width: 8),
                          _ResumenCard(
                            label: 'Domicilios',
                            value: _resumen.totalDomicilios,
                          ),
                          const SizedBox(width: 8),
                          _ResumenCard(
                            label: 'Total jornada',
                            value: _resumen.totalGeneral,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Desglose de Ventas por Medio de Pago (Efectivo y Transferencias)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.primary.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.payments_outlined,
                                    size: 17, color: AppColors.primary),
                                SizedBox(width: 6),
                                Text(
                                  'Desglose por medio de pago:',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12.5,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF15803D)
                                          .withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: const Color(0xFF15803D)
                                            .withValues(alpha: 0.25),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          '💵 Efectivo',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF15803D),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _formatMoney(_resumen.totalEfectivo),
                                          style: const TextStyle(
                                            fontSize: 14.5,
                                            fontWeight: FontWeight.w900,
                                            color: Color(0xFF15803D),
                                          ),
                                        ),
                                        Text(
                                          '${_resumen.cantEfectivo} pedido(s)',
                                          style: const TextStyle(
                                            fontSize: 10.5,
                                            color: AppColors.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0284C7)
                                          .withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: const Color(0xFF0284C7)
                                            .withValues(alpha: 0.25),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          '📱 Transferencias',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF0284C7),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _formatMoney(
                                              _resumen.totalTransferencia),
                                          style: const TextStyle(
                                            fontSize: 14.5,
                                            fontWeight: FontWeight.w900,
                                            color: Color(0xFF0284C7),
                                          ),
                                        ),
                                        Text(
                                          '${_resumen.cantTransferencia} pedido(s)',
                                          style: const TextStyle(
                                            fontSize: 10.5,
                                            color: AppColors.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (_resumen.detalleTransferencias.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: _resumen
                                    .detalleTransferencias.entries
                                    .map((e) {
                                  final cant =
                                      _resumen.cantTransferencias[e.key] ?? 1;
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 7, vertical: 2.5),
                                    decoration: BoxDecoration(
                                      color: Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                          color: Colors.grey.shade300),
                                    ),
                                    child: Text(
                                      '${e.key}: ${_formatMoney(e.value)} ($cant)',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF334155),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _ResumenMeta(
                              label: 'Pedidos: ${_resumen.totalPedidos}',
                              color: AppColors.textPrimary,
                            ),
                            _ResumenMeta(
                              label: 'Cerrados: ${_resumen.totalCerrados}',
                              color: AppColors.success,
                            ),
                            _ResumenMeta(
                              label: 'Cancelados: ${_resumen.totalCancelados}',
                              color: AppColors.error,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Los cancelados se muestran aparte y no suman al total de la jornada.',
                          style: TextStyle(
                            color: AppColors.textMuted.withValues(alpha: 0.9),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText:
                              'Buscar pedido, cliente, mesero o referencia',
                        ),
                        onChanged: (value) => setState(() => _query = value),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _EstadoFilter(
                              label: 'Todos (${_resumen.totalPedidos})',
                              icon: Icons.list_alt_rounded,
                              color: AppColors.primary,
                              active: _filtroEstado == 'todos',
                              onTap: () =>
                                  setState(() => _filtroEstado = 'todos'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _EstadoFilter(
                              label: 'Cerrados (${_resumen.totalCerrados})',
                              icon: Icons.check_circle_outline_rounded,
                              color: AppColors.success,
                              active: _filtroEstado == 'cerrado',
                              onTap: () =>
                                  setState(() => _filtroEstado = 'cerrado'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _EstadoFilter(
                              label: 'Cancelados (${_resumen.totalCancelados})',
                              icon: Icons.cancel_outlined,
                              color: AppColors.error,
                              active: _filtroEstado == 'cancelado',
                              onTap: () =>
                                  setState(() => _filtroEstado = 'cancelado'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: pedidosFiltrados.isEmpty
                      ? const Center(
                          child: Text(
                            'No hay pedidos para este filtro.',
                            style: TextStyle(color: AppColors.textMuted),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          itemBuilder: (_, i) {
                            final p = pedidosFiltrados[i];
                            return Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: AppColors.primary,
                                            borderRadius:
                                                BorderRadius.circular(100),
                                          ),
                                          child: Text(
                                            codigoTurnoDesde(
                                                p.numeroTurno > 0
                                                    ? p.numeroTurno
                                                    : p.id),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                        if (p.medioPago.isNotEmpty) ...[
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: p.medioPago
                                                      .toLowerCase()
                                                      .contains('efectivo')
                                                  ? const Color(0xFF15803D)
                                                      .withValues(alpha: 0.12)
                                                  : const Color(0xFF0284C7)
                                                      .withValues(alpha: 0.12),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              p.medioPago,
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                                color: p.medioPago
                                                        .toLowerCase()
                                                        .contains('efectivo')
                                                    ? const Color(0xFF15803D)
                                                    : const Color(0xFF0284C7),
                                              ),
                                            ),
                                          ),
                                        ],
                                        const Spacer(),
                                        Text(
                                          p.estado,
                                          style: TextStyle(
                                            color: p.estado == 'cancelado'
                                                ? AppColors.error
                                                : (p.estado == 'cerrado'
                                                    ? AppColors.success
                                                    : AppColors.warning),
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${p.tipo == 'domicilio' ? 'Domicilio' : 'Mesa'} · ${p.itemsCount} item(s)',
                                      style: const TextStyle(
                                          color: AppColors.textMuted),
                                    ),
                                    if (p.referencia.isNotEmpty)
                                      Text('Ref: ${p.referencia}'),
                                    if (p.cliente.isNotEmpty)
                                      Text('Cliente: ${p.cliente}'),
                                    if (p.mesero.isNotEmpty)
                                      Text('Mesero: ${p.mesero}'),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Productos: ${_formatMoney(p.subtotal)} · Domicilio: ${_formatMoney(p.domicilio)} · Total: ${_formatMoney(p.total)}',
                                      style: const TextStyle(
                                        color: AppColors.textPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (p.estado == 'cancelado') ...[
                                      const SizedBox(height: 4),
                                      const Text(
                                        'Pedido cancelado. Solo informativo.',
                                        style: TextStyle(
                                          color: AppColors.error,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                    if (p.estado != 'abierto' &&
                                        p.itemsCount > 0) ...[
                                      const SizedBox(height: 8),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor:
                                                AppColors.verTicket,
                                            side: const BorderSide(
                                                color: AppColors.verTicket),
                                          ),
                                          onPressed: () => _verTicket(p),
                                          icon: const Icon(Icons.receipt_long,
                                              size: 18),
                                          label: const Text(
                                              'Ver / reimprimir ticket'),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemCount: pedidosFiltrados.length,
                        ),
                ),
              ],
            ),
    );
  }
}

class _ResumenVentas {
  final double totalProductos;
  final double totalDomicilios;
  final double totalGeneral;
  final int totalCancelados;
  final double totalCanceladosMonto;
  final int totalPedidos;
  final int totalCerrados;
  final double totalEfectivo;
  final int cantEfectivo;
  final double totalTransferencia;
  final int cantTransferencia;
  final Map<String, double> detalleTransferencias;
  final Map<String, int> cantTransferencias;

  const _ResumenVentas({
    this.totalProductos = 0,
    this.totalDomicilios = 0,
    this.totalGeneral = 0,
    this.totalCancelados = 0,
    this.totalCanceladosMonto = 0,
    this.totalPedidos = 0,
    this.totalCerrados = 0,
    this.totalEfectivo = 0,
    this.cantEfectivo = 0,
    this.totalTransferencia = 0,
    this.cantTransferencia = 0,
    this.detalleTransferencias = const {},
    this.cantTransferencias = const {},
  });
}

class _PedidoHistorial {
  final int id;
  final String tipo;
  final String estado;
  final String referencia;
  final String cliente;
  final String mesero;
  final int itemsCount;
  final double subtotal;
  final double domicilio;
  final double total;
  final int numeroTurno;
  final String medioPago;

  const _PedidoHistorial({
    required this.id,
    required this.tipo,
    required this.estado,
    required this.referencia,
    required this.cliente,
    required this.mesero,
    required this.itemsCount,
    required this.subtotal,
    this.numeroTurno = 0,
    required this.domicilio,
    required this.total,
    this.medioPago = '',
  });
}

class _ResumenCard extends StatelessWidget {
  final String label;
  final double value;

  const _ResumenCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                _formatMoney(value),
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResumenMeta extends StatelessWidget {
  final String label;
  final Color color;

  const _ResumenMeta({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _EstadoFilter extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  const _EstadoFilter({
    required this.label,
    required this.icon,
    required this.color,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? color : AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active ? color : color.withValues(alpha: 0.35),
              width: active ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: active ? Colors.white : color,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: active ? Colors.white : AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
