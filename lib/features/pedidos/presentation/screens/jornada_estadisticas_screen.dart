import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/utils/money_formatter.dart';
import '../../../../database/app_database.dart';
import '../../../../injection_container.dart';

class JornadaEstadisticasScreen extends StatefulWidget {
  final String titulo;
  final List<int>? initialJornadaIds;
  final String initialRango; // 'filtradas' | 'semana' | 'mes' | '3_meses' | 'todo'
  final int? initialDiaSemana; // 1..7 (DateTime.monday..sunday) o null = todos

  const JornadaEstadisticasScreen({
    super.key,
    required this.titulo,
    this.initialJornadaIds,
    this.initialRango = '3_meses',
    this.initialDiaSemana,
  });

  @override
  State<JornadaEstadisticasScreen> createState() =>
      _JornadaEstadisticasScreenState();
}

class _JornadaEstadisticasScreenState extends State<JornadaEstadisticasScreen> {
  final AppDatabase _db = sl<AppDatabase>();

  bool _loading = true;
  late String _rango;
  int? _diaSemana;
  String _modoCobertura = 'seguro_10'; // exacto | seguro_10 | seguro_20 | maximo

  int _jornadasAnalizadas = 0;
  int _pedidosCerrados = 0;
  double _totalVentasProductos = 0;
  double _totalDomicilios = 0;
  double _totalVentasConCosto = 0;
  double _totalCostoConfigurado = 0;
  int _productosConCosto = 0;
  int _productosTotales = 0;
  List<_ProductoEstadistica> _productos = const [];

  static const _diasSemana = <(int?, String)>[
    (null, 'Todos'),
    (DateTime.monday, 'Lun'),
    (DateTime.tuesday, 'Mar'),
    (DateTime.wednesday, 'Mié'),
    (DateTime.thursday, 'Jue'),
    (DateTime.friday, 'Vie'),
    (DateTime.saturday, 'Sáb'),
    (DateTime.sunday, 'Dom'),
  ];

  @override
  void initState() {
    super.initState();
    _rango = widget.initialRango;
    _diaSemana = widget.initialDiaSemana;
    _cargar();
  }

  DateTime? _parseDbDate(String value) {
    if (value.trim().isEmpty) return null;
    return DateTime.tryParse(value.replaceFirst(' ', 'T'));
  }

  String _nombreDia(int? weekday) {
    return switch (weekday) {
      DateTime.monday => 'Lunes',
      DateTime.tuesday => 'Martes',
      DateTime.wednesday => 'Miércoles',
      DateTime.thursday => 'Jueves',
      DateTime.friday => 'Viernes',
      DateTime.saturday => 'Sábado',
      DateTime.sunday => 'Domingo',
      _ => 'Todos los días',
    };
  }

  String _nombreRango(String rango) {
    return switch (rango) {
      'filtradas' => 'Jornadas filtradas',
      'semana' => 'Última semana (7 días)',
      'mes' => 'Último mes (30 días)',
      '3_meses' => 'Últimos 3 meses (90 días)',
      _ => 'Todo el historial',
    };
  }

  int _calcularSugerido(_ProductoEstadistica item) {
    switch (_modoCobertura) {
      case 'exacto':
        return item.promedioPorJornada.ceil();
      case 'seguro_20':
        return (item.promedioPorJornada * 1.20).ceil();
      case 'maximo':
        return item.maxPorJornada;
      case 'seguro_10':
      default:
        return (item.promedioPorJornada * 1.10).ceil();
    }
  }

  Future<void> _cargar() async {
    setState(() => _loading = true);

    final jornadasRows = await _db.customSelect(
      '''
      SELECT id, nombre, estado, abierta_en, cerrada_en
      FROM jornadas
      WHERE estado = 'cerrada' OR id IN (SELECT DISTINCT jornada_id FROM pedidos WHERE estado = 'cerrado')
      ORDER BY id DESC
      ''',
    ).get();

    final now = DateTime.now();
    final hoyInicio = DateTime(now.year, now.month, now.day);
    final limiteInicio = switch (_rango) {
      'semana' => hoyInicio.subtract(const Duration(days: 6)),
      'mes' => hoyInicio.subtract(const Duration(days: 29)),
      '3_meses' => hoyInicio.subtract(const Duration(days: 89)),
      _ => null,
    };

    final filtradasIdsSet = widget.initialJornadaIds?.toSet();

    final jornadasMatch = <int>[];
    for (final row in jornadasRows) {
      final id = row.data['id'] as int?;
      if (id == null) continue;

      final fecha = _parseDbDate((row.data['cerrada_en'] as String?) ?? '') ??
          _parseDbDate((row.data['abierta_en'] as String?) ?? '');
      if (fecha == null) continue;

      if (_rango == 'filtradas' && filtradasIdsSet != null) {
        if (!filtradasIdsSet.contains(id)) continue;
      } else if (limiteInicio != null) {
        if (fecha.isBefore(limiteInicio)) continue;
      }

      if (_diaSemana != null && fecha.weekday != _diaSemana) {
        continue;
      }

      jornadasMatch.add(id);
    }

    if (jornadasMatch.isEmpty) {
      if (!mounted) return;
      setState(() {
        _jornadasAnalizadas = 0;
        _pedidosCerrados = 0;
        _totalVentasProductos = 0;
        _totalDomicilios = 0;
        _totalVentasConCosto = 0;
        _totalCostoConfigurado = 0;
        _productosConCosto = 0;
        _productosTotales = 0;
        _productos = const [];
        _loading = false;
      });
      return;
    }

    final idsSql = jornadasMatch.join(',');

    final resumenPedidosRow = await _db.customSelect(
      '''
      SELECT COALESCE(COUNT(*), 0) AS pedidos_cerrados,
             COALESCE(SUM(CASE WHEN tipo = 'domicilio' THEN valor_domicilio ELSE 0 END), 0) AS total_domicilios
      FROM pedidos
      WHERE jornada_id IN ($idsSql) AND estado = 'cerrado'
      ''',
    ).getSingle();

    final itemsPorJornadaRows = await _db.customSelect(
      '''
      SELECT p.jornada_id AS jornada_id,
             i.producto_id AS producto_id,
             i.nombre_producto AS nombre_producto,
             COALESCE(SUM(i.cantidad), 0) AS cantidad,
             COALESCE(SUM(i.precio * i.cantidad), 0) AS venta,
             MAX(prod.costo) AS costo_unitario
      FROM items_pedido i
      JOIN pedidos p ON p.id = i.pedido_id
      LEFT JOIN productos prod ON prod.id = i.producto_id
      WHERE p.jornada_id IN ($idsSql) AND p.estado = 'cerrado'
      GROUP BY p.jornada_id, i.producto_id, i.nombre_producto
      ''',
    ).get();

    final mapa = <String, _AcumuladoProducto>{};
    for (final row in itemsPorJornadaRows) {
      final jornadaId = (row.data['jornada_id'] as int?) ?? 0;
      final nombre = ((row.data['nombre_producto'] as String?) ?? 'Producto').trim();
      final cantidad = (row.data['cantidad'] as num?)?.toInt() ?? 0;
      final venta = (row.data['venta'] as num?)?.toDouble() ?? 0;
      final costoUnit = (row.data['costo_unitario'] as num?)?.toDouble();

      final key = nombre.toLowerCase();
      final acc = mapa.putIfAbsent(
        key,
        () => _AcumuladoProducto(nombre: nombre, costoUnitario: costoUnit),
      );
      if (acc.costoUnitario == null && costoUnit != null) {
        acc.costoUnitario = costoUnit;
      }
      acc.cantidadPorJornada[jornadaId] =
          (acc.cantidadPorJornada[jornadaId] ?? 0) + cantidad;
      acc.totalCantidad += cantidad;
      acc.totalVentas += venta;
    }

    final totalJornadas = jornadasMatch.length;
    final lista = <_ProductoEstadistica>[];
    double sumVentas = 0;
    double sumVentasConCosto = 0;
    double sumCosto = 0;
    int conCosto = 0;

    for (final acc in mapa.values) {
      int minCant = 1 << 30;
      int maxCant = 0;
      for (final jId in jornadasMatch) {
        final c = acc.cantidadPorJornada[jId] ?? 0;
        if (c < minCant) minCant = c;
        if (c > maxCant) maxCant = c;
      }
      if (minCant == (1 << 30)) minCant = 0;

      final promedio = acc.totalCantidad / totalJornadas;
      final costoTotal = acc.costoUnitario != null
          ? acc.costoUnitario! * acc.totalCantidad
          : null;
      final gananciaReal =
          costoTotal != null ? acc.totalVentas - costoTotal : null;

      sumVentas += acc.totalVentas;
      if (costoTotal != null) {
        conCosto++;
        sumVentasConCosto += acc.totalVentas;
        sumCosto += costoTotal;
      }

      lista.add(
        _ProductoEstadistica(
          nombre: acc.nombre,
          totalCantidad: acc.totalCantidad,
          totalVentas: acc.totalVentas,
          promedioPorJornada: promedio,
          minPorJornada: minCant,
          maxPorJornada: maxCant,
          costoUnitario: acc.costoUnitario,
          costoTotal: costoTotal,
          gananciaReal: gananciaReal,
        ),
      );
    }

    lista.sort((a, b) => b.totalCantidad.compareTo(a.totalCantidad));

    if (!mounted) return;
    setState(() {
      _jornadasAnalizadas = totalJornadas;
      _pedidosCerrados =
          (resumenPedidosRow.data['pedidos_cerrados'] as int?) ?? 0;
      _totalDomicilios =
          (resumenPedidosRow.data['total_domicilios'] as num?)?.toDouble() ?? 0;
      _totalVentasProductos = sumVentas;
      _totalVentasConCosto = sumVentasConCosto;
      _totalCostoConfigurado = sumCosto;
      _productosConCosto = conCosto;
      _productosTotales = lista.length;
      _productos = lista;
      _loading = false;
    });
  }

  Future<void> _compartirInforme() async {
    final buffer = StringBuffer();
    buffer.writeln('ESTADISTICAS, ROTACION Y GANANCIA');
    buffer.writeln('Alcance: ${widget.titulo}');
    buffer.writeln('Periodo: ${_nombreRango(_rango)}');
    buffer.writeln('Dia objetivo: ${_nombreDia(_diaSemana)}');
    buffer.writeln(
        'Fecha reporte: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}');
    buffer.writeln('----------------------------------------');
    buffer.writeln('Jornadas analizadas: $_jornadasAnalizadas');
    buffer.writeln('Pedidos cerrados: $_pedidosCerrados');
    buffer.writeln('Ventas productos: ${formatMoney(_totalVentasProductos)}');
    buffer.writeln('Domicilios: ${formatMoney(_totalDomicilios)}');
    buffer.writeln(
        'Total ventas: ${formatMoney(_totalVentasProductos + _totalDomicilios)}');
    if (_productosConCosto > 0) {
      final ganancia = _totalVentasConCosto - _totalCostoConfigurado;
      final margen = _totalVentasConCosto > 0
          ? (ganancia / _totalVentasConCosto) * 100
          : 0.0;
      buffer.writeln('Costo productos (config.): ${formatMoney(_totalCostoConfigurado)}');
      buffer.writeln(
          'GANANCIA REAL: ${formatMoney(ganancia)} (${margen.toStringAsFixed(1)}%)');
    }
    buffer.writeln('----------------------------------------');
    buffer.writeln('ROTACION Y CUBRIMIENTO SUGERIDO:');
    for (final p in _productos) {
      final sugerido = _calcularSugerido(p);
      buffer.writeln(
          '- ${p.nombre}: Preparar $sugerido uds | Prom ${p.promedioPorJornada.toStringAsFixed(1)}/jornada (Min ${p.minPorJornada} - Max ${p.maxPorJornada}) | Total ${p.totalCantidad} uds (${formatMoney(p.totalVentas)})');
      if (p.gananciaReal != null && p.costoTotal != null) {
        buffer.writeln(
            '  Costo: ${formatMoney(p.costoTotal!)} | Ganancia real: ${formatMoney(p.gananciaReal!)}');
      }
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/estadisticas_rotacion_posify.txt');
    await file.writeAsString(buffer.toString());

    if (!mounted) return;
    await Share.shareXFiles(
      [XFile(file.path)],
      text: 'Estadísticas y predicción de rotación - ${widget.titulo}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final gananciaReal = _totalVentasConCosto - _totalCostoConfigurado;
    final margenRealPct = _totalVentasConCosto > 0
        ? (gananciaReal / _totalVentasConCosto) * 100
        : 0.0;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Rotación, Predicción y Ganancia',
          style: TextStyle(color: Colors.white, fontSize: 17),
        ),
        actions: [
          IconButton(
            tooltip: 'Compartir informe',
            icon: const Icon(Icons.share_outlined),
            onPressed: _loading || _productos.isEmpty ? null : _compartirInforme,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.titulo,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      if (widget.initialJornadaIds != null)
                        _FiltroChip(
                          label: 'Filtradas',
                          selected: _rango == 'filtradas',
                          onTap: () {
                            setState(() => _rango = 'filtradas');
                            _cargar();
                          },
                        ),
                      _FiltroChip(
                        label: 'Semana',
                        selected: _rango == 'semana',
                        onTap: () {
                          setState(() => _rango = 'semana');
                          _cargar();
                        },
                      ),
                      _FiltroChip(
                        label: 'Mes',
                        selected: _rango == 'mes',
                        onTap: () {
                          setState(() => _rango = 'mes');
                          _cargar();
                        },
                      ),
                      _FiltroChip(
                        label: '3 Meses',
                        selected: _rango == '3_meses',
                        onTap: () {
                          setState(() => _rango = '3_meses');
                          _cargar();
                        },
                      ),
                      _FiltroChip(
                        label: 'Todo',
                        selected: _rango == 'todo',
                        onTap: () {
                          setState(() => _rango = 'todo');
                          _cargar();
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Día específico (para predecir ese día):',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _diasSemana
                        .map(
                          (d) => _FiltroChip(
                            label: d.$2,
                            selected: _diaSemana == d.$1,
                            onTap: () {
                              setState(() => _diaSemana = d.$1);
                              _cargar();
                            },
                          ),
                        )
                        .toList(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text(
                      'Cubrimiento:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _modoCobertura,
                        isDense: true,
                        decoration: const InputDecoration(
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'exacto',
                            child: Text('Promedio exacto',
                                style: TextStyle(fontSize: 12.5)),
                          ),
                          DropdownMenuItem(
                            value: 'seguro_10',
                            child: Text('Promedio + 10% respaldo',
                                style: TextStyle(fontSize: 12.5)),
                          ),
                          DropdownMenuItem(
                            value: 'seguro_20',
                            child: Text('Promedio + 20% respaldo',
                                style: TextStyle(fontSize: 12.5)),
                          ),
                          DropdownMenuItem(
                            value: 'maximo',
                            child: Text('Cubrir pico máximo histórico',
                                style: TextStyle(fontSize: 12.5)),
                          ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _modoCobertura = v);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.accent),
                  )
                : _jornadasAnalizadas == 0 || _productos.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'No hay ventas registradas para "${_nombreRango(_rango)}" (${_nombreDia(_diaSemana)}).',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: AppColors.textMuted),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.all(14),
                        children: [
                          Card(
                            color: Colors.white,
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Resumen (${_nombreDia(_diaSemana)} · $_jornadasAnalizadas jornada(s))',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _StatPill(
                                        label: 'Ventas productos',
                                        value:
                                            formatMoney(_totalVentasProductos),
                                        color: AppColors.primary,
                                      ),
                                      _StatPill(
                                        label: 'Promedio / jornada',
                                        value: formatMoney(
                                            _totalVentasProductos /
                                                _jornadasAnalizadas),
                                        color: AppColors.textPrimary,
                                      ),
                                      _StatPill(
                                        label: 'Pedidos',
                                        value: '$_pedidosCerrados',
                                        color: AppColors.accent,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: _productosConCosto > 0
                                          ? AppColors.success
                                              .withValues(alpha: 0.08)
                                          : Colors.grey.shade100,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: _productosConCosto > 0
                                            ? AppColors.success
                                                .withValues(alpha: 0.3)
                                            : Colors.grey.shade300,
                                      ),
                                    ),
                                    child: _productosConCosto == 0
                                        ? const Text(
                                            'Ganancia real: configura el costo opcional en Productos para calcular costos y ganancia real.',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: AppColors.textMuted,
                                            ),
                                          )
                                        : Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'Ganancia real: ${formatMoney(gananciaReal)} (${margenRealPct.toStringAsFixed(1)}%)',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 14.5,
                                                  color: gananciaReal >= 0
                                                      ? AppColors.success
                                                      : AppColors.error,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                'Costo total: ${formatMoney(_totalCostoConfigurado)} · Base con costo: $_productosConCosto de $_productosTotales productos',
                                                style: const TextStyle(
                                                  fontSize: 11.5,
                                                  color: AppColors.textMuted,
                                                ),
                                              ),
                                            ],
                                          ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Rotación y predicción por producto',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 6),
                          for (final p in _productos) ...[
                            _ProductoRotacionCard(
                              item: p,
                              sugerido: _calcularSugerido(p),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

class _FiltroChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FiltroChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatPill({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductoRotacionCard extends StatelessWidget {
  final _ProductoEstadistica item;
  final int sugerido;

  const _ProductoRotacionCard({
    required this.item,
    required this.sugerido,
  });

  @override
  Widget build(BuildContext context) {
    final margen = (item.gananciaReal != null && item.totalVentas > 0)
        ? (item.gananciaReal! / item.totalVentas) * 100
        : null;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.nombre,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Preparar: $sugerido uds',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Total vendido: ${item.totalCantidad} uds · Promedio: ${item.promedioPorJornada.toStringAsFixed(1)}/jornada · Rango: ${item.minPorJornada}–${item.maxPorJornada} uds',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
            const SizedBox(height: 4),
            Text(
              'Ventas: ${formatMoney(item.totalVentas)}',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (item.costoTotal != null &&
                item.gananciaReal != null &&
                margen != null) ...[
              const SizedBox(height: 2),
              Text(
                'Costo: ${formatMoney(item.costoTotal!)} · Ganancia real: ${formatMoney(item.gananciaReal!)} (${margen.toStringAsFixed(1)}%)',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: item.gananciaReal! >= 0
                      ? AppColors.success
                      : AppColors.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AcumuladoProducto {
  final String nombre;
  double? costoUnitario;
  int totalCantidad = 0;
  double totalVentas = 0;
  final Map<int, int> cantidadPorJornada = {};

  _AcumuladoProducto({
    required this.nombre,
    this.costoUnitario,
  });
}

class _ProductoEstadistica {
  final String nombre;
  final int totalCantidad;
  final double totalVentas;
  final double promedioPorJornada;
  final int minPorJornada;
  final int maxPorJornada;
  final double? costoUnitario;
  final double? costoTotal;
  final double? gananciaReal;

  const _ProductoEstadistica({
    required this.nombre,
    required this.totalCantidad,
    required this.totalVentas,
    required this.promedioPorJornada,
    required this.minPorJornada,
    required this.maxPorJornada,
    this.costoUnitario,
    this.costoTotal,
    this.gananciaReal,
  });
}
