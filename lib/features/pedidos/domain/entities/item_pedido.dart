import 'package:equatable/equatable.dart';

class ItemPedido extends Equatable {
  final int          id;
  final int          pedidoId;
  final int          productoId;
  final String       nombreProducto;
  final double       precio;
  final int          cantidad;
  final List<String> adicionales;
  final String       nota;
  final bool         entregado;

  const ItemPedido({
    required this.id,
    required this.pedidoId,
    required this.productoId,
    required this.nombreProducto,
    required this.precio,
    required this.cantidad,
    required this.adicionales,
    required this.nota,
    this.entregado = false,
  });

  ItemPedido copyWith({
    int? id,
    int? pedidoId,
    int? productoId,
    String? nombreProducto,
    double? precio,
    int? cantidad,
    List<String>? adicionales,
    String? nota,
    bool? entregado,
  }) {
    return ItemPedido(
      id: id ?? this.id,
      pedidoId: pedidoId ?? this.pedidoId,
      productoId: productoId ?? this.productoId,
      nombreProducto: nombreProducto ?? this.nombreProducto,
      precio: precio ?? this.precio,
      cantidad: cantidad ?? this.cantidad,
      adicionales: adicionales ?? this.adicionales,
      nota: nota ?? this.nota,
      entregado: entregado ?? this.entregado,
    );
  }

  double get subtotal => precio * cantidad;

  @override
  List<Object?> get props => [id, pedidoId, productoId, cantidad, adicionales, entregado];
}
