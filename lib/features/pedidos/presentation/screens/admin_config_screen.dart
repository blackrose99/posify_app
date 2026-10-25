import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/services/data_backup_service.dart';
import '../../../../core/utils/money_formatter.dart';
import '../../../../database/app_database.dart';
import '../../../../injection_container.dart';
import 'config_categorias_screen.dart';
import 'config_impresoras_screen.dart';
import 'config_meseros_screen.dart';
import 'config_productos_screen.dart';

class AdminConfigScreen extends StatefulWidget {
  const AdminConfigScreen({super.key});

  @override
  State<AdminConfigScreen> createState() => _AdminConfigScreenState();
}

class _AdminConfigScreenState extends State<AdminConfigScreen> {
  final AppDatabase _db = sl<AppDatabase>();
  late final DataBackupService _backupService = DataBackupService(_db);

  bool _loading = true;
  String _valorDomicilio = '5000';
  bool _backupRunning = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _upsertConfig(String clave, String valor) async {
    final actual = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals(clave)))
        .getSingleOrNull();

    if (actual == null) {
      await _db.into(_db.configuracion).insert(
            ConfiguracionCompanion.insert(clave: clave, valor: valor),
          );
      return;
    }

    await (_db.update(_db.configuracion)..where((c) => c.clave.equals(clave)))
        .write(ConfiguracionCompanion(valor: drift.Value(valor)));
  }

  Future<void> _cargar() async {
    setState(() => _loading = true);

    await _upsertConfig('valor_domicilio', '5000');

    final domicilio = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals('valor_domicilio')))
        .getSingle();

    if (!mounted) return;
    setState(() {
      _valorDomicilio = domicilio.valor;
      _loading = false;
    });
  }

  Future<void> _editarValorDomicilio() async {
    final ctrl = TextEditingController(text: _valorDomicilio);

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Costo de envío a domicilio'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Valor en pesos'),
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

    final valor = double.tryParse(ctrl.text.trim());
    if (valor == null || valor < 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ingresa un valor válido.')),
      );
      return;
    }

    await _upsertConfig('valor_domicilio', valor.toStringAsFixed(0));
    await _cargar();
  }

  Future<void> _cargarDatosPrueba() async {
    await _db.asegurarDatosInicialesDePrueba(forzar: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Datos iniciales de prueba (productos, categorías, meseros y etiquetas) cargados correctamente.',
        ),
      ),
    );
  }

  Future<void> _exportarRespaldo() async {
    if (_backupRunning) return;
    setState(() => _backupRunning = true);

    try {
      final file = await _backupService.exportToFile();
      await Share.shareXFiles(
        [XFile(file.path)],
        text:
            'Respaldo completo de Barril App. Guarda este archivo para restaurar datos en otro dispositivo.',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Respaldo generado en ${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo exportar el respaldo: $e')),
      );
    } finally {
      if (mounted) setState(() => _backupRunning = false);
    }
  }

  Future<void> _restaurarRespaldo() async {
    if (_backupRunning) return;

    final confirmado = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restaurar respaldo'),
        content: const Text(
          'Esto reemplazará los datos actuales por los del archivo seleccionado. Continúa solo si ya tienes una copia reciente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continuar'),
          ),
        ],
      ),
    );

    if (confirmado != true) return;

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      dialogTitle: 'Selecciona el respaldo JSON',
    );

    final path = result?.files.single.path;
    if (path == null) return;

    setState(() => _backupRunning = true);
    try {
      final content = await File(path).readAsString();
      await _backupService.restoreFromJson(content);
      await _cargar();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Respaldo restaurado correctamente.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo restaurar el respaldo: $e')),
      );
    } finally {
      if (mounted) setState(() => _backupRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Configuración administrativa',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.delivery_dining_outlined),
                    title: const Text('Costo de envío a domicilio'),
                    subtitle: Text(
                        formatMoney(double.tryParse(_valorDomicilio) ?? 0)),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: _editarValorDomicilio,
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.backup_outlined),
                    title: const Text('Respaldo y sincronización'),
                    subtitle: const Text(
                        'Exporta la base completa y restáurala en otro teléfono'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _backupRunning
                        ? null
                        : () => showModalBottomSheet<void>(
                              context: context,
                              showDragHandle: true,
                              builder: (sheetContext) => SafeArea(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      const Text(
                                        'Respaldo de datos',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        'El archivo JSON incluye configuración, categorías, productos, mesas, pedidos, facturas y adicionales. Puedes guardarlo en Drive o en una carpeta del teléfono.',
                                      ),
                                      const SizedBox(height: 16),
                                      FilledButton.icon(
                                        onPressed: _exportarRespaldo,
                                        icon: const Icon(Icons.upload_file),
                                        label: const Text('Exportar respaldo'),
                                      ),
                                      const SizedBox(height: 8),
                                      OutlinedButton.icon(
                                        onPressed: _restaurarRespaldo,
                                        icon: const Icon(Icons.download),
                                        label: const Text(
                                            'Restaurar desde archivo'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.category_outlined),
                    title: const Text('Administrar categorías'),
                    subtitle: const Text('Crear, editar, eliminar y etiquetas'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ConfigCategoriasScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: const Text('Administrar productos'),
                    subtitle: const Text('Crear, editar y eliminar productos'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ConfigProductosScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.print_outlined),
                    title: const Text('Administrar impresoras POS'),
                    subtitle: const Text(
                        'Agregar, eliminar y seleccionar predeterminada'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ConfigImpresorasScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.people_alt_outlined),
                    title: const Text('Administrar meseros'),
                    subtitle: const Text('Crear, editar y eliminar meseros'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ConfigMeserosScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(
                      Icons.science_outlined,
                      color: AppColors.nuevoPedido,
                    ),
                    title: const Text('Cargar datos iniciales de prueba'),
                    subtitle: const Text(
                      'Asegura al menos 10 productos de prueba, categorías, meseros y etiquetas',
                    ),
                    trailing: const Icon(Icons.playlist_add_check_rounded),
                    onTap: _cargarDatosPrueba,
                  ),
                ),
              ],
            ),
    );
  }
}
