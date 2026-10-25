import 'package:flutter/material.dart';

class AppColors {
  // Paleta verde alineada con el ícono de la app (POSify).
  static const Color primary = Color(0xFF146C2E);
  static const Color primaryDark = Color(0xFF0D5022);
  static const Color accent = Color(0xFF1E9E4A);
  static const Color accentLight = Color(0xFF4CC172);
  static const Color background = Color(0xFFFFFFFF);
  static const Color surface = Color(0xFFF1F8F2);
  static const Color textPrimary = Color(0xFF1B1B1B);
  static const Color textMuted = Color(0xFF888780);

  // Estados semánticos: distintos del verde de marca para no confundirse con él.
  static const Color success = Color(0xFF00897B);
  static const Color warning = Color(0xFFD97706);
  static const Color error = Color(0xFFE24B4A);

  // Colores representativos para acciones y botones clave
  static const Color nuevoPedido = Color(0xFFEA580C); // Naranja vibrante llamativo
  static const Color nuevoPedidoLight = Color(0xFFFFF7ED);
  static const Color agregarProductos = Color(0xFF16A34A); // Verde acción principal
  static const Color comandaCocina = Color(0xFFD97706); // Ámbar cocina
  static const Color verTicket = Color(0xFF0284C7); // Azul ticket/información
  static const Color editarDatos = Color(0xFF6366F1); // Índigo edición
  static const Color cobrarCerrar = Color(0xFF0D9488); // Teal cobro/cierre

  // Verde claro = mesa libre/disponible, ámbar claro = mesa ocupada (antes
  // ambos eran azules casi idénticos y no se distinguían de un vistazo).
  static const Color mesaLibre = Color(0xFFE3F4E8);
  static const Color mesaOcupada = Color(0xFFFCEBD5);
}
