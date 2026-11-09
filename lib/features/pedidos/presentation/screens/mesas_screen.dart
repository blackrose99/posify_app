import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show OrderingTerm, Variable;
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/money_formatter.dart';
import '../../../../database/app_database.dart';
import '../../../../injection_container.dart';
import '../../../impresion/bluetooth_printer_service.dart';
import '../../../impresion/ticket_builder.dart';
import '../../../impresion/ticket_data.dart';
import '../../domain/entities/item_pedido.dart';
import '../../../../core/services/medios_pago_service.dart';
import '../widgets/dialogo_cobrar_pedido.dart';
import 'admin_config_screen.dart';
import 'jornada_historial_screen.dart';
import 'pedido_screen.dart';
import 'ticket_preview_screen.dart';

String _formatMoney(num value) => formatMoney(value);

class MesasScreen extends ConsumerStatefulWidget {
  const MesasScreen({super.key});

  @override
  ConsumerState<MesasScreen> createState() => _MesasScreenState();
}

class _MesasScreenState extends ConsumerState<MesasScreen> {
  final AppDatabase _db = sl<AppDatabase>();
  static bool _estructuraAsegurada = false;

  bool _loading = true;
  String _vistaJornadas = 'abiertas';
  String _filtroPedidos = 'abierto';
  List<_JornadaResumen> _jornadas = const [];
  _JornadaResumen? _jornadaSeleccionada;
  List<_PedidoResumen> _pedidos = const [];
  Map<String, int> _conteoPorEstado = const {
    'abierto': 0,
    'cerrado': 0,
    'cancelado': 0,
  };
  DateTime? _fechaCalendarioCerradas;
  String _rangoCerradas = 'todo'; // todo | hoy | semana | mes

  String _nowLocalSql() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  int _nowEpochMs() => DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    setState(() => _loading = true);

    if (!_estructuraAsegurada) {
      await _asegurarEstructuraJornadas();
      _estructuraAsegurada = true;
    }

    final jornadasRows = await _db.customSelect(
      '''
      SELECT id, nombre, estado, abierta_en, cerrada_en
      FROM jornadas
      WHERE estado = ?
      ORDER BY id DESC
      ''',
      variables: [
        Variable<String>(_vistaJornadas == 'abiertas' ? 'abierta' : 'cerrada')
      ],
    ).get();

    final jornadas = jornadasRows.map((row) {
      final data = row.data;
      return _JornadaResumen(
        id: data['id'] as int,
        nombre: (data['nombre'] as String?) ?? 'Jornada',
        estado: (data['estado'] as String?) ?? 'cerrada',
        abiertaEn: (data['abierta_en'] as String?) ?? '',
        cerradaEn: (data['cerrada_en'] as String?) ?? '',
      );
    }).toList();

    final ventasRows = await _db.customSelect(
      '''
      SELECT p.jornada_id AS jornada_id,
             COALESCE(SUM(
               CASE WHEN p.estado = 'cerrado' THEN (
                 COALESCE((
                   SELECT SUM(i.precio * i.cantidad)
                   FROM items_pedido i
                   WHERE i.pedido_id = p.id
                 ), 0)
               ) ELSE 0 END
             ), 0) AS total_productos,
             COALESCE(SUM(
               CASE WHEN p.estado = 'cerrado' AND p.tipo = 'domicilio' THEN p.valor_domicilio
                    ELSE 0 END
             ), 0) AS total_domicilios,
             COALESCE(COUNT(CASE WHEN p.estado = 'cancelado' THEN 1 END), 0) AS total_cancelados,
             COALESCE(SUM(
               CASE WHEN p.estado = 'cancelado' THEN (
                 COALESCE((
                   SELECT SUM(i.precio * i.cantidad)
                   FROM items_pedido i
                   WHERE i.pedido_id = p.id
                 ), 0) + p.valor_domicilio
               ) ELSE 0 END
             ), 0) AS total_cancelados_monto
      FROM pedidos p
      WHERE p.jornada_id IS NOT NULL
      GROUP BY p.jornada_id
      ''',
    ).get();

    final totalPorJornada = <int, double>{};
    final totalDomicilioPorJornada = <int, double>{};
    final canceladosPorJornada = <int, int>{};
    final canceladosMontoPorJornada = <int, double>{};
    for (final row in ventasRows) {
      final jornadaId = (row.data['jornada_id'] as int?) ?? 0;
      if (jornadaId <= 0) continue;
      totalPorJornada[jornadaId] =
          (row.data['total_productos'] as num?)?.toDouble() ?? 0;
      totalDomicilioPorJornada[jornadaId] =
          (row.data['total_domicilios'] as num?)?.toDouble() ?? 0;
      canceladosPorJornada[jornadaId] =
          (row.data['total_cancelados'] as int?) ?? 0;
      canceladosMontoPorJornada[jornadaId] =
          (row.data['total_cancelados_monto'] as num?)?.toDouble() ?? 0;
    }

    final jornadasConTotal = jornadas
        .map(
          (j) => j.copyWith(
            totalProductos: totalPorJornada[j.id] ?? 0,
            totalDomicilios: totalDomicilioPorJornada[j.id] ?? 0,
            totalCancelados: canceladosPorJornada[j.id] ?? 0,
            totalCanceladosMonto: canceladosMontoPorJornada[j.id] ?? 0,
          ),
        )
        .toList();

    _JornadaResumen? jornadaSeleccionada = _jornadaSeleccionada;
    if (jornadaSeleccionada != null) {
      jornadaSeleccionada =
          jornadasConTotal.cast<_JornadaResumen?>().firstWhere(
                (j) => j?.id == jornadaSeleccionada!.id,
                orElse: () =>
                    jornadasConTotal.isNotEmpty ? jornadasConTotal.first : null,
              );
    } else if (jornadasConTotal.isNotEmpty) {
      jornadaSeleccionada = jornadasConTotal.first;
    }

    final conteoEstados = <String, int>{
      'abierto': 0,
      'cerrado': 0,
      'cancelado': 0,
    };
    if (jornadaSeleccionada != null) {
      final conteoRows = await _db.customSelect(
        '''
        SELECT estado, COUNT(*) AS cnt
        FROM pedidos
        WHERE jornada_id = ?
        GROUP BY estado
        ''',
        variables: [Variable<int>(jornadaSeleccionada.id)],
      ).get();
      for (final r in conteoRows) {
        final est = (r.data['estado'] as String?) ?? '';
        final cnt = (r.data['cnt'] as int?) ?? 0;
        if (conteoEstados.containsKey(est)) {
          conteoEstados[est] = cnt;
        }
      }
    }

    final pedidos = jornadaSeleccionada == null
        ? <_PedidoResumen>[]
        : await _obtenerPedidosJornada(
            jornadaId: jornadaSeleccionada.id,
            estado: _filtroPedidos,
          );

    if (!mounted) return;

    setState(() {
      _jornadas = jornadasConTotal;
      _jornadaSeleccionada = jornadaSeleccionada;
      _pedidos = pedidos;
      _conteoPorEstado = conteoEstados;
      _loading = false;
    });
  }

  Future<void> _asegurarEstructuraJornadas() async {
    await _db.customStatement('''
      CREATE TABLE IF NOT EXISTS jornadas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nombre TEXT NOT NULL,
        estado TEXT NOT NULL DEFAULT 'abierta',
        abierta_en TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        cerrada_en TEXT
      )
    ''');

    await _ejecutarSeguro(
      "ALTER TABLE pedidos ADD COLUMN jornada_id INTEGER",
    );
    await _ejecutarSeguro(
      "ALTER TABLE pedidos ADD COLUMN referencia TEXT",
    );
    await _ejecutarSeguro(
      "ALTER TABLE pedidos ADD COLUMN cliente TEXT",
    );
    await _ejecutarSeguro(
      "ALTER TABLE pedidos ADD COLUMN mesero TEXT",
    );
    await _ejecutarSeguro(
      "ALTER TABLE pedidos ADD COLUMN numero_turno INTEGER",
    );
    await _ejecutarSeguro(
      "ALTER TABLE pedidos ADD COLUMN impreso_cliente INTEGER NOT NULL DEFAULT 0",
    );
    await _ejecutarSeguro(
      "ALTER TABLE pedidos ADD COLUMN impreso_cocina INTEGER NOT NULL DEFAULT 0",
    );
    await _ejecutarSeguro(
      "ALTER TABLE pedidos ADD COLUMN medio_pago TEXT NOT NULL DEFAULT ''",
    );

    await _asegurarClaveConfig('valor_domicilio', '5000');
    await _asegurarClaveConfig('printer_device_id', '');
    await _asegurarClaveConfig('printer_device_name', '');
    await _asegurarClaveConfig('printer_paper_width', '32');

    // Convierte fechas legacy en texto a epoch ms para columnas DateTime de Drift.
    await _db.customStatement('''
      UPDATE pedidos
      SET creado_en = CAST(strftime('%s', creado_en) AS INTEGER) * 1000
      WHERE creado_en IS NOT NULL
        AND typeof(creado_en) = 'text'
        AND TRIM(creado_en) != ''
    ''');

    await _db.customStatement('''
      UPDATE pedidos
      SET cerrado_en = CAST(strftime('%s', cerrado_en) AS INTEGER) * 1000
      WHERE cerrado_en IS NOT NULL
        AND typeof(cerrado_en) = 'text'
        AND TRIM(cerrado_en) != ''
    ''');
  }

  Future<void> _asegurarClaveConfig(
      String clave, String valorPorDefecto) async {
    final row = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals(clave)))
        .getSingleOrNull();
    if (row != null) return;

    await _db.into(_db.configuracion).insert(
          ConfiguracionCompanion.insert(clave: clave, valor: valorPorDefecto),
        );
  }

  Future<String> _leerConfig(String clave, {String fallback = ''}) async {
    final row = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals(clave)))
        .getSingleOrNull();
    return row?.valor ?? fallback;
  }

  Future<List<String>> _meserosConfigurados() async {
    final meseros = await (_db.select(_db.meseros)
          ..orderBy([(m) => OrderingTerm(expression: m.nombre)]))
        .get();
    return meseros
        .map((m) => m.nombre.trim())
        .where((m) => m.isNotEmpty)
        .toList();
  }

  Future<void> _ejecutarSeguro(String sql) async {
    try {
      await _db.customStatement(sql);
    } catch (_) {
      // Ignora columnas ya existentes.
    }
  }

  Future<List<_PedidoResumen>> _obtenerPedidosJornada({
    required int jornadaId,
    required String estado,
  }) async {
    final rows = await _db.customSelect(
      '''
      SELECT id, tipo, estado, referencia, cliente, mesero, valor_domicilio,
             COALESCE(numero_turno, 0) AS numero_turno,
             COALESCE(impreso_cliente, 0) AS impreso_cliente,
             COALESCE(impreso_cocina, 0) AS impreso_cocina,
             COALESCE(medio_pago, '') AS medio_pago
      FROM pedidos
      WHERE jornada_id = ? AND estado = ?
      ORDER BY id DESC
      ''',
      variables: [Variable<int>(jornadaId), Variable<String>(estado)],
    ).get();

    if (rows.isEmpty) return <_PedidoResumen>[];

    // Consulta por lote para optimizar consultas y evitar decenas de selects individuales
    final pedidoIds = rows.map((r) => r.data['id'] as int).toList();
    final placeholders = List.filled(pedidoIds.length, '?').join(',');
    final itemsRows = await _db.customSelect(
      '''
      SELECT pedido_id, nombre_producto, cantidad, precio
      FROM items_pedido
      WHERE pedido_id IN ($placeholders)
      ORDER BY id ASC
      ''',
      variables: pedidoIds.map((id) => Variable<int>(id)).toList(),
    ).get();

    final itemsPorPedido = <int, List<Map<String, dynamic>>>{};
    for (final ir in itemsRows) {
      final pid = ir.data['pedido_id'] as int;
      itemsPorPedido.putIfAbsent(pid, () => []).add(ir.data);
    }

    final pedidos = <_PedidoResumen>[];
    for (final row in rows) {
      final data = row.data;
      final pedidoId = data['id'] as int;
      final items = itemsPorPedido[pedidoId] ?? const [];

      int itemsCount = 0;
      double subtotal = 0;
      final resumenItems = <String>[];
      for (final itm in items) {
        final cant = (itm['cantidad'] as int?) ?? 1;
        final prec = (itm['precio'] as num?)?.toDouble() ?? 0;
        final nom = (itm['nombre_producto'] as String?) ?? '';
        itemsCount += cant;
        subtotal += prec * cant;
        resumenItems.add('${cant}x $nom');
      }

      pedidos.add(_PedidoResumen(
        id: pedidoId,
        tipo: (data['tipo'] as String?) ?? 'mesa',
        estado: (data['estado'] as String?) ?? 'abierto',
        referencia: ((data['referencia'] as String?) ?? '').trim(),
        cliente: ((data['cliente'] as String?) ?? '').trim(),
        mesero: ((data['mesero'] as String?) ?? '').trim(),
        itemsCount: itemsCount,
        subtotal: subtotal,
        valorDomicilio: (data['valor_domicilio'] as num?)?.toDouble() ?? 0,
        numeroTurno: (data['numero_turno'] as int?) ?? 0,
        impresoCliente: ((data['impreso_cliente'] as int?) ?? 0) == 1,
        impresoCocina: ((data['impreso_cocina'] as int?) ?? 0) == 1,
        medioPago: ((data['medio_pago'] as String?) ?? '').trim(),
        resumenItems: resumenItems,
      ));
    }
    return pedidos;
  }

  Future<void> _abrirPantallaProductos(_PedidoResumen pedido) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PedidoScreen(
          pedidoId: pedido.id,
          titulo: pedido.referencia.isNotEmpty
              ? pedido.referencia
              : 'Pedido ${pedido.id}',
          esDomicilio: pedido.tipo == 'domicilio',
        ),
      ),
    );
    await _cargarDatos();
  }

  Future<void> _mostrarAlertaSinProductosCocina({_PedidoResumen? pedido}) async {
    if (!mounted) return;
    final irAAgregar = await showDialog<bool>(
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
                'Orden de cocina sin productos',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: const Text(
          'No hay productos registrados en esta orden de cocina. '
          'Por favor, añade al menos un producto al pedido antes de ver o enviar la comanda a cocina.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Entendido'),
          ),
          if (pedido != null && pedido.estado == 'abierto')
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.agregarProductos,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
              label: const Text('Añadir productos'),
            ),
        ],
      ),
    );

    if (irAAgregar == true && pedido != null) {
      await _abrirPantallaProductos(pedido);
    }
  }

  Future<void> _crearJornada() async {
    final abierta = await _db
        .customSelect(
          "SELECT id FROM jornadas WHERE estado = 'abierta' LIMIT 1",
        )
        .getSingleOrNull();

    if (!mounted) return;

    if (abierta != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Ya existe una jornada abierta. Debes cerrarla primero.'),
        ),
      );
      return;
    }

    final nombreController = TextEditingController(
      text: 'Jornada ${DateTime.now().day}/${DateTime.now().month}',
    );

    final nombre = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nueva jornada'),
        content: TextField(
          controller: nombreController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nombre de jornada',
            hintText: 'Jornada mañana',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          ElevatedButton.icon(
            onPressed: () =>
                Navigator.pop(dialogContext, nombreController.text),
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Crear'),
          ),
        ],
      ),
    );

    if (nombre == null) return;

    await _db.customStatement(
      "INSERT INTO jornadas (nombre, estado, abierta_en) VALUES (?, 'abierta', ?)",
      [
        nombre.trim().isEmpty ? 'Jornada abierta' : nombre.trim(),
        _nowLocalSql()
      ],
    );

    _vistaJornadas = 'abiertas';
    await _cargarDatos();
  }

  Future<void> _cerrarJornada(_JornadaResumen jornada) async {
    final abiertos = await _db.customSelect(
      '''
      SELECT p.id AS id,
             COALESCE(SUM(i.precio * i.cantidad), 0) +
             CASE WHEN p.tipo = 'domicilio' THEN COALESCE(p.valor_domicilio, 0)
                  ELSE 0 END AS total
      FROM pedidos p
      LEFT JOIN items_pedido i ON i.pedido_id = p.id
      WHERE p.jornada_id = ? AND p.estado = 'abierto'
      GROUP BY p.id, p.tipo, p.valor_domicilio
      ''',
      variables: [Variable<int>(jornada.id)],
    ).get();

    final abiertosConTotal = abiertos.where((row) {
      final total = (row.data['total'] as num?)?.toDouble() ?? 0;
      return total > 0.0001;
    }).toList();

    if (abiertosConTotal.isNotEmpty) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No se puede cerrar jornada'),
          content: Text(
            'Hay ${abiertosConTotal.length} pedido(s) abiertos con total mayor a 0. Cierra o cancela esos pedidos antes de cerrar la jornada.',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Entendido'),
            ),
          ],
        ),
      );
      return;
    }

    if (abiertos.isNotEmpty) {
      await _db.customStatement(
        "UPDATE pedidos SET estado = 'cancelado', cerrado_en = ? WHERE jornada_id = ? AND estado = 'abierto'",
        [_nowEpochMs(), jornada.id],
      );
    }

    await _db.customStatement(
      "UPDATE jornadas SET estado = 'cerrada', cerrada_en = ? WHERE id = ?",
      [_nowLocalSql(), jornada.id],
    );

    if (!mounted) return;
    if (abiertos.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Jornada cerrada. ${abiertos.length} pedido(s) abierto(s) con total 0 fueron marcados como cancelados.',
          ),
        ),
      );
    }

    await _cargarDatos();
  }

  Future<void> _eliminarJornada(_JornadaResumen jornada) async {
    if (jornada.estado == 'abierta') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No se puede borrar una jornada abierta. Debes cerrarla primero.',
          ),
        ),
      );
      return;
    }

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar jornada'),
        content: Text(
          '¿Estás seguro de eliminar la "${jornada.nombre}"? Esta acción borrará permanentemente la jornada y todos sus pedidos e ítems asociados.',
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
        [jornada.id],
      );
      await _db.customStatement(
        'DELETE FROM pedidos WHERE jornada_id = ?',
        [jornada.id],
      );
      await _db.customStatement(
        'DELETE FROM jornadas WHERE id = ?',
        [jornada.id],
      );
    });

    if (_jornadaSeleccionada?.id == jornada.id) {
      _jornadaSeleccionada = null;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Jornada eliminada correctamente.')),
    );
    await _cargarDatos();
  }

  Future<void> _crearPedido() async {
    final jornada = _jornadaSeleccionada;
    if (jornada == null || jornada.estado != 'abierta') return;

    String tipo = 'mesa';
    final referenciaCtrl = TextEditingController();
    final clienteCtrl = TextEditingController();
    final meseros = await _meserosConfigurados();
    String meseroSeleccionado = '';

    final valorDomicilioConfig = double.tryParse(
            await _leerConfig('valor_domicilio', fallback: '5000')) ??
        5000.0;
    final valorDomicilioCtrl =
        TextEditingController(text: valorDomicilioConfig.toStringAsFixed(0));

    if (!mounted) return;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.add_circle_rounded, color: AppColors.nuevoPedido),
              SizedBox(width: 8),
              Text('Nuevo pedido'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'mesa',
                      icon: Icon(Icons.table_restaurant_rounded, size: 18),
                      label: Text('Mesa'),
                    ),
                    ButtonSegment(
                      value: 'domicilio',
                      icon: Icon(Icons.delivery_dining_rounded, size: 18),
                      label: Text('Domicilio'),
                    ),
                  ],
                  selected: {tipo},
                  onSelectionChanged: (value) {
                    setLocalState(() => tipo = value.first);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: referenciaCtrl,
                  decoration: InputDecoration(
                    prefixIcon: Icon(
                      tipo == 'mesa'
                          ? Icons.table_bar_rounded
                          : Icons.location_on_outlined,
                    ),
                    labelText: tipo == 'mesa'
                        ? 'Referencia (Ej: Mesa 1)'
                        : 'Dirección o referencia',
                  ),
                ),
                if (tipo == 'domicilio') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: valorDomicilioCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.attach_money_rounded),
                      labelText: 'Precio del domicilio (\$)',
                      hintText: 'Ej: 5000',
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: clienteCtrl,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.person_outline_rounded),
                    labelText: 'Cliente (opcional)',
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: meseroSeleccionado,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.badge_outlined),
                    labelText: 'Mesero (opcional)',
                    helperText: meseros.isEmpty
                        ? 'Crea meseros en Configuración para verlos aquí.'
                        : null,
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('Sin mesero'),
                    ),
                    ...meseros.map(
                      (mesero) => DropdownMenuItem(
                        value: mesero,
                        child: Text(mesero),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    setLocalState(() => meseroSeleccionado = value ?? '');
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.nuevoPedido,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
              label: const Text('Crear y añadir productos'),
            ),
          ],
        ),
      ),
    );

    if (confirmar != true) return;

    final valorIngresado = double.tryParse(valorDomicilioCtrl.text.trim());
    final valorDomicilio =
        tipo == 'domicilio' ? (valorIngresado ?? valorDomicilioConfig) : 0.0;

    final maxTurnoRow = await _db.customSelect(
      'SELECT COALESCE(MAX(numero_turno), 0) AS max_turno FROM pedidos WHERE jornada_id = ?',
      variables: [Variable<int>(jornada.id)],
    ).getSingle();
    final numeroTurno = ((maxTurnoRow.data['max_turno'] as int?) ?? 0) + 1;

    final nuevoPedidoId = await _db.customInsert(
      '''
      INSERT INTO pedidos (mesa_id, tipo, valor_domicilio, estado, creado_en, jornada_id, referencia, cliente, mesero, numero_turno)
      VALUES (NULL, ?, ?, 'abierto', ?, ?, ?, ?, ?, ?)
      ''',
      variables: [
        Variable<String>(tipo),
        Variable<double>(valorDomicilio),
        Variable<int>(_nowEpochMs()),
        Variable<int>(jornada.id),
        Variable<String>(referenciaCtrl.text.trim()),
        Variable<String>(clienteCtrl.text.trim()),
        Variable<String>(meseroSeleccionado.trim()),
        Variable<int>(numeroTurno),
      ],
    );

    _filtroPedidos = 'abierto';
    await _cargarDatos();

    if (!mounted) return;
    final refTexto = referenciaCtrl.text.trim();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PedidoScreen(
          pedidoId: nuevoPedidoId,
          titulo: refTexto.isNotEmpty ? refTexto : 'Pedido $nuevoPedidoId',
          esDomicilio: tipo == 'domicilio',
        ),
      ),
    );
    await _cargarDatos();
  }

  Future<void> _editarPedidoAbierto(_PedidoResumen pedido) async {
    if (pedido.estado != 'abierto') return;

    final referenciaCtrl = TextEditingController(text: pedido.referencia);
    final clienteCtrl = TextEditingController(text: pedido.cliente);
    final meseros = await _meserosConfigurados();
    String meseroSeleccionado = pedido.mesero;

    if (!mounted) return;

    if (meseroSeleccionado.isNotEmpty &&
        !meseros.contains(meseroSeleccionado)) {
      meseroSeleccionado = '';
    }

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocalState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.edit_note_rounded, color: AppColors.editarDatos),
              const SizedBox(width: 8),
              Text('Editar datos #${pedido.id}'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: referenciaCtrl,
                  decoration: InputDecoration(
                    labelText: pedido.tipo == 'mesa'
                        ? 'Mesa o referencia'
                        : 'Dirección o referencia',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: clienteCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Cliente (opcional)',
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: meseroSeleccionado,
                  decoration: InputDecoration(
                    labelText: 'Mesero (opcional)',
                    helperText: meseros.isEmpty
                        ? 'Crea meseros en Configuración para verlos aquí.'
                        : null,
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('Sin mesero'),
                    ),
                    ...meseros.map(
                      (mesero) => DropdownMenuItem(
                        value: mesero,
                        child: Text(mesero),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    setLocalState(() => meseroSeleccionado = value ?? '');
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.save_outlined, size: 18),
              label: const Text('Guardar cambios'),
            ),
          ],
        ),
      ),
    );

    if (confirmar != true) return;

    final totalActualizados = await _db.customUpdate(
      "UPDATE pedidos SET referencia = ?, cliente = ?, mesero = ? WHERE id = ? AND estado = 'abierto'",
      variables: [
        Variable<String>(referenciaCtrl.text.trim()),
        Variable<String>(clienteCtrl.text.trim()),
        Variable<String>(meseroSeleccionado.trim()),
        Variable<int>(pedido.id),
      ],
      updates: {_db.pedidos},
    );

    if (!mounted) return;

    if (totalActualizados == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No se pudo editar el pedido porque ya no está abierto.',
          ),
        ),
      );
      await _cargarDatos();
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pedido actualizado correctamente.')),
    );
    await _cargarDatos();
  }

  Future<void> _actualizarEstadoPedido(int pedidoId, String estado, {String medioPago = ''}) async {
    final cerradoEn = estado == 'abierto' ? null : _nowEpochMs();
    if (medioPago.isNotEmpty) {
      await _db.customStatement(
        "UPDATE pedidos SET estado = ?, cerrado_en = ?, medio_pago = ? WHERE id = ?",
        [estado, cerradoEn, medioPago, pedidoId],
      );
    } else {
      await _db.customStatement(
        "UPDATE pedidos SET estado = ?, cerrado_en = ? WHERE id = ?",
        [estado, cerradoEn, pedidoId],
      );
    }
    await _cargarDatos();
  }

  Future<TicketData> _construirTicketData(
    _PedidoResumen pedido, {
    required String estado,
    String? medioPago,
    List<String>? infoTransferencia,
  }) async {
    final rows = await _db.customSelect(
      '''
      SELECT id, pedido_id, producto_id, nombre_producto, precio, cantidad, adicionales, nota
      FROM items_pedido
      WHERE pedido_id = ?
      ORDER BY id ASC
      ''',
      variables: [Variable<int>(pedido.id)],
    ).get();

    final items = rows.map((r) {
      final row = r.data;
      return ItemPedido(
        id: row['id'] as int,
        pedidoId: row['pedido_id'] as int,
        productoId: row['producto_id'] as int,
        nombreProducto: (row['nombre_producto'] as String?) ?? '',
        precio: (row['precio'] as num?)?.toDouble() ?? 0.0,
        cantidad: (row['cantidad'] as int?) ?? 1,
        adicionales: () {
          try {
            final decoded = jsonDecode((row['adicionales'] as String?) ?? '[]');
            if (decoded is List) {
              return decoded.map((e) => e.toString()).toList();
            }
          } catch (_) {}
          return <String>[];
        }(),
        nota: (row['nota'] as String?) ?? '',
      );
    }).toList();

    final nombreNegocio =
        await _leerConfig('nombre_negocio', fallback: 'POSify');

    final transferencias = infoTransferencia ??
        await MediosPagoService(_db).obtenerLineasTicket();
    final medioFinal = medioPago ?? pedido.medioPago;

    return TicketData(
      nombreNegocio: nombreNegocio,
      pedidoId: pedido.id,
      numeroTurno: pedido.numeroTurno,
      tipo: pedido.tipo,
      referencia: pedido.referencia,
      cliente: pedido.cliente,
      mesero: pedido.mesero,
      items: items,
      valorDomicilio: pedido.valorDomicilio,
      cobrarDomicilio: pedido.valorDomicilio > 0,
      estadoPedido: estado,
      fecha: DateTime.now(),
      impresoCliente: pedido.impresoCliente,
      impresoCocina: pedido.impresoCocina,
      medioPago: medioFinal,
      infoTransferencia: transferencias,
    );
  }

  Future<bool> _confirmarReimpresionPedido(
    _PedidoResumen pedido, {
    required bool esCocina,
  }) async {
    final yaImpreso = esCocina ? pedido.impresoCocina : pedido.impresoCliente;
    if (!yaImpreso) return true;
    if (!mounted) return false;

    final codigo = codigoTurnoDesde(
      pedido.numeroTurno > 0 ? pedido.numeroTurno : pedido.id,
    );
    final titulo = esCocina
        ? 'Orden de cocina ya impresa'
        : 'Factura de cliente ya impresa';
    final detalle = esCocina
        ? 'La orden de cocina del pedido $codigo ya fue enviada a imprimir anteriormente. ¿Deseas volver a imprimir la orden de cocina?'
        : 'La factura para el cliente del pedido $codigo ya fue impresa anteriormente. ¿Deseas volver a imprimir o ver la factura?';

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.print_rounded,
              color: esCocina ? AppColors.comandaCocina : AppColors.verTicket,
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
        content: Text(detalle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor:
                  esCocina ? AppColors.comandaCocina : AppColors.verTicket,
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

  Future<void> _verTicket(
    _PedidoResumen pedido, {
    bool modoCocina = false,
  }) async {
    if (pedido.itemsCount <= 0) {
      await _mostrarAlertaSinProductosCocina(pedido: pedido);
      return;
    }

    final continuar =
        await _confirmarReimpresionPedido(pedido, esCocina: modoCocina);
    if (!continuar) return;

    final data = await _construirTicketData(pedido, estado: pedido.estado);
    if (!mounted) return;
    if (data.items.isEmpty) {
      await _mostrarAlertaSinProductosCocina(pedido: pedido);
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            TicketPreviewScreen(data: data, modoCocinaInicial: modoCocina),
      ),
    );
    await _cargarDatos();
  }

  Future<void> _imprimirComandaCocina(
    _PedidoResumen pedido, {
    bool previsualizar = false,
  }) async {
    if (pedido.itemsCount <= 0) {
      await _mostrarAlertaSinProductosCocina(pedido: pedido);
      return;
    }

    final continuar =
        await _confirmarReimpresionPedido(pedido, esCocina: true);
    if (!continuar) return;

    final data = await _construirTicketData(pedido, estado: pedido.estado);
    if (!mounted) return;

    if (data.items.isEmpty) {
      await _mostrarAlertaSinProductosCocina(pedido: pedido);
      return;
    }

    if (previsualizar) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              TicketPreviewScreen(data: data, modoCocinaInicial: true),
        ),
      );
      await _cargarDatos();
      return;
    }

    final printerId = await _leerConfig('printer_device_id');
    final printerName =
        await _leerConfig('printer_device_name', fallback: 'POS');
    final anchoRaw = await _leerConfig('printer_paper_width', fallback: '32');
    final ancho = AnchoPapelX.desdeCaracteres(int.tryParse(anchoRaw) ?? 32);

    if (printerId.isEmpty) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              TicketPreviewScreen(data: data, modoCocinaInicial: true),
        ),
      );
      await _cargarDatos();
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Enviando comanda a cocina ($printerName)...'),
        duration: const Duration(seconds: 1),
      ),
    );

    try {
      const printerService = BluetoothPrinterService();
      final bytes = await buildEscPosCocinaBytes(data, ancho: ancho);
      final dev = await printerService.connect(printerId);
      final exito = dev != null && await printerService.printBytes(dev, bytes);

      if (!mounted) return;
      if (exito) {
        await _db.customStatement(
          'UPDATE pedidos SET impreso_cocina = 1 WHERE id = ?',
          [pedido.id],
        );
        await _cargarDatos();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Comanda enviada a cocina (${data.codigoTurno}). Marcada como ya impresa.'),
            action: SnackBarAction(
              label: 'Ver ticket',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TicketPreviewScreen(
                        data: data.copyWith(impresoCocina: true),
                        modoCocinaInicial: true),
                  ),
                ).then((_) => _cargarDatos());
              },
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'No se pudo imprimir automáticamente. Abriendo vista previa...')),
        );
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                TicketPreviewScreen(data: data, modoCocinaInicial: true),
          ),
        );
        await _cargarDatos();
      }
    } catch (_) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              TicketPreviewScreen(data: data, modoCocinaInicial: true),
        ),
      );
      await _cargarDatos();
    }
  }

  Future<void> _cerrarPedidoConImpresion(_PedidoResumen pedido) async {
    if (pedido.itemsCount == 0) {
      await _mostrarAlertaSinProductosCocina(pedido: pedido);
      return;
    }

    final mediosPagoConfig =
        await MediosPagoService(_db).obtenerConfiguracion();
    if (!mounted) return;

    final resultado = await DialogoCobrarPedido.mostrar(
      context: context,
      codigoTurno: codigoTurnoDesde(
        pedido.numeroTurno > 0 ? pedido.numeroTurno : pedido.id,
      ),
      referencia: pedido.referencia.isNotEmpty
          ? pedido.referencia
          : (pedido.tipo == 'domicilio' ? 'Domicilio' : 'Mesa'),
      cliente: pedido.cliente,
      total: pedido.total,
      config: mediosPagoConfig,
    );

    if (resultado == null || !resultado.confirmado) return;

    await _actualizarEstadoPedido(pedido.id, 'cerrado', medioPago: resultado.medioPago);
    final data = await _construirTicketData(
      pedido,
      estado: 'cerrado',
      medioPago: resultado.medioPago,
      infoTransferencia: mediosPagoConfig.lineasParaTicket,
    );

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TicketPreviewScreen(data: data)),
    );
    await _cargarDatos();
  }

  Future<void> _confirmarCancelacion(_PedidoResumen pedido) async {
    final tieneProductos = pedido.itemsCount > 0;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirmar cancelación'),
        content: Text(
          tieneProductos
              ? 'Este pedido tiene ${pedido.itemsCount} producto(s). ¿Estás seguro de cancelarlo?'
              : '¿Estás seguro de cancelar este pedido?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('No'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.cancel_outlined, size: 18),
            label: const Text('Sí, cancelar'),
          ),
        ],
      ),
    );

    if (confirmar == true) {
      await _actualizarEstadoPedido(pedido.id, 'cancelado');
    }
  }

  Future<void> _reabrirPedido(_PedidoResumen pedido) async {
    if (_jornadaSeleccionada?.estado != 'abierta') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('No se puede reabrir un pedido de una jornada ya cerrada.'),
        ),
      );
      return;
    }

    final codigo = codigoTurnoDesde(
        pedido.numeroTurno > 0 ? pedido.numeroTurno : pedido.id);

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reabrir pedido'),
        content: Text(
          '¿Deseas reabrir el pedido $codigo? El pedido cambiará a estado abierto para que puedas agregar o editar productos.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.lock_open_rounded, size: 18),
            label: const Text('Reabrir pedido'),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    await _actualizarEstadoPedido(pedido.id, 'abierto');

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Pedido $codigo reabierto correctamente.'),
      ),
    );
    await _cargarDatos();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        elevation: 0,
        title: const Text(
          '${AppStrings.appName} - Jornadas',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 21,
            color: Colors.white,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Configuración',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AdminConfigScreen()),
            ).then((_) => _cargarDatos()),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Barra superior: Selector Abiertas / Cerradas + Nueva Jornada
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: SegmentedButton<String>(
                          showSelectedIcon: false,
                          style: ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            textStyle: WidgetStateProperty.all(
                              const TextStyle(
                                  fontSize: 12.5, fontWeight: FontWeight.w700),
                            ),
                            padding: WidgetStateProperty.all(
                              const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 8),
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          segments: const [
                            ButtonSegment(
                              value: 'abiertas',
                              icon: Icon(Icons.storefront_rounded, size: 16),
                              label: Text('Abiertas'),
                            ),
                            ButtonSegment(
                              value: 'cerradas',
                              icon: Icon(Icons.history_rounded, size: 16),
                              label: Text('Cerradas'),
                            ),
                          ],
                          selected: {_vistaJornadas},
                          onSelectionChanged: (value) async {
                            _vistaJornadas = value.first;
                            _jornadaSeleccionada = null;
                            await _cargarDatos();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.primaryDark,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: _crearJornada,
                        icon: const Icon(Icons.add_business_rounded, size: 16),
                        label: const Text(
                          'Nueva jornada',
                          style: TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_vistaJornadas == 'cerradas')
                  Expanded(child: _buildJornadasCerradas())
                else if (_jornadas.isEmpty)
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.storefront_outlined,
                              size: 56,
                              color: AppColors.textMuted,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'No hay jornadas abiertas en este momento.',
                              style: TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'Crea una nueva jornada para empezar a registrar pedidos.',
                              style: TextStyle(color: AppColors.textMuted),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _crearJornada,
                              icon: const Icon(Icons.add_business_rounded),
                              label: const Text('Abrir nueva jornada'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DropdownButtonFormField<int>(
                            key: ValueKey(_jornadaSeleccionada?.id),
                            initialValue: _jornadaSeleccionada?.id,
                            decoration: const InputDecoration(
                              labelText: 'Jornada activa',
                              prefixIcon: Icon(Icons.calendar_today_rounded),
                              isDense: true,
                            ),
                            items: _jornadas
                                .map(
                                  (j) => DropdownMenuItem<int>(
                                    value: j.id,
                                    child: Text(j.nombre),
                                  ),
                                )
                                .toList(),
                            onChanged: (id) async {
                              _jornadaSeleccionada =
                                  _jornadas.firstWhere((j) => j.id == id);
                              await _cargarDatos();
                            },
                          ),
                          const SizedBox(height: 10),
                          // Botón de Nuevo Pedido muy visible y llamativo + Cerrar Jornada con color representativo
                          if (_jornadaSeleccionada?.estado == 'abierta') ...[
                            Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.nuevoPedido,
                                      foregroundColor: Colors.white,
                                      elevation: 3,
                                      shadowColor: AppColors.nuevoPedido
                                          .withValues(alpha: 0.45),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 13),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    onPressed: _crearPedido,
                                    icon: const Icon(
                                        Icons.add_circle_rounded,
                                        size: 22),
                                    label: const Text(
                                      'NUEVO PEDIDO',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 14.5,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  flex: 2,
                                  child: OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFF9A3412),
                                      backgroundColor: const Color(0xFFFFF7ED),
                                      side: const BorderSide(
                                        color: Color(0xFFEA580C),
                                        width: 1.2,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 13),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    onPressed: () =>
                                        _cerrarJornada(_jornadaSeleccionada!),
                                    icon: const Icon(Icons.lock_outline_rounded,
                                        size: 18),
                                    label: const Text(
                                      'Cerrar jornada',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                          ],
                          // Filtros Abiertos / Cerrados / Cancelados repartidos equitativamente con íconos y colores
                          Row(
                            children: [
                              Expanded(
                                child: _BotonEstadoFiltro(
                                  label: 'Abiertos',
                                  count: _conteoPorEstado['abierto'] ?? 0,
                                  icon: Icons.timelapse_rounded,
                                  color: AppColors.warning,
                                  selected: _filtroPedidos == 'abierto',
                                  onTap: () async {
                                    _filtroPedidos = 'abierto';
                                    await _cargarDatos();
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _BotonEstadoFiltro(
                                  label: 'Cerrados',
                                  count: _conteoPorEstado['cerrado'] ?? 0,
                                  icon: Icons.check_circle_outline_rounded,
                                  color: AppColors.success,
                                  selected: _filtroPedidos == 'cerrado',
                                  onTap: () async {
                                    _filtroPedidos = 'cerrado';
                                    await _cargarDatos();
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _BotonEstadoFiltro(
                                  label: 'Cancelados',
                                  count: _conteoPorEstado['cancelado'] ?? 0,
                                  icon: Icons.cancel_outlined,
                                  color: AppColors.error,
                                  selected: _filtroPedidos == 'cancelado',
                                  onTap: () async {
                                    _filtroPedidos = 'cancelado';
                                    await _cargarDatos();
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Expanded(
                            child: _pedidos.isEmpty
                                ? Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _filtroPedidos == 'abierto'
                                              ? Icons.receipt_long_outlined
                                              : (_filtroPedidos == 'cerrado'
                                                  ? Icons.task_alt_rounded
                                                  : Icons.cancel_outlined),
                                          size: 46,
                                          color: AppColors.textMuted,
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'No hay pedidos $_filtroPedidos' 's en esta jornada.',
                                          style: const TextStyle(
                                            color: AppColors.textMuted,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : ListView.separated(
                                    padding: const EdgeInsets.only(bottom: 16),
                                    itemCount: _pedidos.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 10),
                                    itemBuilder: (_, i) =>
                                        _buildPedidoCard(_pedidos[i]),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildPedidoCard(_PedidoResumen pedido) {
    final tieneProductos = pedido.itemsCount > 0;
    final subtitulo = [
      if (pedido.referencia.isNotEmpty) pedido.referencia,
      if (pedido.cliente.isNotEmpty) 'Cliente: ${pedido.cliente}',
      if (pedido.mesero.isNotEmpty) 'Mesero: ${pedido.mesero}',
    ].join(' · ');

    return Card(
      color: AppColors.surface,
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: tieneProductos
              ? AppColors.primary.withValues(alpha: 0.18)
              : AppColors.warning.withValues(alpha: 0.45),
          width: 1.2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _TurnoBadge(
                        numeroTurno:
                            pedido.numeroTurno > 0 ? pedido.numeroTurno : pedido.id,
                      ),
                      _EstadoTag(estado: pedido.estado),
                      if (!tieneProductos && pedido.estado == 'abierto')
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.warning.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(100),
                            border: Border.all(
                              color: AppColors.warning.withValues(alpha: 0.5),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.info_outline_rounded,
                                size: 13,
                                color: AppColors.warning,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Sin productos',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.warning,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (pedido.medioPago.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: pedido.medioPago.toLowerCase().contains('efectivo')
                                ? const Color(0xFF15803D).withValues(alpha: 0.12)
                                : const Color(0xFF0284C7).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: pedido.medioPago.toLowerCase().contains('efectivo')
                                  ? const Color(0xFF15803D).withValues(alpha: 0.3)
                                  : const Color(0xFF0284C7).withValues(alpha: 0.3),
                            ),
                          ),
                          child: Text(
                            pedido.medioPago,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: pedido.medioPago.toLowerCase().contains('efectivo')
                                  ? const Color(0xFF15803D)
                                  : const Color(0xFF0284C7),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: pedido.tipo == 'domicilio'
                        ? Colors.orange.withValues(alpha: 0.14)
                        : Colors.blue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        pedido.tipo == 'domicilio'
                            ? Icons.delivery_dining_rounded
                            : Icons.table_restaurant_rounded,
                        size: 14,
                        color: pedido.tipo == 'domicilio'
                            ? Colors.deepOrange
                            : Colors.blue.shade700,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        pedido.tipo == 'domicilio' ? 'Domicilio' : 'Mesa',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: pedido.tipo == 'domicilio'
                              ? Colors.deepOrange
                              : Colors.blue.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (subtitulo.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                subtitulo,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
            ],
            const SizedBox(height: 6),
            if (tieneProductos) ...[
              Text(
                '${pedido.itemsCount} producto(s) · Subtotal: ${_formatMoney(pedido.subtotal)}'
                '${pedido.tipo == 'domicilio' && pedido.valorDomicilio > 0 ? ' + Domicilio: ${_formatMoney(pedido.valorDomicilio)}' : ''}',
                style: const TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              if (pedido.resumenItems.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  pedido.resumenItems.join(', '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ] else
              const Text(
                'Este pedido aún no tiene productos cargados. Toca "Añadir productos" para comenzar.',
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            if (pedido.estado == 'abierto') ...[
              const SizedBox(height: 12),
              // Botón principal y más intuitivo: Añadir productos (siempre protagonista)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.agregarProductos,
                    foregroundColor: Colors.white,
                    elevation: 2,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => _abrirPantallaProductos(pedido),
                  icon: Icon(
                    tieneProductos
                        ? Icons.shopping_cart_checkout_rounded
                        : Icons.add_shopping_cart_rounded,
                    size: 20,
                  ),
                  label: Text(
                    tieneProductos
                        ? 'Añadir / Editar productos (${pedido.itemsCount})'
                        : 'Añadir productos al pedido',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Solo mostrar Comanda Cocina, Ver Ticket y Cerrar si el pedido TIENE productos
              if (tieneProductos) ...[
                if (pedido.impresoCocina || pedido.impresoCliente) ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (pedido.impresoCocina)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.success.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(100),
                            border: Border.all(
                              color: AppColors.success.withValues(alpha: 0.45),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check_circle_rounded,
                                size: 13,
                                color: AppColors.success,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Orden cocina: Ya impresa',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.success,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (pedido.impresoCliente)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.success.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(100),
                            border: Border.all(
                              color: AppColors.success.withValues(alpha: 0.45),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check_circle_rounded,
                                size: 13,
                                color: AppColors.success,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Factura cliente: Ya impresa',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.success,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: pedido.impresoCocina
                              ? AppColors.comandaCocina.withValues(alpha: 0.10)
                              : null,
                          foregroundColor: AppColors.comandaCocina,
                          side: const BorderSide(color: AppColors.comandaCocina),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 9),
                        ),
                        onPressed: () => _imprimirComandaCocina(pedido),
                        icon: Icon(
                          pedido.impresoCocina
                              ? Icons.check_circle_rounded
                              : Icons.soup_kitchen_rounded,
                          size: 17,
                        ),
                        label: Text(
                          pedido.impresoCocina
                              ? 'Cocina (Ya impresa)'
                              : 'Comanda cocina',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: pedido.impresoCliente
                              ? AppColors.verTicket.withValues(alpha: 0.10)
                              : null,
                          foregroundColor: AppColors.verTicket,
                          side: const BorderSide(color: AppColors.verTicket),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 9),
                        ),
                        onPressed: () => _verTicket(pedido),
                        icon: Icon(
                          pedido.impresoCliente
                              ? Icons.check_circle_rounded
                              : Icons.receipt_long_rounded,
                          size: 17,
                        ),
                        label: Text(
                          pedido.impresoCliente
                              ? 'Ticket (Ya impreso)'
                              : 'Ver ticket',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.cobrarCerrar,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => _cerrarPedidoConImpresion(pedido),
                        icon:
                            const Icon(Icons.point_of_sale_rounded, size: 16),
                        label: const Text(
                          'Cobrar',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      flex: 4,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.editarDatos,
                          side: const BorderSide(color: AppColors.editarDatos),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => _editarPedidoAbierto(pedido),
                        icon: const Icon(Icons.edit_note_rounded, size: 16),
                        label: const Text(
                          'Datos',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      flex: 5,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.error,
                          side: const BorderSide(color: AppColors.error),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => _confirmarCancelacion(pedido),
                        icon: const Icon(Icons.cancel_outlined, size: 15),
                        label: const Text(
                          'Cancelar',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // Cuando NO hay productos: solo permitir Editar datos del pedido o Cancelar
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.editarDatos,
                          side: const BorderSide(color: AppColors.editarDatos),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 9),
                        ),
                        onPressed: () => _editarPedidoAbierto(pedido),
                        icon: const Icon(Icons.edit_note_rounded, size: 18),
                        label: const Text(
                          'Editar datos',
                          style: TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.error,
                          side: const BorderSide(color: AppColors.error),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 9),
                        ),
                        onPressed: () => _confirmarCancelacion(pedido),
                        icon: const Icon(Icons.cancel_outlined, size: 18),
                        label: const Text(
                          'Cancelar pedido',
                          style: TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ] else if (pedido.estado == 'cerrado') ...[
              const SizedBox(height: 10),
              if (pedido.impresoCocina || pedido.impresoCliente) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (pedido.impresoCocina)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.success.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(100),
                          border: Border.all(
                            color: AppColors.success.withValues(alpha: 0.45),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check_circle_rounded,
                              size: 13,
                              color: AppColors.success,
                            ),
                            SizedBox(width: 4),
                            Text(
                              'Orden cocina: Ya impresa',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.success,
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (pedido.impresoCliente)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.success.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(100),
                          border: Border.all(
                            color: AppColors.success.withValues(alpha: 0.45),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check_circle_rounded,
                              size: 13,
                              color: AppColors.success,
                            ),
                            SizedBox(width: 4),
                            Text(
                              'Factura cliente: Ya impresa',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppColors.success,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (tieneProductos) ...[
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: pedido.impresoCocina
                            ? AppColors.comandaCocina.withValues(alpha: 0.10)
                            : null,
                        foregroundColor: AppColors.comandaCocina,
                        side: const BorderSide(color: AppColors.comandaCocina),
                      ),
                      onPressed: () => _imprimirComandaCocina(pedido),
                      icon: Icon(
                        pedido.impresoCocina
                            ? Icons.check_circle_rounded
                            : Icons.soup_kitchen_rounded,
                        size: 18,
                      ),
                      label: Text(
                        pedido.impresoCocina
                            ? 'Cocina (Ya impresa)'
                            : 'Comanda cocina',
                      ),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: pedido.impresoCliente
                            ? AppColors.verTicket.withValues(alpha: 0.10)
                            : null,
                        foregroundColor: AppColors.verTicket,
                        side: const BorderSide(color: AppColors.verTicket),
                      ),
                      onPressed: () => _verTicket(pedido),
                      icon: Icon(
                        pedido.impresoCliente
                            ? Icons.check_circle_rounded
                            : Icons.receipt_long_rounded,
                        size: 18,
                      ),
                      label: Text(
                        pedido.impresoCliente
                            ? 'Ticket (Ya impreso)'
                            : 'Ver / reimprimir ticket',
                      ),
                    ),
                  ],
                  if (_jornadaSeleccionada?.estado == 'abierta')
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => _reabrirPedido(pedido),
                      icon: const Icon(Icons.lock_open_rounded, size: 18),
                      label: const Text('Reabrir pedido'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildJornadasCerradas() {
    final now = DateTime.now();

    DateTime? parseDbDate(String value) {
      if (value.trim().isEmpty) return null;
      return DateTime.tryParse(value.replaceFirst(' ', 'T'));
    }

    bool esMismoDia(DateTime a, DateTime b) {
      return a.year == b.year && a.month == b.month && a.day == b.day;
    }

    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    final weekEnd = weekStart.add(const Duration(days: 7));

    final filtradas = _jornadas.where((j) {
      final fechaBase = parseDbDate(j.cerradaEn) ?? parseDbDate(j.abiertaEn);
      if (fechaBase == null) return false;

      final matchCalendario = _fechaCalendarioCerradas == null
          ? true
          : esMismoDia(fechaBase, _fechaCalendarioCerradas!);

      final matchRango = switch (_rangoCerradas) {
        'hoy' => esMismoDia(fechaBase, now),
        'semana' =>
          !fechaBase.isBefore(weekStart) && fechaBase.isBefore(weekEnd),
        'mes' => fechaBase.year == now.year && fechaBase.month == now.month,
        _ => true,
      };

      return matchCalendario && matchRango;
    }).toList();

    final totalGeneral =
        filtradas.fold<double>(0, (s, j) => s + j.totalGeneral);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _FiltroChip(
                  label: 'Todo',
                  icon: Icons.all_inclusive_rounded,
                  selected: _rangoCerradas == 'todo',
                  onTap: () => setState(() => _rangoCerradas = 'todo'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _FiltroChip(
                  label: 'Hoy',
                  icon: Icons.today_rounded,
                  selected: _rangoCerradas == 'hoy',
                  onTap: () => setState(() => _rangoCerradas = 'hoy'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _FiltroChip(
                  label: 'Semana',
                  icon: Icons.date_range_rounded,
                  selected: _rangoCerradas == 'semana',
                  onTap: () => setState(() => _rangoCerradas = 'semana'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _FiltroChip(
                  label: 'Mes',
                  icon: Icons.calendar_month_rounded,
                  selected: _rangoCerradas == 'mes',
                  onTap: () => setState(() => _rangoCerradas = 'mes'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final selected = await showDatePicker(
                      context: context,
                      initialDate: _fechaCalendarioCerradas ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (selected == null) return;
                    setState(() => _fechaCalendarioCerradas = selected);
                  },
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text(
                    _fechaCalendarioCerradas == null
                        ? 'Seleccionar fecha en calendario'
                        : 'Fecha: ${_fechaCalendarioCerradas!.toIso8601String().substring(0, 10)}',
                  ),
                ),
              ),
              if (_fechaCalendarioCerradas != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Limpiar fecha',
                  onPressed: () =>
                      setState(() => _fechaCalendarioCerradas = null),
                  icon: const Icon(Icons.close),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Total jornada filtrada: ${_formatMoney(totalGeneral)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'El total incluye productos vendidos y domicilios. Los cancelados quedan solo como referencia.',
              style: TextStyle(
                color: AppColors.textMuted.withValues(alpha: 0.9),
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filtradas.isEmpty
                ? const Center(
                    child: Text(
                      'No hay jornadas cerradas para esos filtros.',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  )
                : Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.2),
                      ),
                    ),
                    child: ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: filtradas.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) {
                        final j = filtradas[i];
                        return Card(
                          margin: EdgeInsets.zero,
                          color: AppColors.surface,
                          child: InkWell(
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => JornadaHistorialScreen(
                                  jornadaId: j.id,
                                  jornadaNombre: j.nombre,
                                ),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          j.nombre,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 15,
                                          ),
                                        ),
                                      ),
                                      _EstadoTag(estado: j.estado),
                                      const SizedBox(width: 4),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        tooltip: 'Eliminar jornada',
                                        icon: const Icon(Icons.delete_outline,
                                            color: AppColors.error, size: 20),
                                        onPressed: () => _eliminarJornada(j),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    'Apertura: ${_formatDateTime(j.abiertaEn)}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Cierre: ${_formatDateTime(j.cerradaEn)}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _ResumenMeta(
                                        label:
                                            'Productos: ${_formatMoney(j.totalProductos)}',
                                        color: AppColors.textPrimary,
                                      ),
                                      _ResumenMeta(
                                        label:
                                            'Domicilios: ${_formatMoney(j.totalDomicilios)}',
                                        color: AppColors.primary,
                                      ),
                                      _ResumenMeta(
                                        label:
                                            'Total: ${_formatMoney(j.totalGeneral)}',
                                        color: AppColors.success,
                                      ),
                                      _ResumenMeta(
                                        label:
                                            'Cancelados: ${j.totalCancelados}',
                                        color: AppColors.error,
                                      ),
                                    ],
                                  ),
                                  if (j.totalCancelados > 0) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      'Cancelados informativos: ${_formatMoney(j.totalCanceladosMonto)}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textMuted,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Toca para ver el detalle de la jornada.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(String raw) {
    if (raw.trim().isEmpty) return '-';
    final parsed = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
    if (parsed == null) return raw;
    final y = parsed.year.toString().padLeft(4, '0');
    final m = parsed.month.toString().padLeft(2, '0');
    final d = parsed.day.toString().padLeft(2, '0');
    final hh = parsed.hour.toString().padLeft(2, '0');
    final mm = parsed.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}

class _JornadaResumen {
  final int id;
  final String nombre;
  final String estado;
  final String abiertaEn;
  final String cerradaEn;
  final double totalProductos;
  final double totalDomicilios;
  final double totalCanceladosMonto;
  final int totalCancelados;

  const _JornadaResumen({
    required this.id,
    required this.nombre,
    required this.estado,
    required this.abiertaEn,
    required this.cerradaEn,
    this.totalProductos = 0,
    this.totalDomicilios = 0,
    this.totalCanceladosMonto = 0,
    this.totalCancelados = 0,
  });

  double get totalGeneral => totalProductos + totalDomicilios;

  _JornadaResumen copyWith({
    double? totalProductos,
    double? totalDomicilios,
    double? totalCanceladosMonto,
    int? totalCancelados,
  }) {
    return _JornadaResumen(
      id: id,
      nombre: nombre,
      estado: estado,
      abiertaEn: abiertaEn,
      cerradaEn: cerradaEn,
      totalProductos: totalProductos ?? this.totalProductos,
      totalDomicilios: totalDomicilios ?? this.totalDomicilios,
      totalCanceladosMonto: totalCanceladosMonto ?? this.totalCanceladosMonto,
      totalCancelados: totalCancelados ?? this.totalCancelados,
    );
  }
}

class _PedidoResumen {
  final int id;
  final String tipo;
  final String estado;
  final String referencia;
  final String cliente;
  final String mesero;
  final int itemsCount;
  final double subtotal;
  final double valorDomicilio;
  final int numeroTurno;
  final bool impresoCliente;
  final bool impresoCocina;
  final String medioPago;
  final List<String> resumenItems;

  double get total => subtotal + valorDomicilio;

  const _PedidoResumen({
    required this.id,
    required this.tipo,
    required this.estado,
    required this.referencia,
    required this.cliente,
    required this.mesero,
    required this.itemsCount,
    required this.subtotal,
    this.valorDomicilio = 0,
    this.numeroTurno = 0,
    this.impresoCliente = false,
    this.impresoCocina = false,
    this.medioPago = '',
    this.resumenItems = const [],
  });
}

/// Botón de filtro que se reparte equitativamente en la pantalla con ícono,
/// color representativo y contador.
class _BotonEstadoFiltro extends StatelessWidget {
  final String label;
  final int count;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _BotonEstadoFiltro({
    required this.label,
    required this.count,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? color : AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? color : color.withValues(alpha: 0.35),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 14,
                    color: selected ? Colors.white : color,
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: selected ? Colors.white : AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: selected ? Colors.white : color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FiltroChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _FiltroChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.accent : AppColors.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 15,
                  color: selected ? Colors.white : AppColors.primary,
                ),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : AppColors.textPrimary,
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

class _ResumenMeta extends StatelessWidget {
  final String label;
  final Color color;

  const _ResumenMeta({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _TurnoBadge extends StatelessWidget {
  final int numeroTurno;

  const _TurnoBadge({required this.numeroTurno});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        codigoTurnoDesde(numeroTurno),
        style: const TextStyle(
          fontSize: 12,
          color: Colors.white,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _EstadoTag extends StatelessWidget {
  final String estado;

  const _EstadoTag({required this.estado});

  Color get _color {
    switch (estado) {
      case 'cerrado':
        return AppColors.success;
      case 'cancelado':
        return AppColors.error;
      default:
        return AppColors.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        estado,
        style: TextStyle(
          fontSize: 12,
          color: _color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
