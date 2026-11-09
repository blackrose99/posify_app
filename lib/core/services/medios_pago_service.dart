import 'package:drift/drift.dart' as drift;
import '../../database/app_database.dart';
import '../../features/pedidos/data/models/medios_pago_config.dart';

class MediosPagoService {
  final AppDatabase _db;
  static const String _claveConfig = 'medios_pago_config';

  MediosPagoService(this._db);

  /// Obtiene la configuración de medios de pago guardada en la base de datos,
  /// o retorna la configuración por defecto si aún no ha sido parametrizada.
  Future<MediosPagoConfig> obtenerConfiguracion() async {
    final row = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals(_claveConfig)))
        .getSingleOrNull();

    if (row == null) {
      final configDefault = MediosPagoConfig.porDefecto();
      await guardarConfiguracion(configDefault);
      return configDefault;
    }

    return MediosPagoConfig.fromJsonString(row.valor);
  }

  /// Guarda la configuración actualizada en la base de datos local.
  Future<void> guardarConfiguracion(MediosPagoConfig config) async {
    final raw = config.toJsonString();
    final row = await (_db.select(_db.configuracion)
          ..where((c) => c.clave.equals(_claveConfig)))
        .getSingleOrNull();

    if (row == null) {
      await _db.into(_db.configuracion).insert(
            ConfiguracionCompanion.insert(
              clave: _claveConfig,
              valor: raw,
            ),
          );
    } else {
      await (_db.update(_db.configuracion)
            ..where((c) => c.clave.equals(_claveConfig)))
          .write(ConfiguracionCompanion(valor: drift.Value(raw)));
    }
  }

  /// Retorna las líneas formateadas de transferencias configuradas para el footer del ticket.
  Future<List<String>> obtenerLineasTicket() async {
    final cfg = await obtenerConfiguracion();
    return cfg.lineasParaTicket;
  }
}

