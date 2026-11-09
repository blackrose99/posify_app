import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/utils/money_formatter.dart';
import 'package:barril_app/features/pedidos/data/models/medios_pago_config.dart';

class ResultadoCobroPedido {
  final String medioPago;
  final bool confirmado;

  const ResultadoCobroPedido({
    required this.medioPago,
    required this.confirmado,
  });
}

class DialogoCobrarPedido extends StatefulWidget {
  final String codigoTurno;
  final String referencia;
  final String cliente;
  final double total;
  final MediosPagoConfig config;

  const DialogoCobrarPedido({
    super.key,
    required this.codigoTurno,
    required this.referencia,
    required this.cliente,
    required this.total,
    required this.config,
  });

  static Future<ResultadoCobroPedido?> mostrar({
    required BuildContext context,
    required String codigoTurno,
    required String referencia,
    required String cliente,
    required double total,
    required MediosPagoConfig config,
  }) {
    return showDialog<ResultadoCobroPedido>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => DialogoCobrarPedido(
        codigoTurno: codigoTurno,
        referencia: referencia,
        cliente: cliente,
        total: total,
        config: config,
      ),
    );
  }

  @override
  State<DialogoCobrarPedido> createState() => _DialogoCobrarPedidoState();
}

class _DialogoCobrarPedidoState extends State<DialogoCobrarPedido> {
  late String _tipoPrincipal; // 'efectivo' o 'transferencia'
  String? _cuentaSeleccionadaId;

  @override
  void initState() {
    super.initState();
    if (widget.config.efectivoHabilitado) {
      _tipoPrincipal = 'efectivo';
    } else if (widget.config.transferenciaHabilitada) {
      _tipoPrincipal = 'transferencia';
    } else {
      _tipoPrincipal = 'efectivo';
    }

    final cuentasActivas =
        widget.config.cuentas.where((c) => c.activa).toList();
    if (cuentasActivas.isNotEmpty) {
      _cuentaSeleccionadaId = cuentasActivas.first.id;
    }
  }

  String get _medioPagoFinal {
    if (_tipoPrincipal == 'efectivo') {
      return 'Efectivo';
    }
    final cuenta = widget.config.cuentas
        .where((c) => c.id == _cuentaSeleccionadaId)
        .firstOrNull;
    if (cuenta != null) {
      return 'Transferencia (${cuenta.banco})';
    }
    return 'Transferencia';
  }

  @override
  Widget build(BuildContext context) {
    final cuentasActivas =
        widget.config.cuentas.where((c) => c.activa).toList();

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.cobrarCerrar.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.point_of_sale_rounded,
              color: AppColors.cobrarCerrar,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Cobrar y cerrar pedido',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Resumen de pedido y Total
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          widget.codigoTurno,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                      Flexible(
                        child: Text(
                          widget.referencia,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (widget.cliente.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Cliente: ${widget.cliente.trim()}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'TOTAL A COBRAR:',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textMuted,
                        ),
                      ),
                      Text(
                        formatMoney(widget.total),
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: AppColors.primaryDark,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Selector del Medio de Pago
            const Text(
              'Selecciona el medio de pago:',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),

            // Opciones principales: Efectivo vs Transferencia
            Row(
              children: [
                if (widget.config.efectivoHabilitado)
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        setState(() => _tipoPrincipal = 'efectivo');
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 12),
                        decoration: BoxDecoration(
                          color: _tipoPrincipal == 'efectivo'
                              ? const Color(0xFF15803D).withValues(alpha: 0.12)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _tipoPrincipal == 'efectivo'
                                ? const Color(0xFF15803D)
                                : Colors.grey.shade300,
                            width: _tipoPrincipal == 'efectivo' ? 2 : 1,
                          ),
                        ),
                        child: Column(
                          children: [
                            Icon(
                              Icons.payments_rounded,
                              color: _tipoPrincipal == 'efectivo'
                                  ? const Color(0xFF15803D)
                                  : Colors.grey.shade600,
                              size: 26,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Efectivo',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                                color: _tipoPrincipal == 'efectivo'
                                    ? const Color(0xFF15803D)
                                    : AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (widget.config.efectivoHabilitado &&
                    widget.config.transferenciaHabilitada)
                  const SizedBox(width: 10),
                if (widget.config.transferenciaHabilitada)
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        setState(() => _tipoPrincipal = 'transferencia');
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 12),
                        decoration: BoxDecoration(
                          color: _tipoPrincipal == 'transferencia'
                              ? const Color(0xFF0284C7).withValues(alpha: 0.12)
                              : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _tipoPrincipal == 'transferencia'
                                ? const Color(0xFF0284C7)
                                : Colors.grey.shade300,
                            width: _tipoPrincipal == 'transferencia' ? 2 : 1,
                          ),
                        ),
                        child: Column(
                          children: [
                            Icon(
                              Icons.account_balance_wallet_rounded,
                              color: _tipoPrincipal == 'transferencia'
                                  ? const Color(0xFF0284C7)
                                  : Colors.grey.shade600,
                              size: 26,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Transferencia',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                                color: _tipoPrincipal == 'transferencia'
                                    ? const Color(0xFF0284C7)
                                    : AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),

            // Si es transferencia, listar las cuentas/canales configurados (Nequi, Daviplata, Bre-B, etc.)
            if (_tipoPrincipal == 'transferencia') ...[
              const SizedBox(height: 14),
              const Text(
                'Canal / Cuenta de transferencia:',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              if (cuentasActivas.isEmpty)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.shade300),
                  ),
                  child: const Text(
                    'No hay cuentas configuradas. Se registrará como transferencia general.',
                    style: TextStyle(fontSize: 12),
                  ),
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ...cuentasActivas.map((c) {
                      final sel = _cuentaSeleccionadaId == c.id;
                      return ChoiceChip(
                        avatar: Icon(
                          _obtenerIconoBanco(c.banco),
                          size: 16,
                          color: sel ? Colors.white : AppColors.primary,
                        ),
                        label: Text(
                          '${c.banco} (${c.numero})',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight:
                                sel ? FontWeight.w800 : FontWeight.w600,
                            color: sel ? Colors.white : AppColors.textPrimary,
                          ),
                        ),
                        selected: sel,
                        selectedColor: AppColors.primary,
                        onSelected: (val) {
                          if (val) {
                            setState(() => _cuentaSeleccionadaId = c.id);
                          }
                        },
                      );
                    }),
                    ChoiceChip(
                      label: const Text('Otra transferencia'),
                      selected: _cuentaSeleccionadaId == null,
                      onSelected: (val) {
                        if (val) {
                          setState(() => _cuentaSeleccionadaId = null);
                        }
                      },
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            const ResultadoCobroPedido(medioPago: '', confirmado: false),
          ),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.cobrarCerrar,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          ),
          onPressed: () {
            Navigator.pop(
              context,
              ResultadoCobroPedido(
                medioPago: _medioPagoFinal,
                confirmado: true,
              ),
            );
          },
          icon: const Icon(Icons.check_circle_rounded, size: 18),
          label: const Text(
            'Confirmar cobro y cerrar',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }

  IconData _obtenerIconoBanco(String banco) {
    final b = banco.toLowerCase();
    if (b.contains('nequi') || b.contains('daviplata') || b.contains('dale')) {
      return Icons.phone_android_rounded;
    }
    if (b.contains('bre-b') || b.contains('llave')) {
      return Icons.vpn_key_rounded;
    }
    return Icons.account_balance_rounded;
  }
}
