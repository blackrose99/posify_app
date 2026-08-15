import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm, Value, Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/utils/money_formatter.dart';
import '../../../../database/app_database.dart' as dbi;
import '../../../../injection_container.dart';
import '../../../impresion/ticket_data.dart';
import '../../../productos/domain/entities/producto.dart';
import '../../../productos/presentation/providers/productos_provider.dart';
import '../../domain/entities/item_pedido.dart';
import '../widgets/adicionales_chips.dart';
import '../widgets/cantidad_selector.dart';
import 'ticket_preview_screen.dart';

const double _anchoBreakpointEscritorio = 900;

String _formatMoney(num value) {
  return formatMoney(value);
}

class PedidoScreen extends ConsumerStatefulWidget {
  final int pedidoId;
  final String titulo;
  final bool esDomicilio;

  const PedidoScreen({
    super.key,
    required this.pedidoId,
    required this.titulo,
    required this.esDomicilio,
  });

  @override
  ConsumerState<PedidoScreen> createState() => _PedidoScreenState();
}

class _PedidoScreenState extends ConsumerState<PedidoScreen> {
  bool _cargando = true;
  int? _pedidoId;
  int _numeroTurno = 0;
  String _estadoPedido = 'abierto';
  String _referencia = '';
  String _cliente = '';
  String _mesero = '';
  final dbi.AppDatabase _db = sl<dbi.AppDatabase>();
  final List<ItemPedido> _items = [];
  bool _esDomicilio = false;
  bool _cobrarDomicilio = false;
  double _valorDomicilioPedido = 5000;
  bool _jornadaEstaAbierta = true;

  int _nowEpochMs() => DateTime.now().millisecondsSinceEpoch;

  String _normalizarNota(String nota) => nota.trim();

  List<String> _normalizarAdicionales(List<String> adicionales) {
    final normalizados = adicionales
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList()
      ..sort();
    return normalizados;
  }

  String _firmaItem({
    required int productoId,
    required double precio,
    required List<String> adicionales,
    required String nota,
  }) {
    final precioCentavos = (precio * 100).round();
    final adicionalesFirma = _normalizarAdicionales(adicionales).join('|');
    final notaFirma = _normalizarNota(nota);
    return '$productoId#$precioCentavos#$adicionalesFirma#$notaFirma';
  }

  Future<void> _consolidarItemsDuplicadosPedido(int pedidoId) async {
    final rows = await (_db.select(_db.itemsPedido)
          ..where((i) => i.pedidoId.equals(pedidoId))
          ..orderBy([(i) => OrderingTerm.asc(i.id)]))
        .get();

    final porFirma = <String, List<dbi.ItemsPedidoData>>{};
    for (final row in rows) {
      List<String> adicionales = const [];
      try {
        final decoded = jsonDecode(row.adicionales);
        if (decoded is List) {
          adicionales = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {
        adicionales = const [];
      }

      final firma = _firmaItem(
        productoId: row.productoId,
        precio: row.precio,
        adicionales: adicionales,
        nota: row.nota,
      );
      porFirma.putIfAbsent(firma, () => []).add(row);
    }

    final hayDuplicados = porFirma.values.any((grupo) => grupo.length > 1);
    if (!hayDuplicados) return;

    await _db.transaction(() async {
      for (final grupo in porFirma.values) {
        if (grupo.length <= 1) continue;

        final base = grupo.first;
        final cantidadTotal =
            grupo.fold<int>(0, (sum, item) => sum + item.cantidad);

        await (_db.update(_db.itemsPedido)..where((i) => i.id.equals(base.id)))
            .write(dbi.ItemsPedidoCompanion(cantidad: Value(cantidadTotal)));

        final idsEliminar = grupo.skip(1).map((e) => e.id).toList();
        for (final id in idsEliminar) {
          await (_db.delete(_db.itemsPedido)..where((i) => i.id.equals(id)))
              .go();
        }
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _inicializar();
  }

  Future<void> _inicializar() async {
    await _normalizarFechasPedidos();
    await _consolidarItemsDuplicadosPedido(widget.pedidoId);

    final pedidoRow = await _db.customSelect(
      '''
      SELECT p.tipo, p.valor_domicilio, p.estado, p.referencia, p.cliente, p.mesero,
             COALESCE(p.numero_turno, 0) AS numero_turno,
             j.estado AS jornada_estado
      FROM pedidos p
      LEFT JOIN jornadas j ON j.id = p.jornada_id
      WHERE p.id = ?
      LIMIT 1
      ''',
      variables: [Variable<int>(widget.pedidoId)],
    ).getSingle();
    final pedidoData = pedidoRow.data;

    final valorDomicilioConf = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals('valor_domicilio')))
        .getSingleOrNull();
    final configParsed =
        double.tryParse(valorDomicilioConf?.valor ?? '5000') ?? 5000;

    final rows = await (_db.select(_db.itemsPedido)
          ..where((i) => i.pedidoId.equals(widget.pedidoId)))
        .get();

    final valDomDb = ((pedidoData['valor_domicilio'] as num?) ?? 0).toDouble();

    if (!mounted) return;

    setState(() {
      _pedidoId = widget.pedidoId;
      _valorDomicilioPedido = valDomDb > 0 ? valDomDb : configParsed;
      _esDomicilio = (pedidoData['tipo'] as String?) == 'domicilio';
      _cobrarDomicilio =
          _esDomicilio && valDomDb > 0;
      _estadoPedido = (pedidoData['estado'] as String?) ?? 'abierto';
      _referencia = ((pedidoData['referencia'] as String?) ?? '').trim();
      _cliente = ((pedidoData['cliente'] as String?) ?? '').trim();
      _mesero = ((pedidoData['mesero'] as String?) ?? '').trim();
      _numeroTurno = (pedidoData['numero_turno'] as int?) ?? 0;
      _jornadaEstaAbierta =
          (pedidoData['jornada_estado'] as String?) == 'abierta';
      _items
        ..clear()
        ..addAll(
          rows.map(
            (item) => ItemPedido(
              id: item.id,
              pedidoId: item.pedidoId,
              productoId: item.productoId,
              nombreProducto: item.nombreProducto,
              precio: item.precio,
              cantidad: item.cantidad,
              adicionales: List<String>.from(
                jsonDecode(item.adicionales) as List<dynamic>,
              ),
              nota: item.nota,
            ),
          ),
        );
      _cargando = false;
    });
  }

  Future<void> _normalizarFechasPedidos() async {
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

  Future<void> _actualizarModoDomicilio({double? nuevoValor}) async {
    if (_pedidoId == null) return;
    if (nuevoValor != null && nuevoValor > 0) {
      _valorDomicilioPedido = nuevoValor;
    }
    final tipo = _esDomicilio ? 'domicilio' : 'mesa';
    final valor =
        _esDomicilio ? (_cobrarDomicilio ? _valorDomicilioPedido : 0.0) : 0.0;

    await (_db.update(_db.pedidos)..where((p) => p.id.equals(_pedidoId!)))
        .write(
      dbi.PedidosCompanion(
        tipo: Value(tipo),
        valorDomicilio: Value(valor),
      ),
    );
    setState(() {});
  }

  Future<String> _leerConfig(String clave, {String fallback = ''}) async {
    final row = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals(clave)))
        .getSingleOrNull();
    return row?.valor ?? fallback;
  }

  Future<void> _actualizarEstadoPedido(String estado) async {
    if (_pedidoId == null) return;
    final cerradoEn = estado == 'abierto' ? null : _nowEpochMs();
    await _db.customStatement(
      'UPDATE pedidos SET estado = ?, cerrado_en = ? WHERE id = ?',
      [estado, cerradoEn, _pedidoId!],
    );
    setState(() => _estadoPedido = estado);
  }

  Future<TicketData> _construirTicketData({required String estado}) async {
    final nombreNegocio = await _leerConfig('nombre_negocio', fallback: 'POSify');
    return TicketData(
      nombreNegocio: nombreNegocio,
      pedidoId: _pedidoId ?? widget.pedidoId,
      numeroTurno: _numeroTurno,
      tipo: _esDomicilio ? 'domicilio' : 'mesa',
      referencia: _referencia.isNotEmpty ? _referencia : widget.titulo,
      cliente: _cliente,
      mesero: _mesero,
      items: List<ItemPedido>.from(_items),
      valorDomicilio: _valorDomicilioPedido,
      cobrarDomicilio: _cobrarDomicilio,
      estadoPedido: estado,
      fecha: DateTime.now(),
    );
  }

  Future<void> _verTicketActual() async {
    final data = await _construirTicketData(estado: _estadoPedido);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TicketPreviewScreen(data: data)),
    );
  }

  Future<void> _cerrarPedidoDesdeDetalle() async {
    if (_pedidoId == null) return;

    if (_items.isEmpty) {
      if (!mounted) return;
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

    await _actualizarEstadoPedido('cerrado');
    final data = await _construirTicketData(estado: 'cerrado');

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TicketPreviewScreen(data: data)),
    );

    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _cancelarPedidoDesdeDetalle() async {
    if (_pedidoId == null) return;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Confirmar cancelacion'),
        content: Text(
          _items.isNotEmpty
              ? 'Este pedido tiene ${_items.length} item(s). Estas segura de cancelarlo?'
              : 'Estas segura de cancelar este pedido?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Si, cancelar'),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    await _actualizarEstadoPedido('cancelado');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pedido cancelado.')),
    );
    Navigator.pop(context, true);
  }

  Future<void> _reabrirPedidoDesdeDetalle() async {
    if (_pedidoId == null) return;
    if (!_jornadaEstaAbierta) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No se puede reabrir un pedido de una jornada ya cerrada.',
          ),
        ),
      );
      return;
    }

    final codigo =
        codigoTurnoDesde(_numeroTurno > 0 ? _numeroTurno : _pedidoId!);

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reabrir pedido'),
        content: Text(
          '¿Deseas reabrir el pedido $codigo? El pedido volverá a estar abierto para agregar o modificar productos.',
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

    await _actualizarEstadoPedido('abierto');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Pedido $codigo reabierto correctamente.'),
      ),
    );
  }

  Future<void> _mostrarModalDomicilio() async {
    if (_pedidoId == null) return;

    bool esDomicilioLocal = _esDomicilio;
    bool cobrarDomicilioLocal = _cobrarDomicilio;
    final precioCtrl = TextEditingController(
      text: _valorDomicilioPedido.toStringAsFixed(0),
    );

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setLocalState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              MediaQuery.of(sheetContext).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Configuración de domicilio',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Ajusta aquí si el pedido es a domicilio, activa el cobro y modifica la tarifa si lo deseas.',
                  style: TextStyle(color: AppColors.textMuted),
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Enviar a domicilio'),
                  value: esDomicilioLocal,
                  onChanged: (value) {
                    setLocalState(() {
                      esDomicilioLocal = value;
                      if (!value) {
                        cobrarDomicilioLocal = false;
                      } else if (!cobrarDomicilioLocal) {
                        cobrarDomicilioLocal = true;
                      }
                    });
                  },
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Cobrar domicilio'),
                  subtitle: Text(_formatMoney(_valorDomicilioPedido)),
                  value: esDomicilioLocal && cobrarDomicilioLocal,
                  onChanged: esDomicilioLocal
                      ? (value) {
                          setLocalState(() => cobrarDomicilioLocal = value);
                        }
                      : null,
                ),
                if (esDomicilioLocal && cobrarDomicilioLocal) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: precioCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Precio del domicilio (\$)',
                      hintText: 'Ej: 5000',
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () async {
                    final nuevoValor = double.tryParse(precioCtrl.text.trim());
                    setState(() {
                      _esDomicilio = esDomicilioLocal;
                      _cobrarDomicilio = cobrarDomicilioLocal;
                    });
                    await _actualizarModoDomicilio(nuevoValor: nuevoValor);

                    if (!sheetContext.mounted) return;
                    Navigator.of(sheetContext).pop();
                  },
                  child: const Text('Guardar cambios'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _agregarProductoConDatos(
    Producto producto,
    int cantidad,
    List<String> adicionales,
    String nota,
  ) async {
    if (_pedidoId == null) return;

    final adicionalesNorm = _normalizarAdicionales(adicionales);
    final notaNorm = _normalizarNota(nota);
    final firmaNuevo = _firmaItem(
      productoId: producto.id,
      precio: producto.precio,
      adicionales: adicionalesNorm,
      nota: notaNorm,
    );

    final indexExistente = _items.indexWhere(
      (item) =>
          _firmaItem(
            productoId: item.productoId,
            precio: item.precio,
            adicionales: item.adicionales,
            nota: item.nota,
          ) ==
          firmaNuevo,
    );

    if (indexExistente != -1) {
      final itemExistente = _items[indexExistente];
      final nuevaCantidad = itemExistente.cantidad + cantidad;

      await (_db.update(_db.itemsPedido)
            ..where((i) => i.id.equals(itemExistente.id)))
          .write(dbi.ItemsPedidoCompanion(cantidad: Value(nuevaCantidad)));

      if (!mounted) return;
      setState(() {
        _items[indexExistente] = ItemPedido(
          id: itemExistente.id,
          pedidoId: itemExistente.pedidoId,
          productoId: itemExistente.productoId,
          nombreProducto: itemExistente.nombreProducto,
          precio: itemExistente.precio,
          cantidad: nuevaCantidad,
          adicionales: itemExistente.adicionales,
          nota: itemExistente.nota,
        );
      });
      return;
    }

    final itemId = await _db.into(_db.itemsPedido).insert(
          dbi.ItemsPedidoCompanion.insert(
            pedidoId: _pedidoId!,
            productoId: producto.id,
            nombreProducto: producto.nombre,
            precio: producto.precio,
            cantidad: Value(cantidad),
            adicionales: Value(jsonEncode(adicionalesNorm)),
            nota: Value(notaNorm),
          ),
        );

    final item = ItemPedido(
      id: itemId,
      pedidoId: _pedidoId!,
      productoId: producto.id,
      nombreProducto: producto.nombre,
      precio: producto.precio,
      cantidad: cantidad,
      adicionales: adicionalesNorm,
      nota: notaNorm,
    );
    if (!mounted) return;
    setState(() => _items.add(item));
  }

  void _agregarRapido(Producto producto) {
    _agregarProductoConDatos(producto, 1, const [], '');
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('+1 ${producto.nombre}'),
        duration: const Duration(milliseconds: 900),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.primary,
        width: 220,
      ),
    );
  }

  int _indiceSimpleEnCarrito(Producto producto) {
    final firma = _firmaItem(
      productoId: producto.id,
      precio: producto.precio,
      adicionales: const [],
      nota: '',
    );
    return _items.indexWhere(
      (item) => _firmaItem(
            productoId: item.productoId,
            precio: item.precio,
            adicionales: item.adicionales,
            nota: item.nota,
          ) ==
          firma,
    );
  }

  int _cantidadSimpleEnCarrito(Producto producto) {
    final index = _indiceSimpleEnCarrito(producto);
    return index == -1 ? 0 : _items[index].cantidad;
  }

  Future<void> _quitarRapido(Producto producto) async {
    final index = _indiceSimpleEnCarrito(producto);
    if (index == -1) return;

    final item = _items[index];
    if (item.cantidad > 1) {
      final nuevaCantidad = item.cantidad - 1;
      await (_db.update(_db.itemsPedido)..where((i) => i.id.equals(item.id)))
          .write(dbi.ItemsPedidoCompanion(cantidad: Value(nuevaCantidad)));
      if (!mounted) return;
      setState(() {
        _items[index] = ItemPedido(
          id: item.id,
          pedidoId: item.pedidoId,
          productoId: item.productoId,
          nombreProducto: item.nombreProducto,
          precio: item.precio,
          cantidad: nuevaCantidad,
          adicionales: item.adicionales,
          nota: item.nota,
        );
      });
    } else {
      await (_db.delete(_db.itemsPedido)..where((i) => i.id.equals(item.id)))
          .go();
      if (!mounted) return;
      setState(() => _items.removeAt(index));
    }
  }

  Future<void> _personalizarYAgregar(
    Producto producto,
    List<String> etiquetasDisponibles,
  ) async {
    int cantidad = 1;
    final seleccionados = <String>[];
    final notaCtrl = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setLocalState) => Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            4,
            16,
            MediaQuery.of(sheetContext).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  producto.nombre,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatMoney(producto.precio),
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                if (etiquetasDisponibles.isNotEmpty) ...[
                  const Text('Adicionales', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  AdicionalesChips(
                    adicionales: etiquetasDisponibles,
                    seleccionados: seleccionados,
                    onToggle: (nombre) => setLocalState(() {
                      seleccionados.contains(nombre)
                          ? seleccionados.remove(nombre)
                          : seleccionados.add(nombre);
                    }),
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: notaCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nota del mesero (opcional)',
                    hintText: 'Ej: Sin cebolla, termino 3/4, extra salsa',
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    CantidadSelector(
                      cantidad: cantidad,
                      onIncrementar: () => setLocalState(() => cantidad++),
                      onDecrementar: () => setLocalState(() => cantidad--),
                    ),
                    const Spacer(),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        _agregarProductoConDatos(
                          producto,
                          cantidad,
                          List<String>.from(seleccionados),
                          notaCtrl.text.trim(),
                        );
                        Navigator.pop(sheetContext);
                      },
                      child: Text(
                        'Agregar · ${_formatMoney(producto.precio * cantidad)}',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editarItem(ItemPedido item) async {
    final cantidadCtrl = TextEditingController(text: item.cantidad.toString());

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Editar ${item.nombreProducto}'),
        content: TextField(
          controller: cantidadCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Cantidad'),
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
    );

    if (ok != true) return;
    final nuevaCantidad = int.tryParse(cantidadCtrl.text.trim());
    if (nuevaCantidad == null || nuevaCantidad <= 0) return;

    await (_db.update(_db.itemsPedido)..where((i) => i.id.equals(item.id)))
        .write(
      dbi.ItemsPedidoCompanion(cantidad: Value(nuevaCantidad)),
    );

    if (!mounted) return;
    setState(() {
      final idx = _items.indexWhere((e) => e.id == item.id);
      if (idx == -1) return;
      _items[idx] = ItemPedido(
        id: item.id,
        pedidoId: item.pedidoId,
        productoId: item.productoId,
        nombreProducto: item.nombreProducto,
        precio: item.precio,
        cantidad: nuevaCantidad,
        adicionales: item.adicionales,
        nota: item.nota,
      );
    });
  }

  Future<void> _eliminarItem(ItemPedido item) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminar producto'),
        content: Text('Deseas eliminar ${item.nombreProducto} del pedido?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    await (_db.delete(_db.itemsPedido)..where((i) => i.id.equals(item.id)))
        .go();
    if (!mounted) return;
    setState(() => _items.removeWhere((e) => e.id == item.id));
  }

  double get _subtotal => _items.fold(0, (s, i) => s + i.subtotal);
  double get _domicilio => _esDomicilio && _cobrarDomicilio ? _valorDomicilioPedido : 0;
  double get _total => _subtotal + _domicilio;

  void _abrirCarritoEnSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, scrollController) => StatefulBuilder(
          builder: (context, setLocalState) => _CarritoPanel(
            items: _items,
            subtotal: _subtotal,
            domicilio: _domicilio,
            total: _total,
            esDomicilio: _esDomicilio,
            scrollController: scrollController,
            onEditar: (item) async {
              await _editarItem(item);
              setLocalState(() {});
            },
            onEliminar: (item) async {
              await _eliminarItem(item);
              setLocalState(() {});
            },
            onCerrarPedido: () {
              Navigator.pop(sheetContext);
              _cerrarPedidoDesdeDetalle();
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        elevation: 0,
        title: Row(
          children: [
            if (_numeroTurno > 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  codigoTurnoDesde(_numeroTurno),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                widget.titulo,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ),
          ],
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) {
              if (value == 'cerrar') {
                _cerrarPedidoDesdeDetalle();
              } else if (value == 'cancelar') {
                _cancelarPedidoDesdeDetalle();
              } else if (value == 'domicilio') {
                _mostrarModalDomicilio();
              } else if (value == 'ticket') {
                _verTicketActual();
              } else if (value == 'reabrir') {
                _reabrirPedidoDesdeDetalle();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'ticket',
                child: Text('Vista previa / imprimir ticket'),
              ),
              const PopupMenuItem<String>(
                value: 'domicilio',
                child: Text('Domicilio'),
              ),
              if (_estadoPedido == 'abierto') ...const [
                PopupMenuItem<String>(
                  value: 'cerrar',
                  child: Text('Cerrar pedido'),
                ),
                PopupMenuItem<String>(
                  value: 'cancelar',
                  child: Text('Cancelar pedido'),
                ),
              ],
              if (_estadoPedido == 'cerrado' && _jornadaEstaAbierta)
                const PopupMenuItem<String>(
                  value: 'reabrir',
                  child: Row(
                    children: [
                      Icon(Icons.lock_open, color: AppColors.primary, size: 20),
                      SizedBox(width: 8),
                      Text('Reabrir pedido'),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator(color: AppColors.accent))
          : Column(
              children: [
                if (_estadoPedido == 'cerrado')
                  Container(
                    width: double.infinity,
                    color: Colors.amber.shade100,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, color: Colors.amber, size: 20),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Este pedido ya está CERRADO.',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Colors.brown,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (_jornadaEstaAbierta)
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                            ),
                            onPressed: _reabrirPedidoDesdeDetalle,
                            icon: const Icon(Icons.lock_open, size: 16),
                            label: const Text('Reabrir pedido'),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                final esEscritorio = constraints.maxWidth >= _anchoBreakpointEscritorio;

                final panelProductos = _ProductosPanel(
                  onAgregarRapido: _agregarRapido,
                  onQuitarRapido: _quitarRapido,
                  cantidadEnCarrito: _cantidadSimpleEnCarrito,
                  onPersonalizar: _personalizarYAgregar,
                );

                if (esEscritorio) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 3, child: panelProductos),
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: 360,
                        child: _CarritoPanel(
                          items: _items,
                          subtotal: _subtotal,
                          domicilio: _domicilio,
                          total: _total,
                          esDomicilio: _esDomicilio,
                          onEditar: _editarItem,
                          onEliminar: _eliminarItem,
                          onCerrarPedido: _cerrarPedidoDesdeDetalle,
                        ),
                      ),
                    ],
                  );
                }

                return Stack(
                  children: [
                    Positioned.fill(
                      bottom: 64,
                      child: panelProductos,
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: _BarraCarritoInferior(
                        cantidadItems: _items.fold(0, (s, i) => s + i.cantidad),
                        total: _total,
                        onTap: _abrirCarritoEnSheet,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BarraCarritoInferior extends StatelessWidget {
  final int cantidadItems;
  final double total;
  final VoidCallback onTap;

  const _BarraCarritoInferior({
    required this.cantidadItems,
    required this.total,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Material(
        color: AppColors.primary,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                const Icon(Icons.shopping_cart, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Text(
                  cantidadItems == 0
                      ? 'Carrito vacío'
                      : '$cantidadItems producto(s) · ${_formatMoney(total)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.keyboard_arrow_up, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CarritoPanel extends StatelessWidget {
  final List<ItemPedido> items;
  final double subtotal;
  final double domicilio;
  final double total;
  final bool esDomicilio;
  final ScrollController? scrollController;
  final Future<void> Function(ItemPedido item) onEditar;
  final Future<void> Function(ItemPedido item) onEliminar;
  final VoidCallback onCerrarPedido;

  const _CarritoPanel({
    required this.items,
    required this.subtotal,
    required this.domicilio,
    required this.total,
    required this.esDomicilio,
    required this.onEditar,
    required this.onEliminar,
    required this.onCerrarPedido,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            'Pedido (${items.length})',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Text(
                    'Aún no hay productos en el pedido.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                )
              : ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, index) {
                    final item = items[index];
                    return Card(
                      elevation: 0,
                      color: AppColors.surface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.nombreProducto,
                                    style: const TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                  Text(
                                    '${item.cantidad} x ${_formatMoney(item.precio)}',
                                    style: const TextStyle(
                                        color: AppColors.textMuted, fontSize: 12),
                                  ),
                                  if (item.adicionales.isNotEmpty)
                                    Text(
                                      '+ ${item.adicionales.join(', ')}',
                                      style: const TextStyle(
                                          color: AppColors.textMuted, fontSize: 12),
                                    ),
                                  if (item.nota.trim().isNotEmpty)
                                    Text(
                                      'Nota: ${item.nota.trim()}',
                                      style: const TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 12,
                                          fontStyle: FontStyle.italic),
                                    ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  _formatMoney(item.subtotal),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700, color: AppColors.primary),
                                ),
                                Row(
                                  children: [
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(Icons.edit_outlined, size: 18),
                                      onPressed: () => onEditar(item),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(Icons.delete_outline,
                                          size: 18, color: AppColors.error),
                                      onPressed: () => onEliminar(item),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.surface, width: 2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Subtotal: ${_formatMoney(subtotal)}'),
                  if (esDomicilio) ...[
                    const SizedBox(width: 12),
                    Text('Domicilio: ${_formatMoney(domicilio)}'),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: items.isEmpty ? null : onCerrarPedido,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: Text(
                  'Cerrar pedido · ${_formatMoney(total)}',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProductosPanel extends ConsumerStatefulWidget {
  final void Function(Producto) onAgregarRapido;
  final void Function(Producto) onQuitarRapido;
  final int Function(Producto) cantidadEnCarrito;
  final Future<void> Function(Producto, List<String>) onPersonalizar;

  const _ProductosPanel({
    required this.onAgregarRapido,
    required this.onQuitarRapido,
    required this.cantidadEnCarrito,
    required this.onPersonalizar,
  });

  @override
  ConsumerState<_ProductosPanel> createState() => _ProductosPanelState();
}

class _ProductosPanelState extends ConsumerState<_ProductosPanel> {
  String _query = '';
  final dbi.AppDatabase _db = sl<dbi.AppDatabase>();
  Map<int, List<String>> _etiquetasPorCategoria = const {};

  @override
  void initState() {
    super.initState();
    _cargarEtiquetasPorCategoria();
  }

  Future<void> _cargarEtiquetasPorCategoria() async {
    await _db.customStatement('''
      CREATE TABLE IF NOT EXISTS categoria_etiquetas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        categoria_id INTEGER NOT NULL,
        nombre TEXT NOT NULL,
        activa INTEGER NOT NULL DEFAULT 1
      )
    ''');

    final rows = await _db.customSelect(
      '''
      SELECT categoria_id, nombre
      FROM categoria_etiquetas
      WHERE activa = 1
      ORDER BY id ASC
      ''',
    ).get();

    final map = <int, List<String>>{};
    for (final row in rows) {
      final data = row.data;
      final categoriaId = (data['categoria_id'] as int?) ?? 0;
      final nombre = ((data['nombre'] as String?) ?? '').trim();
      if (categoriaId <= 0 || nombre.isEmpty) continue;
      map.putIfAbsent(categoriaId, () => []).add(nombre);
    }

    if (!mounted) return;
    setState(() => _etiquetasPorCategoria = map);
  }

  @override
  Widget build(BuildContext context) {
    final categoriasAsync = ref.watch(categoriasProvider);
    final catSelec = ref.watch(categoriaSeleccionadaProvider);

    return Column(
      children: [
        const SizedBox(height: 8),
        categoriasAsync.when(
          loading: () => const SizedBox(),
          error: (e, _) => const SizedBox(),
          data: (cats) => SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: cats.map((c) {
                final sel = catSelec == c.id;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(c.nombre),
                    selected: sel,
                    onSelected: (_) => ref
                        .read(categoriaSeleccionadaProvider.notifier)
                        .state = sel ? null : c.id,
                    selectedColor: AppColors.accent,
                    labelStyle: TextStyle(
                      color: sel ? Colors.white : AppColors.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                    backgroundColor: AppColors.surface,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    side: BorderSide.none,
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Buscar producto y tocar para agregar',
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _ProductosLista(
            categoriaId: catSelec,
            query: _query,
            etiquetasPorCategoria: _etiquetasPorCategoria,
            onAgregarRapido: widget.onAgregarRapido,
            onQuitarRapido: widget.onQuitarRapido,
            cantidadEnCarrito: widget.cantidadEnCarrito,
            onPersonalizar: widget.onPersonalizar,
          ),
        ),
      ],
    );
  }
}

class _ProductosLista extends ConsumerWidget {
  final int? categoriaId;
  final String query;
  final Map<int, List<String>> etiquetasPorCategoria;
  final void Function(Producto) onAgregarRapido;
  final void Function(Producto) onQuitarRapido;
  final int Function(Producto) cantidadEnCarrito;
  final Future<void> Function(Producto, List<String>) onPersonalizar;

  const _ProductosLista({
    required this.categoriaId,
    required this.query,
    required this.etiquetasPorCategoria,
    required this.onAgregarRapido,
    required this.onQuitarRapido,
    required this.cantidadEnCarrito,
    required this.onPersonalizar,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final productosAsync = categoriaId != null
        ? ref.watch(productosPorCategoriaProvider(categoriaId!))
        : ref.watch(productosProvider);

    return productosAsync.when(
      loading: () => const Center(child: CircularProgressIndicator(color: AppColors.accent)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (productos) {
        final q = query.trim().toLowerCase();
        final filtrados = q.isEmpty
            ? productos
            : productos.where((p) => p.nombre.toLowerCase().contains(q)).toList();

        if (filtrados.isEmpty) {
          return const Center(
            child: Text('Sin productos', style: TextStyle(color: AppColors.textMuted)),
          );
        }

        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 320,
            mainAxisExtent: 126,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemCount: filtrados.length,
          itemBuilder: (_, i) {
            final producto = filtrados[i];
            final etiquetas = etiquetasPorCategoria[producto.categoria.id] ?? const [];
            return _ProductoTileRapido(
              producto: producto,
              cantidad: cantidadEnCarrito(producto),
              onAgregarRapido: () => onAgregarRapido(producto),
              onQuitarRapido: () => onQuitarRapido(producto),
              onPersonalizar: () => onPersonalizar(producto, etiquetas),
            );
          },
        );
      },
    );
  }
}

class _ProductoTileRapido extends StatelessWidget {
  final Producto producto;
  final int cantidad;
  final VoidCallback onAgregarRapido;
  final VoidCallback onQuitarRapido;
  final VoidCallback onPersonalizar;

  const _ProductoTileRapido({
    required this.producto,
    required this.cantidad,
    required this.onAgregarRapido,
    required this.onQuitarRapido,
    required this.onPersonalizar,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPersonalizar,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      producto.nombre,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (producto.descripcion.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        producto.descripcion,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      _formatMoney(producto.precio),
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13.5, color: AppColors.accent),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _BotonRedondo(
                    icon: Icons.remove,
                    habilitado: cantidad > 0,
                    color: AppColors.textMuted,
                    onTap: onQuitarRapido,
                  ),
                  SizedBox(
                    width: 26,
                    child: Text(
                      '$cantidad',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  _BotonRedondo(
                    icon: Icons.add,
                    habilitado: true,
                    color: AppColors.accent,
                    onTap: onAgregarRapido,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BotonRedondo extends StatelessWidget {
  final IconData icon;
  final bool habilitado;
  final Color color;
  final VoidCallback onTap;

  const _BotonRedondo({
    required this.icon,
    required this.habilitado,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: habilitado ? color : AppColors.textMuted.withValues(alpha: 0.25),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: habilitado ? onTap : null,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, color: Colors.white, size: 16),
        ),
      ),
    );
  }
}
