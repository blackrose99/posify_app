import 'package:flutter/material.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/medios_pago_service.dart';
import '../../../../database/app_database.dart';
import '../../../../injection_container.dart';
import '../../data/models/medios_pago_config.dart';

class ConfigMediosPagoScreen extends StatefulWidget {
  const ConfigMediosPagoScreen({super.key});

  @override
  State<ConfigMediosPagoScreen> createState() => _ConfigMediosPagoScreenState();
}

class _ConfigMediosPagoScreenState extends State<ConfigMediosPagoScreen> {
  final MediosPagoService _service = MediosPagoService(sl<AppDatabase>());
  late MediosPagoConfig _config;
  bool _loading = true;
  final TextEditingController _notaController = TextEditingController();

  static const List<String> _entidadesSugeridas = [
    'Nequi',
    'Daviplata',
    'Bre-B',
    'Bancolombia',
    'Dale!',
    'Davivienda',
    'BBVA',
    'Banco de Bogotá',
    'Lulo Bank',
  ];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _notaController.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() => _loading = true);
    final cfg = await _service.obtenerConfiguracion();
    if (!mounted) return;
    setState(() {
      _config = cfg;
      _notaController.text = cfg.notaAdicional;
      _loading = false;
    });
  }

  Future<void> _guardarConfig(MediosPagoConfig nuevaConfig) async {
    setState(() => _config = nuevaConfig);
    await _service.guardarConfiguracion(nuevaConfig);
  }

  Future<void> _editarCuenta({CuentaTransferencia? cuenta}) async {
    final esNueva = cuenta == null;
    String bancoSeleccionado = cuenta?.banco ?? 'Nequi';
    final customBancoCtrl = TextEditingController(
      text: _entidadesSugeridas.contains(bancoSeleccionado)
          ? ''
          : bancoSeleccionado,
    );
    final numeroCtrl = TextEditingController(text: cuenta?.numero ?? '');
    final titularCtrl = TextEditingController(text: cuenta?.titular ?? '');

    final guardado = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final esOtroBanco = !_entidadesSugeridas.contains(bancoSeleccionado);
          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  esNueva ? Icons.add_card_rounded : Icons.edit_note_rounded,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 8),
                Text(esNueva ? 'Nueva cuenta' : 'Editar cuenta'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Entidad / Canal de transferencia:',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      ..._entidadesSugeridas.map((b) {
                        final sel = bancoSeleccionado == b;
                        return ChoiceChip(
                          label: Text(b),
                          selected: sel,
                          onSelected: (val) {
                            if (val) {
                              setDialogState(() {
                                bancoSeleccionado = b;
                              });
                            }
                          },
                        );
                      }),
                      ChoiceChip(
                        label: const Text('Otro...'),
                        selected: esOtroBanco,
                        onSelected: (val) {
                          if (val) {
                            setDialogState(() {
                              bancoSeleccionado = 'Otro';
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  if (esOtroBanco) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: customBancoCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Nombre de la entidad o billetera',
                        hintText: 'Ej. Scotiabank, Ualá, etc.',
                        isDense: true,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  TextField(
                    controller: numeroCtrl,
                    keyboardType: TextInputType.text,
                    decoration: const InputDecoration(
                      labelText: 'Número de celular, cuenta o llave *',
                      hintText: 'Ej. 300 123 4567 o Llave Bre-B',
                      prefixIcon: Icon(Icons.tag_rounded),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: titularCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Titular de la cuenta (opcional)',
                      hintText: 'Ej. Juan Pérez',
                      prefixIcon: Icon(Icons.person_outline_rounded),
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () {
                  final num = numeroCtrl.text.trim();
                  if (num.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Ingresa el número o llave de la cuenta'),
                      ),
                    );
                    return;
                  }
                  Navigator.pop(dialogCtx, true);
                },
                child: const Text('Guardar'),
              ),
            ],
          );
        },
      ),
    );

    if (guardado != true) return;

    final finalBanco = !_entidadesSugeridas.contains(bancoSeleccionado) &&
            customBancoCtrl.text.trim().isNotEmpty
        ? customBancoCtrl.text.trim()
        : bancoSeleccionado;

    final nuevasCuentas = List<CuentaTransferencia>.from(_config.cuentas);

    if (esNueva) {
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      nuevasCuentas.add(
        CuentaTransferencia(
          id: id,
          banco: finalBanco,
          numero: numeroCtrl.text.trim(),
          titular: titularCtrl.text.trim(),
          activa: true,
        ),
      );
    } else {
      final index = nuevasCuentas.indexWhere((c) => c.id == cuenta.id);
      if (index != -1) {
        nuevasCuentas[index] = cuenta.copyWith(
          banco: finalBanco,
          numero: numeroCtrl.text.trim(),
          titular: titularCtrl.text.trim(),
        );
      }
    }

    await _guardarConfig(_config.copyWith(cuentas: nuevasCuentas));
  }

  Future<void> _eliminarCuenta(CuentaTransferencia cuenta) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar cuenta'),
        content: Text(
          '¿Deseas eliminar la cuenta ${cuenta.banco} (${cuenta.numero}) de los medios de pago?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final nuevasCuentas = _config.cuentas.where((c) => c.id != cuenta.id).toList();
    await _guardarConfig(_config.copyWith(cuentas: nuevasCuentas));
  }

  Future<void> _restablecerDefecto() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restablecer medios de pago'),
        content: const Text(
          '¿Deseas restablecer los medios de pago por defecto (Efectivo y Transferencias Nequi, Daviplata, Bre-B)?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restablecer'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final defaultCfg = MediosPagoConfig.porDefecto();
    await _guardarConfig(defaultCfg);
    setState(() {
      _notaController.text = defaultCfg.notaAdicional;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Medios de pago',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            tooltip: 'Restablecer por defecto',
            icon: const Icon(Icons.restore_rounded),
            onPressed: _loading ? null : _restablecerDefecto,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Tarjeta informativa
                Card(
                  elevation: 0,
                  color: AppColors.primary.withValues(alpha: 0.08),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: AppColors.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          color: AppColors.primary,
                          size: 22,
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Parametriza aquí las formas de pago aceptadas. Al cobrar un pedido se consultará el medio de pago, y los datos de transferencias configurados saldrán automáticamente en el pie de la factura para el cliente.',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textPrimary,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Secciones de Medios Base (Efectivo y Transferencia)
                const Text(
                  'Medios de pago disponibles:',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(
                          Icons.payments_rounded,
                          color: Color(0xFF15803D),
                        ),
                        title: const Text(
                          'Efectivo',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: const Text('Pago manual en caja con dinero en físico'),
                        value: _config.efectivoHabilitado,
                        onChanged: (val) {
                          _guardarConfig(
                            _config.copyWith(efectivoHabilitado: val),
                          );
                        },
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        secondary: const Icon(
                          Icons.account_balance_wallet_rounded,
                          color: Color(0xFF0284C7),
                        ),
                        title: const Text(
                          'Transferencia electrónica',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: const Text(
                          'Pagos digitales vía Nequi, Daviplata, Bre-B, etc.',
                        ),
                        value: _config.transferenciaHabilitada,
                        onChanged: (val) {
                          _guardarConfig(
                            _config.copyWith(transferenciaHabilitada: val),
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Sección de configuración de Ticket Cliente
                const Text(
                  'Pie de factura (Factura de venta para cliente):',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        SwitchListTile(
                          secondary: const Icon(Icons.receipt_long_rounded),
                          title: const Text(
                            'Imprimir transferencias en factura',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: const Text(
                            'Incluye números de Nequi, Bre-B, Daviplata en el pie del ticket para que el cliente pague fácil',
                          ),
                          value: _config.mostrarEnTicket,
                          onChanged: (val) {
                            _guardarConfig(
                              _config.copyWith(mostrarEnTicket: val),
                            );
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          child: TextField(
                            controller: _notaController,
                            decoration: const InputDecoration(
                              labelText: 'Mensaje adicional en el pie del ticket (opcional)',
                              hintText: 'Ej. Enviar comprobante al WhatsApp 300 123 4567',
                              prefixIcon: Icon(Icons.chat_bubble_outline_rounded),
                              isDense: true,
                            ),
                            onChanged: (val) {
                              _guardarConfig(
                                _config.copyWith(notaAdicional: val.trim()),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Sección Cuentas y Llaves de Transferencia
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Cuentas y llaves para transferencias:',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    Text(
                      '${_config.cuentas.where((c) => c.activa).length} activa(s)',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                if (_config.cuentas.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          const Icon(
                            Icons.credit_card_off_rounded,
                            size: 44,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'No tienes cuentas de transferencia agregadas.',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Agrega cuentas como Nequi, Daviplata o Bre-B para que aparezcan al cobrar y en la factura del cliente.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 14),
                          FilledButton.icon(
                            onPressed: () => _editarCuenta(),
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Agregar primera cuenta'),
                          ),
                        ],
                      ),
                    ),
                  )
                else ...[
                  ..._config.cuentas.map((cuenta) {
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: cuenta.activa
                              ? AppColors.primary.withValues(alpha: 0.14)
                              : Colors.grey.withValues(alpha: 0.15),
                          child: Icon(
                            _obtenerIconoBanco(cuenta.banco),
                            color: cuenta.activa
                                ? AppColors.primary
                                : Colors.grey,
                            size: 20,
                          ),
                        ),
                        title: Row(
                          children: [
                            Text(
                              cuenta.banco,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 15,
                                color: cuenta.activa
                                    ? AppColors.textPrimary
                                    : AppColors.textMuted,
                              ),
                            ),
                            if (!cuenta.activa) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade200,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'Inactiva',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 2),
                            Text(
                              cuenta.numero,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: cuenta.activa
                                    ? const Color(0xFF0F172A)
                                    : AppColors.textMuted,
                              ),
                            ),
                            if (cuenta.titular.isNotEmpty)
                              Text(
                                'Titular: ${cuenta.titular}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textMuted,
                                ),
                              ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: cuenta.activa,
                              onChanged: (val) {
                                final nuevas = _config.cuentas.map((c) {
                                  if (c.id == cuenta.id) {
                                    return c.copyWith(activa: val);
                                  }
                                  return c;
                                }).toList();
                                _guardarConfig(
                                  _config.copyWith(cuentas: nuevas),
                                );
                              },
                            ),
                            PopupMenuButton<String>(
                              onSelected: (val) {
                                if (val == 'editar') {
                                  _editarCuenta(cuenta: cuenta);
                                } else if (val == 'eliminar') {
                                  _eliminarCuenta(cuenta);
                                }
                              },
                              itemBuilder: (ctx) => [
                                const PopupMenuItem(
                                  value: 'editar',
                                  child: Row(
                                    children: [
                                      Icon(Icons.edit_outlined, size: 18),
                                      SizedBox(width: 8),
                                      Text('Editar'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'eliminar',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.delete_outline_rounded,
                                        size: 18,
                                        color: AppColors.error,
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'Eliminar',
                                        style:
                                            TextStyle(color: AppColors.error),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => _editarCuenta(),
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    label: const Text(
                      'Agregar otra cuenta o llave',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
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

