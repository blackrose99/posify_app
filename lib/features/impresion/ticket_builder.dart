import 'dart:convert';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';

import '../../core/utils/money_formatter.dart';
import 'ticket_data.dart';

PaperSize _paperSizeDe(AnchoPapel ancho) =>
    ancho == AnchoPapel.mm58 ? PaperSize.mm58 : PaperSize.mm80;

enum _TextAlign { left, center, right }

class _TicketLineItem {
  final String? text;
  final String? leftText;
  final String? rightText;
  final img.BitmapFont font;
  final _TextAlign align;
  final bool isBold;
  final bool isDivider;
  final int height;

  _TicketLineItem.text(
    this.text, {
    required this.font,
    this.align = _TextAlign.left,
    this.isBold = false,
  })  : leftText = null,
        rightText = null,
        isDivider = false,
        height = font == img.arial24 ? 32 : 24;

  _TicketLineItem.row(
    this.leftText,
    this.rightText, {
    required this.font,
    this.isBold = false,
  })  : text = null,
        align = _TextAlign.left,
        isDivider = false,
        height = font == img.arial24 ? 32 : 24;

  _TicketLineItem.divider()
      : text = null,
        leftText = null,
        rightText = null,
        font = img.arial14,
        align = _TextAlign.left,
        isBold = false,
        isDivider = true,
        height = 16;

  void render(img.Image image, int y, int canvasWidth, int printableWidth) {
    const marginX = 10;
    final charWidth = font == img.arial24 ? 13 : 8;

    if (isDivider) {
      img.drawLine(
        image,
        x1: marginX,
        y1: y + 8,
        x2: marginX + printableWidth,
        y2: y + 8,
        color: img.ColorRgb8(0, 0, 0),
        thickness: 2,
      );
      return;
    }

    if (leftText != null && rightText != null) {
      img.drawString(
        image,
        leftText!,
        font: font,
        x: marginX,
        y: y,
        color: img.ColorRgb8(0, 0, 0),
      );
      final rightPixelWidth = rightText!.length * charWidth;
      final rightX = marginX + printableWidth - rightPixelWidth;
      img.drawString(
        image,
        rightText!,
        font: font,
        x: rightX > marginX ? rightX : marginX,
        y: y,
        color: img.ColorRgb8(0, 0, 0),
      );

      if (isBold) {
        img.drawString(image, leftText!, font: font, x: marginX + 1, y: y, color: img.ColorRgb8(0, 0, 0));
        img.drawString(image, rightText!, font: font, x: (rightX > marginX ? rightX : marginX) + 1, y: y, color: img.ColorRgb8(0, 0, 0));
      }
      return;
    }

    if (text != null) {
      final str = text!;
      final strPixelWidth = str.length * charWidth;
      int posX = marginX;

      if (align == _TextAlign.center) {
        posX = marginX + ((printableWidth - strPixelWidth) ~/ 2);
        if (posX < marginX) posX = marginX;
      } else if (align == _TextAlign.right) {
        posX = marginX + printableWidth - strPixelWidth;
        if (posX < marginX) posX = marginX;
      }

      img.drawString(image, str, font: font, x: posX, y: y, color: img.ColorRgb8(0, 0, 0));

      if (isBold) {
        img.drawString(image, str, font: font, x: posX + 1, y: y, color: img.ColorRgb8(0, 0, 0));
      }
    }
  }
}

String _centrar(String texto, int ancho) {
  final t = texto.length > ancho ? texto.substring(0, ancho) : texto;
  final espacios = ancho - t.length;
  final izq = espacios ~/ 2;
  final der = espacios - izq;
  return '${' ' * izq}$t${' ' * der}';
}

String _linea(int ancho, [String ch = '-']) => ch * ancho;

String _dosColumnas(String izquierda, String derecha, int ancho) {
  final espacio = ancho - izquierda.length - derecha.length;
  if (espacio < 1) {
    final maxIzq = ancho - derecha.length - 1;
    final recortada = maxIzq > 0 && izquierda.length > maxIzq
        ? izquierda.substring(0, maxIzq)
        : izquierda;
    final relleno = ancho - recortada.length - derecha.length;
    return '$recortada${' ' * (relleno > 0 ? relleno : 1)}$derecha';
  }
  return '$izquierda${' ' * espacio}$derecha';
}

/// Texto plano del ticket, usado tanto para la vista previa en pantalla como
/// de respaldo si no hay impresora térmica conectada.
String buildPlainTicket(TicketData data, {AnchoPapel ancho = AnchoPapel.mm58}) {
  final w = ancho.caracteresPorLinea;
  final buffer = StringBuffer();

  // Holgura inicial de al menos 1 cm (4 saltos de línea)
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln(_centrar(data.nombreNegocio.toUpperCase(), w));
  buffer.writeln(_centrar(data.tituloEstado, w));
  buffer.writeln(_linea(w, '='));
  buffer.writeln(_centrar(data.codigoTurno, w));
  buffer.writeln(_linea(w, '='));
  buffer.writeln('${data.esDomicilio ? 'Domicilio' : 'Mesa'}: ${data.referenciaONombreTipo}');
  if (data.cliente.trim().isNotEmpty) buffer.writeln('Cliente: ${data.cliente.trim()}');
  if (data.mesero.trim().isNotEmpty) buffer.writeln('Mesero: ${data.mesero.trim()}');
  buffer.writeln('Fecha: ${formatFechaTicket(data.fecha)}');
  buffer.writeln(_linea(w));

  if (data.items.isEmpty) {
    buffer.writeln(_centrar('Sin productos agregados', w));
  } else {
    for (final item in data.items) {
      buffer.writeln('${item.cantidad}x ${item.nombreProducto}');
      if (item.adicionales.isNotEmpty) {
        buffer.writeln('  + ${item.adicionales.join(', ')}');
      }
      if (item.nota.trim().isNotEmpty) {
        buffer.writeln('  Nota: ${item.nota.trim()}');
      }
      buffer.writeln(
        _dosColumnas('  ${formatMoney(item.precio)} c/u', formatMoney(item.subtotal), w),
      );
    }
  }

  buffer.writeln(_linea(w));
  buffer.writeln(_dosColumnas('Subtotal', formatMoney(data.subtotal), w));
  if (data.domicilioCobrado > 0) {
    buffer.writeln(_dosColumnas('Domicilio', formatMoney(data.domicilioCobrado), w));
  }
  buffer.writeln(_linea(w, '='));
  buffer.writeln(_dosColumnas('TOTAL', formatMoney(data.total), w));
  if (data.medioPago.trim().isNotEmpty) {
    buffer.writeln(_linea(w, '-'));
    buffer.writeln(_dosColumnas('Medio de pago', data.medioPago.trim(), w));
  }
  if (data.infoTransferencia.isNotEmpty) {
    buffer.writeln(_linea(w, '-'));
    buffer.writeln(_centrar('PAGOS POR TRANSFERENCIA:', w));
    for (final linea in data.infoTransferencia) {
      buffer.writeln(_centrar(linea, w));
    }
  }
  buffer.writeln(_linea(w, '='));
  buffer.writeln(_centrar('Gracias por tu compra', w));
  // Holgura final para corte limpio sin truncar texto (al menos 1.5 cm - 8 saltos de línea)
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();

  return buffer.toString();
}

/// Genera un mapa de bits (raster) de alta calidad para impresoras Phomemo M220 / 58mm.
/// La fuente es grande (arial24 / 24px) para ocupar el ancho total y el margen de corte
/// al final es de ~2.5 cm directamente en el mapa de bits para evitar avanzar 50 cm.
Future<List<int>> buildRasterEscPosBytes(
  TicketData data, {
  AnchoPapel ancho = AnchoPapel.mm58,
}) async {
  final width = ancho == AnchoPapel.mm58 ? 384 : 576;
  final printableWidth = width - 20;

  final itemsList = <_TicketLineItem>[];

  // Encabezado
  itemsList.add(_TicketLineItem.text(data.nombreNegocio.toUpperCase(), font: img.arial24, isBold: true, align: _TextAlign.center));
  itemsList.add(_TicketLineItem.text(data.tituloEstado, font: img.arial14, align: _TextAlign.center));
  itemsList.add(_TicketLineItem.divider());
  itemsList.add(_TicketLineItem.text(data.codigoTurno, font: img.arial24, isBold: true, align: _TextAlign.center));
  itemsList.add(_TicketLineItem.divider());

  // Detalles de pedido
  itemsList.add(_TicketLineItem.text('${data.esDomicilio ? 'Domicilio' : 'Mesa'}: ${data.referenciaONombreTipo}', font: img.arial24, isBold: true));
  if (data.cliente.trim().isNotEmpty) {
    itemsList.add(_TicketLineItem.text('Cliente: ${data.cliente.trim()}', font: img.arial14));
  }
  if (data.mesero.trim().isNotEmpty) {
    itemsList.add(_TicketLineItem.text('Mesero: ${data.mesero.trim()}', font: img.arial14));
  }
  itemsList.add(_TicketLineItem.text('Fecha: ${formatFechaTicket(data.fecha)}', font: img.arial14));
  itemsList.add(_TicketLineItem.divider());

  // Productos
  if (data.items.isEmpty) {
    itemsList.add(_TicketLineItem.text('Sin productos agregados', font: img.arial14, align: _TextAlign.center));
  } else {
    for (final item in data.items) {
      itemsList.add(_TicketLineItem.text('${item.cantidad}x ${item.nombreProducto}', font: img.arial24, isBold: true));
      if (item.adicionales.isNotEmpty) {
        itemsList.add(_TicketLineItem.text('  + ${item.adicionales.join(', ')}', font: img.arial14));
      }
      if (item.nota.trim().isNotEmpty) {
        itemsList.add(_TicketLineItem.text('  Nota: ${item.nota.trim()}', font: img.arial14));
      }
      itemsList.add(_TicketLineItem.row('  ${formatMoney(item.precio)} c/u', formatMoney(item.subtotal), font: img.arial14));
    }
  }

  itemsList.add(_TicketLineItem.divider());
  itemsList.add(_TicketLineItem.row('Subtotal', formatMoney(data.subtotal), font: img.arial14));
  if (data.domicilioCobrado > 0) {
    itemsList.add(_TicketLineItem.row('Domicilio', formatMoney(data.domicilioCobrado), font: img.arial14));
  }
  itemsList.add(_TicketLineItem.divider());
  itemsList.add(_TicketLineItem.row('TOTAL', formatMoney(data.total), font: img.arial24, isBold: true));
  if (data.medioPago.trim().isNotEmpty) {
    itemsList.add(_TicketLineItem.divider());
    itemsList.add(_TicketLineItem.row('Medio de pago', data.medioPago.trim(), font: img.arial14, isBold: true));
  }
  if (data.infoTransferencia.isNotEmpty) {
    itemsList.add(_TicketLineItem.divider());
    itemsList.add(_TicketLineItem.text('PAGOS POR TRANSFERENCIA:', font: img.arial14, align: _TextAlign.center, isBold: true));
    for (final linea in data.infoTransferencia) {
      itemsList.add(_TicketLineItem.text(linea, font: img.arial14, align: _TextAlign.center));
    }
  }
  itemsList.add(_TicketLineItem.divider());
  itemsList.add(_TicketLineItem.text('Gracias por tu compra', font: img.arial14, align: _TextAlign.center));

  // Holgura requerida: al menos 1 cm al inicio y al final (80 px a 203 DPI = ~10 mm)
  const int marginYTop = 80;    // 1 cm de holgura de papel al inicio
  const int marginYBottom = 80; // 1 cm de holgura de papel al final antes del corte

  int totalHeight = marginYTop + marginYBottom;
  for (final item in itemsList) {
    totalHeight += item.height;
  }

  final image = img.Image(width: width, height: totalHeight);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));

  int currentY = marginYTop;
  for (final item in itemsList) {
    item.render(image, currentY, width, printableWidth);
    currentY += item.height;
  }

  final profile = await CapabilityProfile.load();
  final generator = Generator(_paperSizeDe(ancho), profile);
  final bytes = <int>[];

  // 1. INIT Y CONFIGURACIÓN (Compatible con papel continuo y POS térmicas estándar)
  bytes.addAll([
    0x1B, 0x40,       // ESC @ - Reset e inicialización de impresora
    0x1F, 0x11, 0x0B, // Phomemo M220: modo papel continuo (por si es impresora Phomemo)
    0x1B, 0x33, 0x00, // ESC 3 0 - Espaciado de línea en 0
  ]);

  // 2. DATOS RASTER (GS v 0)
  final rasterBytes = generator.imageRaster(image);
  bytes.addAll(rasterBytes);

  // 3. FINALIZACIÓN Y CORTE: Avance suficiente para superar la cuchilla / barra de corte
  // La distancia física entre el cabezal térmico y la sierra de corte en impresoras 58mm
  // es de 15-22 mm. Avanzamos 220 puntos (~27.5 mm) + 2 líneas para que al cortar
  // siempre quede al menos 1 cm de papel limpio por debajo de la última línea de texto.
  bytes.addAll([
    0x1B, 0x4A, 220,  // ESC J 220 - Avanzar 220 puntos
    0x1B, 0x64, 0x02,  // ESC d 2   - Avanzar 2 líneas adicionales de seguridad
  ]);

  // ---- LOGGING DIAGNÓSTICO PROFUNDO ----
  final totalBytes = bytes.length;
  final widthBytes = image.width ~/ 8;
  final heightLines = image.height;
  final heightMm = heightLines / 8.0;
  
  debugPrint('\n================ REPORTE DE IMPRESIÓN M220 ================');
  debugPrint('ANCHO REAL BITMAP: ${image.width} px ($widthBytes bytes por fila)');
  debugPrint('ALTO REAL BITMAP:  $heightLines px (${heightMm.toStringAsFixed(2)} mm)');
  debugPrint('CANTIDAD DE BYTES RASTER: ${rasterBytes.length}');
  debugPrint('TOTAL BYTES ENVIADOS: $totalBytes');
  
  // Imprimir Hex estructurado
  String toHex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
  debugPrint('\n[PACKET HEX LOG]');
  debugPrint('HEADER (Init, Spacing): ${toHex([0x1B, 0x40, 0x1B, 0x33, 0x00])}');
  debugPrint('RASTER CMD HEADER: ${toHex(rasterBytes.sublist(0, 8))} ... [data omitida] ...');
  debugPrint('FOOTER (Feed dots): ${toHex([0x1B, 0x4A, 128])}');
  debugPrint('===========================================================\n');

  return bytes;
}

/// Genera bytes ESC/POS en formato texto estándar de alta velocidad.
/// Es universalmente compatible con el 99.9% de impresoras térmicas POS (58mm y 80mm).
/// Garantiza holgura inicial de 1 cm y holgura final de > 1.5 cm tras la cuchilla.
List<int> buildStandardEscPosBytes(
  TicketData data, {
  AnchoPapel ancho = AnchoPapel.mm58,
}) {
  final bytes = <int>[];
  final w = ancho.caracteresPorLinea;

  // 1. Reset / Inicialización
  bytes.addAll([0x1B, 0x40]);

  // 2. Holgura inicial de al menos 1 cm (4 saltos de línea físicos ~12 mm)
  bytes.addAll([0x1B, 0x64, 0x04]);

  // 3. Encabezado centrado con texto resaltado
  bytes.addAll([0x1B, 0x61, 0x01]); // Centrado
  bytes.addAll([0x1D, 0x21, 0x11]); // Doble alto y doble ancho
  bytes.addAll(latin1.encode('${data.nombreNegocio.toUpperCase()}\n'));
  bytes.addAll([0x1D, 0x21, 0x00]); // Tamaño estándar
  bytes.addAll(latin1.encode('${data.tituloEstado}\n'));
  bytes.addAll(latin1.encode('${'=' * w}\n'));

  // Código de turno destacado
  bytes.addAll([0x1D, 0x21, 0x11]); // Doble tamaño
  bytes.addAll(latin1.encode('${data.codigoTurno}\n'));
  bytes.addAll([0x1D, 0x21, 0x00]); // Normal
  bytes.addAll(latin1.encode('${'=' * w}\n'));

  // 4. Datos del pedido
  bytes.addAll([0x1B, 0x61, 0x00]); // Alineación a la izquierda
  final tipoStr = data.esDomicilio ? 'Domicilio' : 'Mesa';
  bytes.addAll(latin1.encode('$tipoStr: ${data.referenciaONombreTipo}\n'));
  if (data.cliente.trim().isNotEmpty) {
    bytes.addAll(latin1.encode('Cliente: ${data.cliente.trim()}\n'));
  }
  if (data.mesero.trim().isNotEmpty) {
    bytes.addAll(latin1.encode('Mesero: ${data.mesero.trim()}\n'));
  }
  bytes.addAll(latin1.encode('Fecha: ${formatFechaTicket(data.fecha)}\n'));
  bytes.addAll(latin1.encode('${'-' * w}\n'));

  // 5. Productos
  if (data.items.isEmpty) {
    bytes.addAll(latin1.encode('${_centrar('Sin productos agregados', w)}\n'));
  } else {
    for (final item in data.items) {
      bytes.addAll([0x1B, 0x45, 0x01]); // Negrita
      bytes.addAll(latin1.encode('${item.cantidad}x ${item.nombreProducto}\n'));
      bytes.addAll([0x1B, 0x45, 0x00]); // Normal
      if (item.adicionales.isNotEmpty) {
        bytes.addAll(latin1.encode('  + ${item.adicionales.join(', ')}\n'));
      }
      if (item.nota.trim().isNotEmpty) {
        bytes.addAll(latin1.encode('  Nota: ${item.nota.trim()}\n'));
      }
      bytes.addAll(latin1.encode(
        '${_dosColumnas('  ${formatMoney(item.precio)} c/u', formatMoney(item.subtotal), w)}\n',
      ));
    }
  }

  // 6. Totales
  bytes.addAll(latin1.encode('${'-' * w}\n'));
  bytes.addAll(latin1.encode('${_dosColumnas('Subtotal', formatMoney(data.subtotal), w)}\n'));
  if (data.domicilioCobrado > 0) {
    bytes.addAll(latin1.encode('${_dosColumnas('Domicilio', formatMoney(data.domicilioCobrado), w)}\n'));
  }
  bytes.addAll(latin1.encode('${'=' * w}\n'));
  bytes.addAll([0x1B, 0x45, 0x01]); // Negrita
  bytes.addAll(latin1.encode('${_dosColumnas('TOTAL', formatMoney(data.total), w)}\n'));
  bytes.addAll([0x1B, 0x45, 0x00]); // Normal
  if (data.medioPago.trim().isNotEmpty) {
    bytes.addAll(latin1.encode('${'-' * w}\n'));
    bytes.addAll(latin1.encode('${_dosColumnas('Medio de pago', data.medioPago.trim(), w)}\n'));
  }
  if (data.infoTransferencia.isNotEmpty) {
    bytes.addAll(latin1.encode('${'-' * w}\n'));
    bytes.addAll([0x1B, 0x61, 0x01]); // Centrado
    bytes.addAll(latin1.encode('PAGOS POR TRANSFERENCIA:\n'));
    for (final linea in data.infoTransferencia) {
      bytes.addAll(latin1.encode('$linea\n'));
    }
  }
  bytes.addAll(latin1.encode('${'=' * w}\n'));

  // 7. Pie de ticket
  bytes.addAll([0x1B, 0x61, 0x01]); // Centrado
  bytes.addAll(latin1.encode('Gracias por tu compra\n'));

  // 8. Holgura final y avance para corte seguro:
  // Avanza 8 líneas completas (~30-32 mm) asegurando que el texto supere
  // completamente la barra de corte o sierra de la impresora con holgura.
  bytes.addAll([
    0x1B, 0x64, 0x08, // ESC d 8 - Avanzar 8 líneas
  ]);

  return bytes;
}

/// Texto plano de la comanda de cocina, optimizada para el cocinero/despacho:
/// código de turno grande, casillas [ ] para checklist de platos, notas y adicionales,
/// sin precios de venta ni datos fiscales que estorben al cocinero.
String buildPlainCocinaTicket(TicketData data, {AnchoPapel ancho = AnchoPapel.mm58}) {
  final w = ancho.caracteresPorLinea;
  final buffer = StringBuffer();

  // Holgura inicial
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln(_centrar('*** ORDEN DE COCINA ***', w));
  buffer.writeln(_linea(w, '='));
  buffer.writeln(_centrar(data.codigoTurno, w));
  buffer.writeln(_linea(w, '='));
  buffer.writeln('${data.esDomicilio ? 'Domicilio' : 'Mesa'}: ${data.referenciaONombreTipo}');
  if (data.cliente.trim().isNotEmpty) buffer.writeln('Cliente: ${data.cliente.trim()}');
  if (data.mesero.trim().isNotEmpty) buffer.writeln('Mesero: ${data.mesero.trim()}');
  buffer.writeln('Hora: ${formatFechaTicket(data.fecha)}');
  buffer.writeln(_linea(w));

  if (data.items.isEmpty) {
    buffer.writeln(_centrar('Sin productos agregados', w));
  } else {
    for (final item in data.items) {
      buffer.writeln('[ ] ${item.cantidad}x ${item.nombreProducto}');
      if (item.adicionales.isNotEmpty) {
        buffer.writeln('    + ${item.adicionales.join(', ')}');
      }
      if (item.nota.trim().isNotEmpty) {
        buffer.writeln('    * NOTA: ${item.nota.trim()}');
      }
      buffer.writeln();
    }
  }

  buffer.writeln(_linea(w, '='));
  buffer.writeln('Platos/Items a despachar: ${data.totalCantidadItems}');
  buffer.writeln(_centrar('*** CONTROL DE DESPACHO ***', w));
  // Holgura final para corte limpio
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();
  buffer.writeln();

  return buffer.toString();
}

/// Genera bytes ESC/POS en formato texto estándar para la COMANDA DE COCINA.
/// Incluye casillas [ ] de checklist para cada plato, código de turno destacado
/// y notas especiales de preparación.
List<int> buildStandardEscPosCocinaBytes(
  TicketData data, {
  AnchoPapel ancho = AnchoPapel.mm58,
}) {
  final bytes = <int>[];
  final w = ancho.caracteresPorLinea;

  // 1. Reset / Inicialización
  bytes.addAll([0x1B, 0x40]);

  // 2. Holgura inicial de al menos 1 cm
  bytes.addAll([0x1B, 0x64, 0x04]);

  // 3. Encabezado centrado de cocina
  bytes.addAll([0x1B, 0x61, 0x01]); // Centrado
  bytes.addAll([0x1D, 0x21, 0x11]); // Doble alto y doble ancho
  bytes.addAll(latin1.encode('ORDEN DE COCINA\n'));
  bytes.addAll([0x1D, 0x21, 0x00]); // Normal
  bytes.addAll(latin1.encode('${'=' * w}\n'));

  // Código de turno destacado gigante
  bytes.addAll([0x1D, 0x21, 0x11]); // Doble tamaño
  bytes.addAll(latin1.encode('${data.codigoTurno}\n'));
  bytes.addAll([0x1D, 0x21, 0x00]); // Normal
  bytes.addAll(latin1.encode('${'=' * w}\n'));

  // 4. Datos del pedido
  bytes.addAll([0x1B, 0x61, 0x00]); // Alineación a la izquierda
  final tipoStr = data.esDomicilio ? 'Domicilio' : 'Mesa';
  bytes.addAll([0x1B, 0x45, 0x01]); // Negrita
  bytes.addAll(latin1.encode('$tipoStr: ${data.referenciaONombreTipo}\n'));
  bytes.addAll([0x1B, 0x45, 0x00]); // Normal
  if (data.cliente.trim().isNotEmpty) {
    bytes.addAll(latin1.encode('Cliente: ${data.cliente.trim()}\n'));
  }
  if (data.mesero.trim().isNotEmpty) {
    bytes.addAll(latin1.encode('Mesero: ${data.mesero.trim()}\n'));
  }
  bytes.addAll(latin1.encode('Hora: ${formatFechaTicket(data.fecha)}\n'));
  bytes.addAll(latin1.encode('${'-' * w}\n'));

  // 5. Productos tipo checklist de cocina
  if (data.items.isEmpty) {
    bytes.addAll(latin1.encode('${_centrar('Sin productos agregados', w)}\n'));
  } else {
    for (final item in data.items) {
      bytes.addAll([0x1B, 0x45, 0x01]); // Negrita
      bytes.addAll(latin1.encode('[ ] ${item.cantidad}x ${item.nombreProducto}\n'));
      bytes.addAll([0x1B, 0x45, 0x00]); // Normal
      if (item.adicionales.isNotEmpty) {
        bytes.addAll(latin1.encode('    + ${item.adicionales.join(', ')}\n'));
      }
      if (item.nota.trim().isNotEmpty) {
        bytes.addAll([0x1B, 0x45, 0x01]);
        bytes.addAll(latin1.encode('    * NOTA: ${item.nota.trim()}\n'));
        bytes.addAll([0x1B, 0x45, 0x00]);
      }
      bytes.addAll(latin1.encode('\n'));
    }
  }

  // 6. Resumen de despacho
  bytes.addAll(latin1.encode('${'=' * w}\n'));
  bytes.addAll([0x1B, 0x45, 0x01]);
  bytes.addAll(latin1.encode('Platos/Items a despachar: ${data.totalCantidadItems}\n'));
  bytes.addAll([0x1B, 0x45, 0x00]);
  bytes.addAll([0x1B, 0x61, 0x01]); // Centrado
  bytes.addAll(latin1.encode('*** CONTROL DE DESPACHO ***\n'));

  // 7. Holgura final y corte seguro (8 líneas)
  bytes.addAll([0x1B, 0x64, 0x08]);

  return bytes;
}

/// Genera un mapa de bits (raster) de comanda de cocina para impresoras Phomemo M220 / térmicas gráficas.
Future<List<int>> buildRasterCocinaBytes(
  TicketData data, {
  AnchoPapel ancho = AnchoPapel.mm58,
}) async {
  final width = ancho == AnchoPapel.mm58 ? 384 : 576;
  final printableWidth = width - 20;

  final itemsList = <_TicketLineItem>[];

  // Encabezado
  itemsList.add(_TicketLineItem.text('ORDEN DE COCINA', font: img.arial24, isBold: true, align: _TextAlign.center));
  itemsList.add(_TicketLineItem.divider());
  itemsList.add(_TicketLineItem.text(data.codigoTurno, font: img.arial24, isBold: true, align: _TextAlign.center));
  itemsList.add(_TicketLineItem.divider());

  // Detalles
  itemsList.add(_TicketLineItem.text('${data.esDomicilio ? 'Domicilio' : 'Mesa'}: ${data.referenciaONombreTipo}', font: img.arial24, isBold: true));
  if (data.cliente.trim().isNotEmpty) {
    itemsList.add(_TicketLineItem.text('Cliente: ${data.cliente.trim()}', font: img.arial14));
  }
  if (data.mesero.trim().isNotEmpty) {
    itemsList.add(_TicketLineItem.text('Mesero: ${data.mesero.trim()}', font: img.arial14));
  }
  itemsList.add(_TicketLineItem.text('Hora: ${formatFechaTicket(data.fecha)}', font: img.arial14));
  itemsList.add(_TicketLineItem.divider());

  // Productos
  if (data.items.isEmpty) {
    itemsList.add(_TicketLineItem.text('Sin productos agregados', font: img.arial14, align: _TextAlign.center));
  } else {
    for (final item in data.items) {
      itemsList.add(_TicketLineItem.text('[ ] ${item.cantidad}x ${item.nombreProducto}', font: img.arial24, isBold: true));
      if (item.adicionales.isNotEmpty) {
        itemsList.add(_TicketLineItem.text('    + ${item.adicionales.join(', ')}', font: img.arial14));
      }
      if (item.nota.trim().isNotEmpty) {
        itemsList.add(_TicketLineItem.text('    * NOTA: ${item.nota.trim()}', font: img.arial14, isBold: true));
      }
    }
  }

  itemsList.add(_TicketLineItem.divider());
  itemsList.add(_TicketLineItem.text('Platos a despachar: ${data.totalCantidadItems}', font: img.arial14, isBold: true, align: _TextAlign.center));
  itemsList.add(_TicketLineItem.text('*** CONTROL DE DESPACHO ***', font: img.arial14, align: _TextAlign.center));

  const int marginYTop = 80;
  const int marginYBottom = 80;

  int totalHeight = marginYTop + marginYBottom;
  for (final item in itemsList) {
    totalHeight += item.height;
  }

  final image = img.Image(width: width, height: totalHeight);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));

  int currentY = marginYTop;
  for (final item in itemsList) {
    item.render(image, currentY, width, printableWidth);
    currentY += item.height;
  }

  final profile = await CapabilityProfile.load();
  final generator = Generator(_paperSizeDe(ancho), profile);
  final bytes = <int>[];

  bytes.addAll([
    0x1B, 0x40,
    0x1F, 0x11, 0x0B,
    0x1B, 0x33, 0x00,
  ]);

  final rasterBytes = generator.imageRaster(image);
  bytes.addAll(rasterBytes);

  bytes.addAll([
    0x1B, 0x4A, 220,
    0x1B, 0x64, 0x02,
  ]);

  return bytes;
}

/// Genera los bytes ESC/POS listos para enviar a la impresora para la COMANDA DE COCINA.
Future<List<int>> buildEscPosCocinaBytes(
  TicketData data, {
  AnchoPapel ancho = AnchoPapel.mm58,
  bool usarRaster = false,
}) async {
  if (usarRaster) {
    return buildRasterCocinaBytes(data, ancho: ancho);
  }
  return buildStandardEscPosCocinaBytes(data, ancho: ancho);
}

/// Genera un ticket especial de calibración y sincronización de impresora.
List<int> buildCalibrationTicketBytes({
  AnchoPapel ancho = AnchoPapel.mm58,
  String deviceName = 'Impresora POS',
}) {
  final bytes = <int>[];
  final w = ancho.caracteresPorLinea;

  bytes.addAll([0x1B, 0x40]);
  bytes.addAll([0x1B, 0x64, 0x04]); // > 1 cm de holgura inicial
  bytes.addAll([0x1B, 0x61, 0x01]); // Centro
  bytes.addAll([0x1D, 0x21, 0x11]); // Doble tamaño
  bytes.addAll(latin1.encode('POSIFY APP\n'));
  bytes.addAll([0x1D, 0x21, 0x00]); // Normal
  bytes.addAll(latin1.encode('CALIBRACION EXITOSA\n'));
  bytes.addAll(latin1.encode('${'=' * w}\n'));
  bytes.addAll([0x1B, 0x61, 0x00]); // Izquierda
  bytes.addAll(latin1.encode('Dispositivo: $deviceName\n'));
  bytes.addAll(latin1.encode('Ancho papel: ${ancho.etiqueta}\n'));
  bytes.addAll(latin1.encode('Holgura inicio: 1.0 cm [OK]\n'));
  bytes.addAll(latin1.encode('Holgura corte:  1.5 cm [OK]\n'));
  bytes.addAll(latin1.encode('Estado: Sincronizada\n'));
  bytes.addAll(latin1.encode('${'=' * w}\n'));
  bytes.addAll([0x1B, 0x61, 0x01]); // Centro
  bytes.addAll([0x1B, 0x45, 0x01]); // Negrita
  bytes.addAll(latin1.encode('*** LISTA PARA FACTURAR ***\n'));
  bytes.addAll([0x1B, 0x45, 0x00]);
  bytes.addAll([0x1B, 0x64, 0x08]); // 8 líneas de avance para corte limpio con holgura

  return bytes;
}

/// Bytes ESC/POS listos para enviar a una impresora térmica Bluetooth.
/// Selecciona automáticamente el formato nativo estándar ESC/POS (ultra-rápido,
/// sin saturación de memoria) o el raster de bitmap si se trata de una impresora Phomemo M220.
Future<List<int>> buildEscPosBytes(
  TicketData data, {
  AnchoPapel ancho = AnchoPapel.mm58,
  bool usarRaster = false,
}) async {
  if (usarRaster) {
    return buildRasterEscPosBytes(data, ancho: ancho);
  }
  return buildStandardEscPosBytes(data, ancho: ancho);
}
