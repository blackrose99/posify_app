import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/utils/money_formatter.dart';
import '../pedidos/domain/entities/item_pedido.dart';
import 'ticket_data.dart';

const PdfColor _verde = PdfColor.fromInt(0xFF146C2E);
const PdfColor _verdeClaro = PdfColor.fromInt(0xFFE3F4E8);

pw.Widget _columnaCabecera(String texto, {bool alinearDerecha = false}) {
  return pw.Text(
    texto,
    textAlign: alinearDerecha ? pw.TextAlign.right : pw.TextAlign.left,
    style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10, color: _verde),
  );
}

pw.Widget _filaItem(ItemPedido item) {
  final adicionales = item.adicionales;
  final nota = item.nota.trim();
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 4),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: 28,
              child: pw.Text('${item.cantidad}x', style: const pw.TextStyle(fontSize: 11)),
            ),
            pw.Expanded(
              flex: 4,
              child: pw.Text(
                item.nombreProducto,
                style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.Expanded(
              flex: 2,
              child: pw.Text(
                formatMoney(item.precio),
                textAlign: pw.TextAlign.right,
                style: const pw.TextStyle(fontSize: 11),
              ),
            ),
            pw.Expanded(
              flex: 2,
              child: pw.Text(
                formatMoney(item.subtotal),
                textAlign: pw.TextAlign.right,
                style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
              ),
            ),
          ],
        ),
        if (adicionales.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 28, top: 2),
            child: pw.Text(
              '+ ${adicionales.join(', ')}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
          ),
        if (nota.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(left: 28, top: 2),
            child: pw.Text(
              'Nota: $nota',
              style: pw.TextStyle(
                fontSize: 9,
                color: PdfColors.grey700,
                fontStyle: pw.FontStyle.italic,
              ),
            ),
          ),
      ],
    ),
  );
}

pw.Widget _filaTotal(String etiqueta, double valor, {bool destacado = false}) {
  return pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 2),
    child: pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.SizedBox(
          width: 90,
          child: pw.Text(
            etiqueta,
            textAlign: pw.TextAlign.right,
            style: pw.TextStyle(
              fontSize: destacado ? 13 : 11,
              fontWeight: destacado ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ),
        pw.SizedBox(width: 12),
        pw.SizedBox(
          width: 80,
          child: pw.Text(
            formatMoney(valor),
            textAlign: pw.TextAlign.right,
            style: pw.TextStyle(
              fontSize: destacado ? 13 : 11,
              fontWeight: pw.FontWeight.bold,
              color: destacado ? _verde : PdfColors.black,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Genera una factura PDF elegante con el detalle completo del pedido:
/// código de turno, productos, adicionales, notas y totales.
Future<Uint8List> buildTicketPdf(TicketData data) async {
  final doc = pw.Document();

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a5,
      margin: const pw.EdgeInsets.all(28),
      build: (context) {
        return pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      data.nombreNegocio,
                      style: pw.TextStyle(
                        fontSize: 20,
                        fontWeight: pw.FontWeight.bold,
                        color: _verde,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      data.tituloEstado,
                      style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
                    ),
                  ],
                ),
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: pw.BoxDecoration(
                    color: _verde,
                    borderRadius: pw.BorderRadius.circular(8),
                  ),
                  child: pw.Text(
                    data.codigoTurno,
                    style: pw.TextStyle(
                      color: PdfColors.white,
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 16),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: _verdeClaro,
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    '${data.esDomicilio ? 'Domicilio' : 'Mesa'}: ${data.referenciaONombreTipo}',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                  if (data.cliente.trim().isNotEmpty)
                    pw.Text('Cliente: ${data.cliente.trim()}', style: const pw.TextStyle(fontSize: 10)),
                  if (data.mesero.trim().isNotEmpty)
                    pw.Text('Atendido por: ${data.mesero.trim()}',
                        style: const pw.TextStyle(fontSize: 10)),
                  pw.Text('Fecha: ${formatFechaTicket(data.fecha)}',
                      style: const pw.TextStyle(fontSize: 10)),
                ],
              ),
            ),
            pw.SizedBox(height: 16),
            pw.Row(
              children: [
                pw.SizedBox(width: 28, child: pw.SizedBox()),
                pw.Expanded(flex: 4, child: _columnaCabecera('Producto')),
                pw.Expanded(flex: 2, child: _columnaCabecera('V. Unit', alinearDerecha: true)),
                pw.Expanded(flex: 2, child: _columnaCabecera('Subtotal', alinearDerecha: true)),
              ],
            ),
            pw.Divider(color: _verde, thickness: 1),
            if (data.items.isEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 12),
                child: pw.Text(
                  'Sin productos agregados.',
                  style: pw.TextStyle(color: PdfColors.grey600, fontStyle: pw.FontStyle.italic),
                ),
              )
            else
              ...data.items.map(_filaItem),
            pw.Divider(color: PdfColors.grey300),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  _filaTotal('Subtotal', data.subtotal),
                  if (data.domicilioCobrado > 0) _filaTotal('Domicilio', data.domicilioCobrado),
                  pw.SizedBox(height: 6),
                  _filaTotal('TOTAL', data.total, destacado: true),
                ],
              ),
            ),
            pw.Spacer(),
            pw.Center(
              child: pw.Text(
                'Gracias por tu compra',
                style: pw.TextStyle(fontStyle: pw.FontStyle.italic, color: PdfColors.grey600),
              ),
            ),
          ],
        );
      },
    ),
  );

  return doc.save();
}
