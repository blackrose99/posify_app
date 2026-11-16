import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/utils/money_formatter.dart';
import '../../../../database/app_database.dart';
import '../../../../injection_container.dart';
import '../../../impresion/bluetooth_printer_service.dart';

class ConfigProductosScreen extends StatefulWidget {
  const ConfigProductosScreen({super.key});

  @override
  State<ConfigProductosScreen> createState() => _ConfigProductosScreenState();
}

class _ConfigProductosScreenState extends State<ConfigProductosScreen> {
  final AppDatabase _db = sl<AppDatabase>();
  final BluetoothPrinterService _printerService =
      const BluetoothPrinterService();

  bool _loading = true;
  bool _imprimiendoRanking = false;
  String _query = '';
  int? _categoriaFiltroId;
  List<Categoria> _categorias = const [];
  List<Producto> _productos = const [];
  Map<int, double?> _costosPorProducto = const {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _loading = true);

    final categorias = await (_db.select(_db.categorias)
          ..orderBy([(c) => drift.OrderingTerm(expression: c.orden)]))
        .get();

    final productos = await (_db.select(_db.productos)
          ..where((p) => p.activo.equals(true))
          ..orderBy([
            (p) => drift.OrderingTerm(
                expression: p.id, mode: drift.OrderingMode.desc)
          ]))
        .get();

    final costosRows = await _db.customSelect(
      'SELECT id, costo FROM productos WHERE activo = 1',
    ).get();
    final costos = <int, double?>{};
    for (final row in costosRows) {
      final id = row.data['id'] as int?;
      final costo = (row.data['costo'] as num?)?.toDouble();
      if (id != null) {
        costos[id] = costo;
      }
    }

    if (!mounted) return;
    setState(() {
      _categorias = categorias;
      _productos = productos;
      _costosPorProducto = costos;
      if (_categoriaFiltroId != null &&
          !categorias.any((c) => c.id == _categoriaFiltroId)) {
        _categoriaFiltroId = null;
      }
      _loading = false;
    });
  }

  Future<String> _leerConfig(String clave, {String fallback = ''}) async {
    final row = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals(clave)))
        .getSingleOrNull();
    return row?.valor ?? fallback;
  }

  Widget _buildMargenPreview(String precioText, String costoText) {
    final precio = double.tryParse(precioText.trim());
    final costo =
        costoText.trim().isEmpty ? null : double.tryParse(costoText.trim());

    if (costo == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Costo opcional: si lo ingresas, verás la ganancia y margen real en informes.',
            style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
          ),
        ),
      );
    }

    if (precio == null || precio <= 0 || costo < 0) {
      return const SizedBox.shrink();
    }

    final ganancia = precio - costo;
    final margenPct = (ganancia / precio) * 100;
    final esPositivo = ganancia >= 0;
    final color = esPositivo ? AppColors.success : AppColors.error;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        'Ganancia: ${formatMoney(ganancia)} · Margen: ${margenPct.toStringAsFixed(1)}%',
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Future<void> _crearProducto() async {
    if (_categorias.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Primero crea una categoria.')),
      );
      return;
    }

    int categoriaId = _categoriaFiltroId ?? _categorias.first.id;
    final nombreCtrl = TextEditingController();
    final descripcionCtrl = TextEditingController();
    final precioCtrl = TextEditingController();
    final costoCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: const Text('Nuevo producto'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: categoriaId,
                  decoration: const InputDecoration(labelText: 'Categoria'),
                  items: _categorias
                      .map((c) =>
                          DropdownMenuItem(value: c.id, child: Text(c.nombre)))
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setLocalState(() => categoriaId = value);
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nombreCtrl,
                  decoration: const InputDecoration(labelText: 'Nombre'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: descripcionCtrl,
                  decoration: const InputDecoration(labelText: 'Descripcion'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: precioCtrl,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Precio de venta'),
                  onChanged: (_) => setLocalState(() {}),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: costoCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Costo de preparacion (opcional)',
                    hintText: 'Ej: 18000',
                  ),
                  onChanged: (_) => setLocalState(() {}),
                ),
                _buildMargenPreview(precioCtrl.text, costoCtrl.text),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Crear'),
            ),
          ],
        ),
      ),
    );

    if (ok != true) return;

    final nombre = nombreCtrl.text.trim();
    final precio = double.tryParse(precioCtrl.text.trim());
    final costoText = costoCtrl.text.trim();
    final costo = costoText.isEmpty ? null : double.tryParse(costoText);
    if (nombre.isEmpty || precio == null || precio <= 0) return;

    final nuevoId = await _db.into(_db.productos).insert(
          ProductosCompanion.insert(
            categoriaId: categoriaId,
            nombre: nombre,
            descripcion: drift.Value(descripcionCtrl.text.trim()),
            precio: precio,
          ),
        );

    if (costo != null && costo >= 0) {
      await _db.customStatement(
        'UPDATE productos SET costo = ? WHERE id = ?',
        [costo, nuevoId],
      );
    }

    await _cargar();
  }

  Future<void> _editarProducto(Producto producto) async {
    int categoriaId = producto.categoriaId;
    final nombreCtrl = TextEditingController(text: producto.nombre);
    final descripcionCtrl = TextEditingController(text: producto.descripcion);
    final precioCtrl =
        TextEditingController(text: producto.precio.toStringAsFixed(0));
    final costoActual = _costosPorProducto[producto.id];
    final costoCtrl = TextEditingController(
      text: costoActual != null ? costoActual.toStringAsFixed(0) : '',
    );

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: const Text('Editar producto'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: categoriaId,
                  decoration: const InputDecoration(labelText: 'Categoria'),
                  items: _categorias
                      .map((c) =>
                          DropdownMenuItem(value: c.id, child: Text(c.nombre)))
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setLocalState(() => categoriaId = value);
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nombreCtrl,
                  decoration: const InputDecoration(labelText: 'Nombre'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: descripcionCtrl,
                  decoration: const InputDecoration(labelText: 'Descripcion'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: precioCtrl,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Precio de venta'),
                  onChanged: (_) => setLocalState(() {}),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: costoCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Costo de preparacion (opcional)',
                    hintText: 'Vacio para no calcular costo',
                  ),
                  onChanged: (_) => setLocalState(() {}),
                ),
                _buildMargenPreview(precioCtrl.text, costoCtrl.text),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );

    if (ok != true) return;

    final nombre = nombreCtrl.text.trim();
    final precio = double.tryParse(precioCtrl.text.trim());
    final costoText = costoCtrl.text.trim();
    final costo = costoText.isEmpty ? null : double.tryParse(costoText);
    if (nombre.isEmpty || precio == null || precio <= 0) return;

    await (_db.update(_db.productos)..where((p) => p.id.equals(producto.id)))
        .write(
      ProductosCompanion(
        categoriaId: drift.Value(categoriaId),
        nombre: drift.Value(nombre),
        descripcion: drift.Value(descripcionCtrl.text.trim()),
        precio: drift.Value(precio),
      ),
    );

    await _db.customStatement(
      'UPDATE productos SET costo = ? WHERE id = ?',
      [costo != null && costo >= 0 ? costo : null, producto.id],
    );

    await _cargar();
  }

  Future<void> _eliminarProducto(Producto producto) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar producto'),
        content: Text('Deseas eliminar ${producto.nombre}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    await (_db.update(_db.productos)..where((p) => p.id.equals(producto.id)))
        .write(
      const ProductosCompanion(activo: drift.Value(false)),
    );

    await _cargar();
  }

  Future<_DatosRankingHistorico> _obtenerRankingHistorico() async {
    final jornadasRow = await _db.customSelect(
      'SELECT COUNT(*) AS cnt FROM jornadas',
    ).getSingle();
    final totalJornadas = (jornadasRow.data['cnt'] as int?) ?? 0;

    final pedidosRow = await _db.customSelect(
      "SELECT COUNT(*) AS cnt FROM pedidos WHERE estado = 'cerrado'",
    ).getSingle();
    final totalPedidosCerrados = (pedidosRow.data['cnt'] as int?) ?? 0;

    final ventasRows = await _db.customSelect(
      '''
      SELECT i.producto_id AS producto_id,
             COALESCE(prod.nombre, i.nombre_producto) AS nombre,
             COALESCE(SUM(i.cantidad), 0) AS cantidad,
             COALESCE(SUM(i.precio * i.cantidad), 0) AS total_ventas,
             MAX(COALESCE(prod.precio, i.precio)) AS precio_unitario,
             MAX(prod.costo) AS costo_unitario,
             MAX(cat.nombre) AS categoria
      FROM items_pedido i
      JOIN pedidos p ON p.id = i.pedido_id
      LEFT JOIN productos prod ON prod.id = i.producto_id
      LEFT JOIN categorias cat ON cat.id = prod.categoria_id
      WHERE p.estado = 'cerrado'
      GROUP BY COALESCE(prod.id, i.nombre_producto)
      ''',
    ).get();

    final mapa = <String, _ItemRankingProducto>{};
    for (final row in ventasRows) {
      final nombre = ((row.data['nombre'] as String?) ?? 'Producto').trim();
      final key = nombre.toLowerCase();
      final cant = (row.data['cantidad'] as num?)?.toInt() ?? 0;
      final ventas = (row.data['total_ventas'] as num?)?.toDouble() ?? 0;
      final precio = (row.data['precio_unitario'] as num?)?.toDouble() ?? 0;
      final costo = (row.data['costo_unitario'] as num?)?.toDouble();
      final categoria =
          ((row.data['categoria'] as String?) ?? 'General').trim();

      final existente = mapa[key];
      if (existente == null) {
        mapa[key] = _ItemRankingProducto(
          nombre: nombre,
          categoria: categoria.isEmpty ? 'General' : categoria,
          cantidadVendida: cant,
          totalVentas: ventas,
          precioUnitario: precio,
          costoUnitario: costo,
        );
      } else {
        mapa[key] = _ItemRankingProducto(
          nombre: existente.nombre,
          categoria: existente.categoria,
          cantidadVendida: existente.cantidadVendida + cant,
          totalVentas: existente.totalVentas + ventas,
          precioUnitario: existente.precioUnitario > 0
              ? existente.precioUnitario
              : precio,
          costoUnitario: existente.costoUnitario ?? costo,
        );
      }
    }

    for (final p in _productos) {
      final key = p.nombre.trim().toLowerCase();
      if (!mapa.containsKey(key)) {
        final cat = _categorias
            .firstWhere(
              (c) => c.id == p.categoriaId,
              orElse: () =>
                  const Categoria(id: 0, nombre: 'General', orden: 0),
            )
            .nombre;
        mapa[key] = _ItemRankingProducto(
          nombre: p.nombre.trim(),
          categoria: cat,
          cantidadVendida: 0,
          totalVentas: 0,
          precioUnitario: p.precio,
          costoUnitario: _costosPorProducto[p.id],
        );
      }
    }

    final items = mapa.values.toList()
      ..sort((a, b) {
        final cmpCant = b.cantidadVendida.compareTo(a.cantidadVendida);
        if (cmpCant != 0) return cmpCant;
        final cmpVentas = b.totalVentas.compareTo(a.totalVentas);
        if (cmpVentas != 0) return cmpVentas;
        return a.nombre.compareTo(b.nombre);
      });

    return _DatosRankingHistorico(
      items: items,
      totalJornadas: totalJornadas,
      totalPedidosCerrados: totalPedidosCerrados,
    );
  }

  String _sanitizarTextoEscPos(String input) {
    const reemplazos = <String, String>{
      'á': 'a',
      'é': 'e',
      'í': 'i',
      'ó': 'o',
      'ú': 'u',
      'Á': 'A',
      'É': 'E',
      'Í': 'I',
      'Ó': 'O',
      'Ú': 'U',
      'ñ': 'n',
      'Ñ': 'N',
      'ü': 'u',
      'Ü': 'U',
      '•': '-',
      '·': '-',
      '–': '-',
      '—': '-',
    };
    final sb = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      final rep = reemplazos[ch];
      if (rep != null) {
        sb.write(rep);
      } else if (rune >= 32 && rune <= 126 || rune == 10 || rune == 13) {
        sb.write(ch);
      } else {
        sb.write(' ');
      }
    }
    return sb.toString();
  }

  Future<String> _construirTextoTicketRanking(
    _DatosRankingHistorico datos, {
    int cols = 32,
  }) async {
    final nombreNegocio =
        await _leerConfig('nombre_negocio', fallback: 'POSify');
    final sep = '-' * cols;
    final b = StringBuffer();

    b.writeln(nombreNegocio.toUpperCase());
    b.writeln('RANKING DE PRODUCTOS');
    b.writeln('(MAS VENDIDOS A MENOS VENDIDOS)');
    b.writeln('Fecha: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}');
    b.writeln(
        'Historial: ${datos.totalJornadas} jornada(s) / ${datos.totalPedidosCerrados} ped.');
    b.writeln(sep);

    if (datos.items.isEmpty) {
      b.writeln('No hay productos registrados.');
    } else {
      for (int i = 0; i < datos.items.length; i++) {
        final item = datos.items[i];
        b.writeln('#${i + 1} ${item.nombre}');
        b.writeln(
            '   Cant: ${item.cantidadVendida} uds | ${formatMoney(item.totalVentas)}');
        if (item.gananciaTotal != null) {
          b.writeln('   Ganancia: ${formatMoney(item.gananciaTotal!)}');
        }
      }
    }

    b.writeln(sep);
    b.writeln('TOTAL UNIDADES: ${datos.totalUnidades}');
    b.writeln('TOTAL VENTAS: ${formatMoney(datos.totalVentas)}');
    if (datos.tieneCostos) {
      b.writeln('GANANCIA REAL: ${formatMoney(datos.totalGananciaReal)}');
    }
    if (datos.items.isNotEmpty) {
      final masVendido = datos.items.first;
      final menosVendido = datos.items.last;
      b.writeln(sep);
      b.writeln(
          'MAS VENDIDO: ${masVendido.nombre} (${masVendido.cantidadVendida})');
      b.writeln(
          'MENOS VENDIDO: ${menosVendido.nombre} (${menosVendido.cantidadVendida})');
    }

    return b.toString();
  }

  Future<void> _imprimirTicketRanking() async {
    if (_imprimiendoRanking) return;
    setState(() => _imprimiendoRanking = true);
    try {
      final datos = await _obtenerRankingHistorico();
      final colsCfg = int.tryParse(
              await _leerConfig('printer_paper_width', fallback: '32')) ??
          32;
      final texto = await _construirTextoTicketRanking(datos, cols: colsCfg);
      final textoLimpio = _sanitizarTextoEscPos(texto);

      final printerId = (await _leerConfig('printer_device_id')).trim();
      bool impresoEnTermica = false;

      if (printerId.isNotEmpty) {
        final device = await _printerService.connect(printerId);
        if (device != null) {
          final bytes = <int>[
            0x1B, 0x40, // ESC @ init
            0x1B, 0x61, 0x00, // align left
            ...latin1.encode('$textoLimpio\n\n\n\n'),
            0x1D, 0x56, 0x42, 0x00, // cut
          ];
          impresoEnTermica = await _printerService.printBytes(device, bytes);
        }
      }

      if (impresoEnTermica) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Ticket de ranking de productos impreso correctamente.'),
            backgroundColor: AppColors.success,
          ),
        );
        return;
      }

      if (!mounted) return;
      await Printing.layoutPdf(
        onLayout: (format) async {
          final doc = pw.Document();
          doc.addPage(
            pw.MultiPage(
              build: (context) => [
                pw.Text(
                  texto,
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
    } finally {
      if (mounted) {
        setState(() => _imprimiendoRanking = false);
      }
    }
  }

  Future<void> _descargarRankingCsv() async {
    final datos = await _obtenerRankingHistorico();
    final rows = <List<dynamic>>[
      [
        'Posicion',
        'Producto',
        'Categoria',
        'Unidades Vendidas',
        'Precio Unitario',
        'Total Ventas',
        'Costo Unitario',
        'Costo Total',
        'Ganancia Real',
      ],
      for (int i = 0; i < datos.items.length; i++)
        [
          i + 1,
          datos.items[i].nombre,
          datos.items[i].categoria,
          datos.items[i].cantidadVendida,
          datos.items[i].precioUnitario.toStringAsFixed(0),
          datos.items[i].totalVentas.toStringAsFixed(0),
          datos.items[i].costoUnitario?.toStringAsFixed(0) ?? '',
          datos.items[i].costoTotal?.toStringAsFixed(0) ?? '',
          datos.items[i].gananciaTotal?.toStringAsFixed(0) ?? '',
        ],
    ];

    final csvData = const ListToCsvConverter().convert(rows);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/ranking_productos_historico.csv');
    await file.writeAsString(csvData);

    if (!mounted) return;
    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'Ranking histórico de productos (más vendidos a menos vendidos)',
    );
  }

  Future<void> _descargarRankingTxt() async {
    final datos = await _obtenerRankingHistorico();
    final texto = await _construirTextoTicketRanking(datos, cols: 40);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/ranking_productos_historico.txt');
    await file.writeAsString(texto);

    if (!mounted) return;
    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'Informe TXT de productos más vendidos a menos vendidos',
    );
  }

  Future<void> _mostrarModalRanking() async {
    final datos = await _obtenerRankingHistorico();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.82,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollCtrl) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Ranking Histórico (+ vendidos a - vendidos)',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Acumulado de todas las jornadas (${datos.totalJornadas} jornada(s) · ${datos.totalPedidosCerrados} pedidos cerrados · ${datos.totalUnidades} uds)',
                style:
                    const TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      Navigator.pop(sheetCtx);
                      _imprimirTicketRanking();
                    },
                    icon: const Icon(Icons.print_outlined, size: 18),
                    label: const Text('Imprimir Ticket'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetCtx);
                      _descargarRankingCsv();
                    },
                    icon: const Icon(Icons.table_chart_outlined, size: 18),
                    label: const Text('Descargar CSV (Excel)'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetCtx);
                      _descargarRankingTxt();
                    },
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('Descargar TXT'),
                  ),
                ],
              ),
              const Divider(height: 20),
              Expanded(
                child: datos.items.isEmpty
                    ? const Center(child: Text('No hay productos registrados.'))
                    : ListView.separated(
                        controller: scrollCtrl,
                        itemCount: datos.items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (_, idx) {
                          final item = datos.items[idx];
                          final esTop = idx == 0 && item.cantidadVendida > 0;
                          final esCero = item.cantidadVendida == 0;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: esTop
                                  ? AppColors.success.withValues(alpha: 0.08)
                                  : AppColors.surface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: esTop
                                    ? AppColors.success.withValues(alpha: 0.35)
                                    : Colors.grey.shade200,
                              ),
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 15,
                                  backgroundColor: esCero
                                      ? Colors.grey.shade400
                                      : AppColors.primary,
                                  child: Text(
                                    '#${idx + 1}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.nombre,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13.5,
                                        ),
                                      ),
                                      Text(
                                        '${item.categoria} · Ventas: ${formatMoney(item.totalVentas)}',
                                        style: const TextStyle(
                                          fontSize: 11.5,
                                          color: AppColors.textMuted,
                                        ),
                                      ),
                                      if (item.gananciaTotal != null)
                                        Text(
                                          'Ganancia real: ${formatMoney(item.gananciaTotal!)}',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w700,
                                            color: item.gananciaTotal! >= 0
                                                ? AppColors.success
                                                : AppColors.error,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: esCero
                                        ? Colors.grey.shade200
                                        : AppColors.primary
                                            .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${item.cantidadVendida} uds',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12.5,
                                      color: esCero
                                          ? AppColors.textMuted
                                          : AppColors.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtrados = _productos.where((p) {
      if (_categoriaFiltroId != null && p.categoriaId != _categoriaFiltroId) {
        return false;
      }
      final q = _query.trim().toLowerCase();
      if (q.isEmpty) return true;
      final cat = _categorias
          .firstWhere(
            (c) => c.id == p.categoriaId,
            orElse: () => const Categoria(id: 0, nombre: '', orden: 0),
          )
          .nombre;
      final text = '${p.nombre} ${p.descripcion} $cat'.toLowerCase();
      return text.contains(q);
    }).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Productos',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            tooltip: 'Imprimir ticket de más a menos vendidos',
            onPressed: _imprimiendoRanking ? null : _imprimirTicketRanking,
            icon: const Icon(Icons.print_outlined, color: Colors.white),
          ),
          IconButton(
            tooltip: 'Descargar informe de más a menos vendidos',
            onPressed: _mostrarModalRanking,
            icon: const Icon(Icons.leaderboard_outlined, color: Colors.white),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _crearProducto,
        icon: const Icon(Icons.add),
        label: const Text('Nuevo producto'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          onPressed: _imprimiendoRanking
                              ? null
                              : _imprimirTicketRanking,
                          icon:
                              const Icon(Icons.receipt_long_outlined, size: 18),
                          label: Text(
                            _imprimiendoRanking
                                ? 'Imprimiendo...'
                                : 'Imprimir Ticket (+ a - vendidos)',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                        onPressed: _mostrarModalRanking,
                        icon: const Icon(Icons.download_outlined, size: 18),
                        label: const Text(
                          'Informe',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Buscar producto',
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                if (_categorias.isNotEmpty)
                  SizedBox(
                    height: 42,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text('Todas (${_productos.length})'),
                            selected: _categoriaFiltroId == null,
                            onSelected: (_) =>
                                setState(() => _categoriaFiltroId = null),
                          ),
                        ),
                        for (final c in _categorias)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(c.nombre),
                              selected: _categoriaFiltroId == c.id,
                              onSelected: (_) => setState(
                                () => _categoriaFiltroId =
                                    _categoriaFiltroId == c.id ? null : c.id,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: filtrados.isEmpty
                      ? const Center(child: Text('No hay productos.'))
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
                          itemCount: filtrados.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (_, i) {
                            final p = filtrados[i];
                            final cat = _categorias
                                .firstWhere(
                                  (c) => c.id == p.categoriaId,
                                  orElse: () => const Categoria(
                                    id: 0,
                                    nombre: 'Sin categoria',
                                    orden: 0,
                                  ),
                                )
                                .nombre;
                            final costo = _costosPorProducto[p.id];
                            final ganancia =
                                costo != null ? (p.precio - costo) : null;
                            final margenPct =
                                (ganancia != null && p.precio > 0)
                                    ? (ganancia / p.precio) * 100
                                    : null;

                            return Card(
                              child: ListTile(
                                title: Text(p.nombre),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('$cat · ${formatMoney(p.precio)}'),
                                    if (costo != null &&
                                        ganancia != null &&
                                        margenPct != null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          'Costo: ${formatMoney(costo)} · Ganancia: ${formatMoney(ganancia)} (${margenPct.toStringAsFixed(1)}%)',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: ganancia >= 0
                                                ? AppColors.success
                                                : AppColors.error,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                trailing: Wrap(
                                  spacing: 4,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined),
                                      onPressed: () => _editarProducto(p),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline,
                                          color: AppColors.error),
                                      onPressed: () => _eliminarProducto(p),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _ItemRankingProducto {
  final String nombre;
  final String categoria;
  final int cantidadVendida;
  final double totalVentas;
  final double precioUnitario;
  final double? costoUnitario;

  const _ItemRankingProducto({
    required this.nombre,
    required this.categoria,
    required this.cantidadVendida,
    required this.totalVentas,
    required this.precioUnitario,
    this.costoUnitario,
  });

  double? get costoTotal =>
      costoUnitario != null ? costoUnitario! * cantidadVendida : null;

  double? get gananciaTotal =>
      costoTotal != null ? totalVentas - costoTotal! : null;
}

class _DatosRankingHistorico {
  final List<_ItemRankingProducto> items;
  final int totalJornadas;
  final int totalPedidosCerrados;

  const _DatosRankingHistorico({
    required this.items,
    required this.totalJornadas,
    required this.totalPedidosCerrados,
  });

  int get totalUnidades =>
      items.fold<int>(0, (sum, item) => sum + item.cantidadVendida);

  double get totalVentas =>
      items.fold<double>(0, (sum, item) => sum + item.totalVentas);

  bool get tieneCostos => items.any((item) => item.costoUnitario != null);

  double get totalGananciaReal => items.fold<double>(
        0,
        (sum, item) => sum + (item.gananciaTotal ?? 0),
      );
}
