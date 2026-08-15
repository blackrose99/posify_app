import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show OrderingTerm, Variable;
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/money_formatter.dart';
import '../../../../database/app_database.dart';
import '../../../../injection_container.dart';
import '../../../impresion/ticket_data.dart';
import '../../domain/entities/item_pedido.dart';
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

  bool _loading = true;
  String _vistaJornadas = 'abiertas';
  String _filtroPedidos = 'abierto';
  List<_JornadaResumen> _jornadas = const [];
  _JornadaResumen? _jornadaSeleccionada;
  List<_PedidoResumen> _pedidos = const [];
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

    await _asegurarEstructuraJornadas();

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
             COALESCE(numero_turno, 0) AS numero_turno
      FROM pedidos
      WHERE jornada_id = ? AND estado = ?
      ORDER BY id DESC
      ''',
      variables: [Variable<int>(jornadaId), Variable<String>(estado)],
    ).get();

    final pedidos = <_PedidoResumen>[];
    for (final row in rows) {
      final data = row.data;
      final pedidoId = data['id'] as int;
      final itemsStats = await _db.customSelect(
        '''
        SELECT COALESCE(COUNT(id), 0) AS items_count,
               COALESCE(SUM(precio * cantidad), 0) AS subtotal
        FROM items_pedido
        WHERE pedido_id = ?
        ''',
        variables: [Variable<int>(pedidoId)],
      ).getSingle();
      final statData = itemsStats.data;

      pedidos.add(_PedidoResumen(
        id: data['id'] as int,
        tipo: (data['tipo'] as String?) ?? 'mesa',
        estado: (data['estado'] as String?) ?? 'abierto',
        referencia: ((data['referencia'] as String?) ?? '').trim(),
        cliente: ((data['cliente'] as String?) ?? '').trim(),
        mesero: ((data['mesero'] as String?) ?? '').trim(),
        itemsCount: (statData['items_count'] as int?) ?? 0,
        subtotal: (statData['subtotal'] as num?)?.toDouble() ?? 0,
        valorDomicilio: (data['valor_domicilio'] as num?)?.toDouble() ?? 0,
        numeroTurno: (data['numero_turno'] as int?) ?? 0,
      ));
    }
    return pedidos;
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
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(dialogContext, nombreController.text),
            child: const Text('Crear'),
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
          title: const Text('Nuevo pedido'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'mesa', label: Text('Mesa')),
                    ButtonSegment(value: 'domicilio', label: Text('Domicilio')),
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
                    labelText: tipo == 'mesa'
                        ? 'Referencia (Mesa 1)'
                        : 'Dirección o referencia',
                  ),
                ),
                if (tipo == 'domicilio') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: valorDomicilioCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Precio del domicilio (\$)',
                      hintText: 'Ej: 5000',
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: clienteCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Cliente (opcional)',
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: meseroSeleccionado,
                  decoration: InputDecoration(
                    labelText: 'Mesero (opcional)',
                    helperText: meseros.isEmpty
                        ? 'Crea meseros en Configuracion para verlos aqui.'
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
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Crear pedido'),
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

    await _db.customStatement(
      '''
      INSERT INTO pedidos (mesa_id, tipo, valor_domicilio, estado, creado_en, jornada_id, referencia, cliente, mesero, numero_turno)
      VALUES (NULL, ?, ?, 'abierto', ?, ?, ?, ?, ?, ?)
      ''',
      [
        tipo,
        valorDomicilio,
        _nowEpochMs(),
        jornada.id,
        referenciaCtrl.text.trim(),
        clienteCtrl.text.trim(),
        meseroSeleccionado.trim(),
        numeroTurno,
      ],
    );

    await _cargarDatos();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Pedido creado: ${codigoTurnoDesde(numeroTurno)}')),
    );
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
          title: Text('Editar pedido #${pedido.id}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: referenciaCtrl,
                  decoration: InputDecoration(
                    labelText: pedido.tipo == 'mesa'
                        ? 'Mesa o referencia'
                        : 'Direccion o referencia',
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
                  value: meseroSeleccionado,
                  decoration: InputDecoration(
                    labelText: 'Mesero (opcional)',
                    helperText: meseros.isEmpty
                        ? 'Crea meseros en Configuracion para verlos aqui.'
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
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Guardar cambios'),
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
            'No se pudo editar el pedido porque ya no esta abierto.',
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

  Future<void> _actualizarEstadoPedido(int pedidoId, String estado) async {
    final cerradoEn = estado == 'abierto' ? null : _nowEpochMs();
    await _db.customStatement(
      "UPDATE pedidos SET estado = ?, cerrado_en = ? WHERE id = ?",
      [estado, cerradoEn, pedidoId],
    );
    await _cargarDatos();
  }

  Future<TicketData> _construirTicketData(
    _PedidoResumen pedido, {
    required String estado,
  }) async {
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
                if (decoded is List) return decoded.map((e) => e.toString()).toList();
              } catch (_) {}
              return <String>[];
            }(),
            nota: row.nota,
          ),
        )
        .toList();

    final nombreNegocio = await _leerConfig('nombre_negocio', fallback: 'POSify');

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
    );
  }

  Future<void> _verTicket(_PedidoResumen pedido) async {
    final data = await _construirTicketData(pedido, estado: pedido.estado);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TicketPreviewScreen(data: data)),
    );
  }

  Future<void> _cerrarPedidoConImpresion(_PedidoResumen pedido) async {
    if (pedido.itemsCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agrega productos antes de cerrar.')),
      );
      return;
    }

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cerrar pedido'),
        content: const Text(
          'Se generará la factura final con el código de turno. ¿Deseas continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Cerrar pedido'),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    await _actualizarEstadoPedido(pedido.id, 'cerrado');
    final data = await _construirTicketData(pedido, estado: 'cerrado');

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TicketPreviewScreen(data: data)),
    );
  }

  Future<void> _confirmarCancelacion(_PedidoResumen pedido) async {
    final tieneProductos = pedido.itemsCount > 0;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirmar cancelacion'),
        content: Text(
          tieneProductos
              ? 'Este pedido tiene ${pedido.itemsCount} producto(s). Estas segura de cancelarlo?'
              : 'Estas segura de cancelar este pedido?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Si, cancelar'),
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
          '¿Deseas reabrir el pedido $codigo? El pedido cambiará a estado abierto para que puedas agregar más productos.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Reabrir pedido'),
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
            fontSize: 22,
            color: Colors.white,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Configuracion',
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: SegmentedButton<String>(
                          style: ButtonStyle(
                            visualDensity: VisualDensity.standard,
                            textStyle: WidgetStateProperty.all(
                              const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            padding: WidgetStateProperty.all(
                              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          segments: const [
                            ButtonSegment(
                              value: 'abiertas',
                              label: Text('Abiertas', maxLines: 1, softWrap: false),
                            ),
                            ButtonSegment(
                              value: 'cerradas',
                              label: Text('Cerradas', maxLines: 1, softWrap: false),
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
                      ElevatedButton.icon(
                        onPressed: _crearJornada,
                        icon: const Icon(Icons.add),
                        label: const Text('Nueva jornada'),
                      ),
                    ],
                  ),
                ),
                if (_vistaJornadas == 'cerradas')
                  Expanded(child: _buildJornadasCerradas())
                else if (_jornadas.isEmpty)
                  const Expanded(
                    child: Center(
                      child: Text(
                        'No hay jornadas en esta vista.',
                        style: TextStyle(color: AppColors.textMuted),
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
                            value: _jornadaSeleccionada?.id,
                            decoration: const InputDecoration(
                              labelText: 'Jornada',
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
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (_jornadaSeleccionada?.estado == 'abierta') ...[
                                ElevatedButton.icon(
                                  onPressed: _crearPedido,
                                  icon: const Icon(Icons.receipt_long),
                                  label: const Text('Nuevo pedido'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      _cerrarJornada(_jornadaSeleccionada!),
                                  icon: const Icon(Icons.lock_outline),
                                  label: const Text('Cerrar jornada'),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            children: [
                              _FiltroChip(
                                label: 'Abiertos',
                                selected: _filtroPedidos == 'abierto',
                                onTap: () async {
                                  _filtroPedidos = 'abierto';
                                  await _cargarDatos();
                                },
                              ),
                              _FiltroChip(
                                label: 'Cerrados',
                                selected: _filtroPedidos == 'cerrado',
                                onTap: () async {
                                  _filtroPedidos = 'cerrado';
                                  await _cargarDatos();
                                },
                              ),
                              _FiltroChip(
                                label: 'Cancelados',
                                selected: _filtroPedidos == 'cancelado',
                                onTap: () async {
                                  _filtroPedidos = 'cancelado';
                                  await _cargarDatos();
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: _pedidos.isEmpty
                                ? const Center(
                                    child: Text(
                                      'No hay pedidos para este filtro.',
                                      style:
                                          TextStyle(color: AppColors.textMuted),
                                    ),
                                  )
                                : ListView.separated(
                                    itemCount: _pedidos.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(height: 8),
                                    itemBuilder: (_, i) {
                                      final pedido = _pedidos[i];
                                      final subtitulo = [
                                        if (pedido.referencia.isNotEmpty)
                                          pedido.referencia,
                                        if (pedido.cliente.isNotEmpty)
                                          'Cliente: ${pedido.cliente}',
                                        if (pedido.mesero.isNotEmpty)
                                          'Mesero: ${pedido.mesero}',
                                      ].join(' · ');

                                      return Card(
                                        color: AppColors.surface,
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  _TurnoBadge(
                                                    numeroTurno:
                                                        pedido.numeroTurno > 0
                                                            ? pedido.numeroTurno
                                                            : pedido.id,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  _EstadoTag(
                                                      estado: pedido.estado),
                                                  const Spacer(),
                                                  Text(
                                                    pedido.tipo == 'domicilio'
                                                        ? 'Domicilio'
                                                        : 'Mesa',
                                                    style: const TextStyle(
                                                      color:
                                                          AppColors.textMuted,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                '${pedido.itemsCount} item(s) · Subtotal: ${_formatMoney(pedido.subtotal)}',
                                                style: const TextStyle(
                                                  color: AppColors.textMuted,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              if (subtitulo.isNotEmpty) ...[
                                                const SizedBox(height: 6),
                                                Text(
                                                  subtitulo,
                                                  style: const TextStyle(
                                                    color: AppColors.textMuted,
                                                  ),
                                                ),
                                              ],
                                              if (pedido.estado ==
                                                  'abierto') ...[
                                                const SizedBox(height: 10),
                                                Wrap(
                                                  spacing: 8,
                                                  children: [
                                                    OutlinedButton(
                                                      onPressed: () =>
                                                          _editarPedidoAbierto(
                                                              pedido),
                                                      child: const Text(
                                                          'Editar datos'),
                                                    ),
                                                    OutlinedButton.icon(
                                                      onPressed: () =>
                                                          _verTicket(pedido),
                                                      icon: const Icon(
                                                          Icons.receipt_long,
                                                          size: 18),
                                                      label: const Text(
                                                          'Ver ticket'),
                                                    ),
                                                    OutlinedButton(
                                                      onPressed: () =>
                                                          Navigator.push(
                                                        context,
                                                        MaterialPageRoute(
                                                          builder: (_) =>
                                                              PedidoScreen(
                                                            pedidoId: pedido.id,
                                                            titulo: pedido
                                                                    .referencia
                                                                    .isNotEmpty
                                                                ? pedido
                                                                    .referencia
                                                                : 'Pedido ${pedido.id}',
                                                            esDomicilio:
                                                                pedido.tipo ==
                                                                    'domicilio',
                                                          ),
                                                        ),
                                                      ).then((_) =>
                                                              _cargarDatos()),
                                                      child: const Text(
                                                          'Agregar productos'),
                                                    ),
                                                    ElevatedButton(
                                                      onPressed: () =>
                                                          _cerrarPedidoConImpresion(
                                                              pedido),
                                                      child:
                                                          const Text('Cerrar'),
                                                    ),
                                                    TextButton(
                                                      onPressed: () =>
                                                          _confirmarCancelacion(
                                                              pedido),
                                                      child: const Text(
                                                          'Cancelar'),
                                                    ),
                                                  ],
                                                ),
                                              ] else if (pedido.estado ==
                                                  'cerrado') ...[
                                                const SizedBox(height: 10),
                                                Wrap(
                                                  spacing: 8,
                                                  runSpacing: 8,
                                                  children: [
                                                    OutlinedButton.icon(
                                                      onPressed: () =>
                                                          _verTicket(pedido),
                                                      icon: const Icon(
                                                          Icons.receipt_long,
                                                          size: 18),
                                                      label: const Text(
                                                          'Ver / reimprimir ticket'),
                                                    ),
                                                    if (_jornadaSeleccionada
                                                            ?.estado ==
                                                        'abierta')
                                                      ElevatedButton.icon(
                                                        onPressed: () =>
                                                            _reabrirPedido(
                                                                pedido),
                                                        icon: const Icon(
                                                            Icons.lock_open,
                                                            size: 18),
                                                        label: const Text(
                                                            'Reabrir pedido'),
                                                      ),
                                                  ],
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      );
                                    },
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
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              children: [
                _FiltroChip(
                  label: 'Todo',
                  selected: _rangoCerradas == 'todo',
                  onTap: () => setState(() => _rangoCerradas = 'todo'),
                ),
                _FiltroChip(
                  label: 'Hoy',
                  selected: _rangoCerradas == 'hoy',
                  onTap: () => setState(() => _rangoCerradas = 'hoy'),
                ),
                _FiltroChip(
                  label: 'Semana',
                  selected: _rangoCerradas == 'semana',
                  onTap: () => setState(() => _rangoCerradas = 'semana'),
                ),
                _FiltroChip(
                  label: 'Mes',
                  selected: _rangoCerradas == 'mes',
                  onTap: () => setState(() => _rangoCerradas = 'mes'),
                ),
              ],
            ),
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
  });
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
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.accent,
      labelStyle: TextStyle(
        color: selected ? Colors.white : AppColors.textPrimary,
      ),
      backgroundColor: AppColors.surface,
      side: BorderSide.none,
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
