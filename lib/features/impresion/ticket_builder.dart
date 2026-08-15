import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;

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
  buffer.writeln(_linea(w, '='));
  buffer.writeln(_centrar('Gracias por tu compra', w));

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
  itemsList.add(_TicketLineItem.divider());
  itemsList.add(_TicketLineItem.text('Gracias por tu compra', font: img.arial14, align: _TextAlign.center));

  // Alto exacto del contenido (sin colchón gigantesco)
  int totalHeight = 30;
  for (final item in itemsList) {
    totalHeight += item.height;
  }

  final image = img.Image(width: width, height: totalHeight);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));

  int currentY = 15;
  for (final item in itemsList) {
    item.render(image, currentY, width, printableWidth);
    currentY += item.height;
  }

  final profile = await CapabilityProfile.load();
  final generator = Generator(_paperSizeDe(ancho), profile);
  final bytes = <int>[];

  // ── HEADER PROPIETARIO PHOMEMO M220 ──────────────────────────────────────
  // El reset (ESC @) y la pausa de 300ms ahora los hace el ForegroundService 
  // en Android ANTES de enviar estos bytes. NO enviar ESC @ aquí porque 
  // reiniciaría la impresora a modo Etiqueta perdiendo el efecto del pre-flush.
  bytes.addAll([
    0x1B, 0x4E, 0x0D, 0x03,  // Velocidad de impresión = 3 (medio)
    0x1B, 0x4E, 0x04, 0x05,  // Densidad de impresión = 5 (medio)
    0x1F, 0x11, 0x0B,        // Modo papel: CONTINUO (reafirmar por si acaso)
  ]);

  // ── DATOS RASTER (GS v 0) ────────────────────────────────────────────────
  bytes.addAll(generator.imageRaster(image));

  // ── FOOTER PROPIETARIO PHOMEMO M220 ─────────────────────────────────────
  // Fuente: phomemo-tools Issue #13 + phomymo/printer.js
  bytes.addAll([
    0x1B, 0x64, 0x02,       // ESC d 2 — Avanzar 2 líneas (separación de corte)
    0x1F, 0xF0, 0x05, 0x00, // End-of-print signal (propietario Phomemo)
    0x1F, 0xF0, 0x03, 0x00, // Motor stop / reset (propietario Phomemo)
  ]);

  return bytes;
}

/// Bytes ESC/POS listos para enviar a una impresora térmica Bluetooth.
Future<List<int>> buildEscPosBytes(
  TicketData data, {
  AnchoPapel ancho = AnchoPapel.mm58,
}) async {
  return buildRasterEscPosBytes(data, ancho: ancho);
}
