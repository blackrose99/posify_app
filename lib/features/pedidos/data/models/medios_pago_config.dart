import 'dart:convert';

/// Representa una cuenta o canal para recibir transferencias (ej. Nequi, Daviplata, Bre-B, etc.)
class CuentaTransferencia {
  final String id;
  final String banco; // Ej: Nequi, Daviplata, Bre-B, Bancolombia, etc.
  final String numero; // Ej: 300 123 4567, 012-345678-90, llave, etc.
  final String titular; // Opcional
  final bool activa;

  const CuentaTransferencia({
    required this.id,
    required this.banco,
    required this.numero,
    this.titular = '',
    this.activa = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'banco': banco,
        'numero': numero,
        'titular': titular,
        'activa': activa,
      };

  factory CuentaTransferencia.fromJson(Map<String, dynamic> json) =>
      CuentaTransferencia(
        id: (json['id'] as String?) ?? '',
        banco: (json['banco'] as String?) ?? '',
        numero: (json['numero'] as String?) ?? '',
        titular: (json['titular'] as String?) ?? '',
        activa: (json['activa'] as bool?) ?? true,
      );

  CuentaTransferencia copyWith({
    String? id,
    String? banco,
    String? numero,
    String? titular,
    bool? activa,
  }) =>
      CuentaTransferencia(
        id: id ?? this.id,
        banco: banco ?? this.banco,
        numero: numero ?? this.numero,
        titular: titular ?? this.titular,
        activa: activa ?? this.activa,
      );
}

/// Configuración parametrizable de medios de pago para cobro y pie de factura.
class MediosPagoConfig {
  final bool efectivoHabilitado;
  final bool transferenciaHabilitada;
  final bool mostrarEnTicket;
  final String notaAdicional;
  final List<CuentaTransferencia> cuentas;

  const MediosPagoConfig({
    this.efectivoHabilitado = true,
    this.transferenciaHabilitada = true,
    this.mostrarEnTicket = true,
    this.notaAdicional = '',
    this.cuentas = const [],
  });

  Map<String, dynamic> toJson() => {
        'efectivoHabilitado': efectivoHabilitado,
        'transferenciaHabilitada': transferenciaHabilitada,
        'mostrarEnTicket': mostrarEnTicket,
        'notaAdicional': notaAdicional,
        'cuentas': cuentas.map((c) => c.toJson()).toList(),
      };

  factory MediosPagoConfig.fromJson(Map<String, dynamic> json) {
    final list = (json['cuentas'] as List<dynamic>?) ?? [];
    return MediosPagoConfig(
      efectivoHabilitado: (json['efectivoHabilitado'] as bool?) ?? true,
      transferenciaHabilitada:
          (json['transferenciaHabilitada'] as bool?) ?? true,
      mostrarEnTicket: (json['mostrarEnTicket'] as bool?) ?? true,
      notaAdicional: (json['notaAdicional'] as String?) ?? '',
      cuentas: list
          .map((item) =>
              CuentaTransferencia.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  factory MediosPagoConfig.fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return MediosPagoConfig.porDefecto();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return MediosPagoConfig.fromJson(decoded);
      }
    } catch (_) {}
    return MediosPagoConfig.porDefecto();
  }

  String toJsonString() => jsonEncode(toJson());

  static MediosPagoConfig porDefecto() => const MediosPagoConfig(
        efectivoHabilitado: true,
        transferenciaHabilitada: true,
        mostrarEnTicket: true,
        notaAdicional: '',
        cuentas: [
          CuentaTransferencia(
            id: '1',
            banco: 'Nequi',
            numero: '300 000 0000',
            titular: '',
            activa: true,
          ),
          CuentaTransferencia(
            id: '2',
            banco: 'Daviplata',
            numero: '300 000 0000',
            titular: '',
            activa: true,
          ),
          CuentaTransferencia(
            id: '3',
            banco: 'Bre-B',
            numero: '300 000 0000',
            titular: '',
            activa: true,
          ),
        ],
      );

  MediosPagoConfig copyWith({
    bool? efectivoHabilitado,
    bool? transferenciaHabilitada,
    bool? mostrarEnTicket,
    String? notaAdicional,
    List<CuentaTransferencia>? cuentas,
  }) {
    return MediosPagoConfig(
      efectivoHabilitado: efectivoHabilitado ?? this.efectivoHabilitado,
      transferenciaHabilitada:
          transferenciaHabilitada ?? this.transferenciaHabilitada,
      mostrarEnTicket: mostrarEnTicket ?? this.mostrarEnTicket,
      notaAdicional: notaAdicional ?? this.notaAdicional,
      cuentas: cuentas ?? this.cuentas,
    );
  }

  /// Retorna las líneas formateadas listas para incluir en el footer del ticket o PDF.
  List<String> get lineasParaTicket {
    if (!mostrarEnTicket) return const [];
    final lineas = <String>[];
    for (final c in cuentas) {
      if (c.activa && c.numero.trim().isNotEmpty) {
        final titularText =
            c.titular.trim().isNotEmpty ? ' (${c.titular.trim()})' : '';
        lineas.add('${c.banco.trim()}: ${c.numero.trim()}$titularText');
      }
    }
    if (notaAdicional.trim().isNotEmpty) {
      lineas.add(notaAdicional.trim());
    }
    return lineas;
  }
}

