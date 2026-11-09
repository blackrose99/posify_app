import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'tables/meseros_table.dart';
import 'tables/pedidos_table.dart';
import 'tables/productos_table.dart';
import 'tables/facturas_table.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [
  Mesas,
  Meseros,
  Pedidos,
  ItemsPedido,
  Categorias,
  Productos,
  Adicionales,
  Facturas,
  Configuracion,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _insertDatosInicialesSeguros();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            try {
              await m.createTable(meseros);
            } catch (_) {}
          }
          // Migraciones seguras y no destructivas: nunca borrar ni sobreescribir datos del cliente
          await _asegurarColumnasYTablas();
        },
        beforeOpen: (details) async {
          await _asegurarColumnasYTablas();
        },
      );

  Future<void> _asegurarColumnasYTablas() async {
    // Asegura tabla de jornadas
    await customStatement('''
      CREATE TABLE IF NOT EXISTS jornadas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nombre TEXT NOT NULL,
        estado TEXT NOT NULL DEFAULT 'abierta',
        abierta_en TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        cerrada_en TEXT
      )
    ''');

    // Asegura tabla de etiquetas por categoría
    await customStatement('''
      CREATE TABLE IF NOT EXISTS categoria_etiquetas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        categoria_id INTEGER NOT NULL,
        nombre TEXT NOT NULL,
        activa INTEGER NOT NULL DEFAULT 1
      )
    ''');

    // Columnas adicionales en pedidos (sin borrar datos existentes)
    for (final colSql in [
      'ALTER TABLE pedidos ADD COLUMN jornada_id INTEGER',
      'ALTER TABLE pedidos ADD COLUMN referencia TEXT',
      'ALTER TABLE pedidos ADD COLUMN cliente TEXT',
      'ALTER TABLE pedidos ADD COLUMN mesero TEXT',
      'ALTER TABLE pedidos ADD COLUMN numero_turno INTEGER',
      'ALTER TABLE pedidos ADD COLUMN entregado INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE pedidos ADD COLUMN entregado_en INTEGER',
      'ALTER TABLE pedidos ADD COLUMN impreso_cliente INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE pedidos ADD COLUMN impreso_cocina INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE pedidos ADD COLUMN medio_pago TEXT NOT NULL DEFAULT ""',
      'ALTER TABLE items_pedido ADD COLUMN entregado INTEGER NOT NULL DEFAULT 0',
    ]) {
      try {
        await customStatement(colSql);
      } catch (_) {}
    }
  }

  Future<void> _insertDatosInicialesSeguros() async {
    // Solo si la base está completamente nueva (primera instalación en dispositivo limpio)
    final existingCats = await select(categorias).get();
    if (existingCats.isEmpty) {
      await batch((b) {
        b.insertAll(categorias, [
          CategoriasCompanion.insert(nombre: 'Picadas', orden: const Value(1)),
          CategoriasCompanion.insert(
              nombre: 'Carnes al Barril', orden: const Value(2)),
          CategoriasCompanion.insert(nombre: 'Porciones', orden: const Value(3)),
          CategoriasCompanion.insert(nombre: 'Bebidas', orden: const Value(4)),
        ]);
      });
    }

    final existingConfig = await select(configuracion).get();
    if (existingConfig.isEmpty) {
      await batch((b) {
        b.insertAll(configuracion, [
          ConfiguracionCompanion.insert(clave: 'valor_domicilio', valor: '5000'),
          ConfiguracionCompanion.insert(clave: 'total_mesas', valor: '6'),
          ConfiguracionCompanion.insert(
              clave: 'nombre_negocio', valor: 'POSify'),
        ]);
      });
    }

    final existingMesas = await select(mesas).get();
    if (existingMesas.isEmpty) {
      await batch((b) {
        b.insertAll(mesas, [
          for (int i = 1; i <= 6; i++) MesasCompanion.insert(nombre: 'Mesa $i'),
        ]);
      });
    }

    await _asegurarColumnasYTablas();
  }

  /// Ya no se siembran datos de prueba automáticamente para no alterar
  /// la base de datos real del cliente. Solo se ejecuta si se solicita manualmente.
  Future<void> asegurarDatosInicialesDePrueba({bool forzar = false}) async {
    if (!forzar) return;
    final flag = await (select(configuracion)
          ..where((c) => c.clave.equals('seed_datos_prueba_v1')))
        .getSingleOrNull();

    final prodCountRow = await customSelect(
      'SELECT COUNT(*) AS cnt FROM productos WHERE activo = 1',
    ).getSingle();
    final prodCount = (prodCountRow.data['cnt'] as int?) ?? 0;

    if (flag != null && prodCount >= 5 && !forzar) {
      return;
    }

    // 1. Asegurar categorías
    var cats = await select(categorias).get();
    if (cats.isEmpty) {
      await batch((b) {
        b.insertAll(categorias, [
          CategoriasCompanion.insert(nombre: 'Picadas', orden: const Value(1)),
          CategoriasCompanion.insert(
              nombre: 'Carnes al Barril', orden: const Value(2)),
          CategoriasCompanion.insert(
              nombre: 'Porciones', orden: const Value(3)),
          CategoriasCompanion.insert(nombre: 'Bebidas', orden: const Value(4)),
        ]);
      });
      cats = await select(categorias).get();
    }

    int catIdPorNombre(String nombre, int fallback) {
      for (final c in cats) {
        if (c.nombre.toLowerCase().contains(nombre.toLowerCase())) {
          return c.id;
        }
      }
      return fallback;
    }

    final idPicadas = catIdPorNombre('picada', cats.first.id);
    final idCarnes = catIdPorNombre('carne', idPicadas);
    final idPorciones = catIdPorNombre('porcion', cats.first.id);
    final idBebidas = catIdPorNombre('bebida', cats.last.id);

    // 2. Asegurar productos iniciales (al menos 8 productos variados)
    if (prodCount < 5 || forzar) {
      final existentes = (await select(productos).get())
          .map((p) => p.nombre.toLowerCase().trim())
          .toSet();

      final productosPrueba = <ProductosCompanion>[
        ProductosCompanion.insert(
          categoriaId: idPicadas,
          nombre: 'Picada Personal al Barril',
          descripcion: const Value(
              'Chicharrón, bondiola de cerdo, res, chorizo, papa criolla y arepa'),
          precio: 28000,
        ),
        ProductosCompanion.insert(
          categoriaId: idPicadas,
          nombre: 'Picada Dúo Barril (2 personas)',
          descripcion: const Value(
              'Chicharrón crocante, costilla BBQ, punta de anca, chorizo y patacón'),
          precio: 54000,
        ),
        ProductosCompanion.insert(
          categoriaId: idPicadas,
          nombre: 'Picada Familiar Barril (4 personas)',
          descripcion: const Value(
              'Mix completo de carnes al barril con papas criollas, yuca y guacamole'),
          precio: 98000,
        ),
        ProductosCompanion.insert(
          categoriaId: idCarnes,
          nombre: 'Bandeja de Chicharrón al Barril',
          descripcion: const Value(
              '350g de chicharrón carnudo y crocante con arepa y limón'),
          precio: 32000,
        ),
        ProductosCompanion.insert(
          categoriaId: idCarnes,
          nombre: 'Costillas San Luis BBQ al Barril',
          descripcion: const Value(
              '400g de costilla de cerdo ahumada al barril con papas rústicas'),
          precio: 36000,
        ),
        ProductosCompanion.insert(
          categoriaId: idCarnes,
          nombre: 'Punta de Anca al Barril 350g',
          descripcion: const Value(
              'Corte jugoso al barril acompañado de papa criolla y chimichurri'),
          precio: 39000,
        ),
        ProductosCompanion.insert(
          categoriaId: idPorciones,
          nombre: 'Porción de Chorizo Artesanal (x2)',
          descripcion: const Value(
              'Dos chorizos santarrosanos al barril con arepa y limón'),
          precio: 14000,
        ),
        ProductosCompanion.insert(
          categoriaId: idPorciones,
          nombre: 'Porción de Papa Criolla Dorada',
          descripcion:
              const Value('Papas criollas al barril con salsa de la casa'),
          precio: 8000,
        ),
        ProductosCompanion.insert(
          categoriaId: idBebidas,
          nombre: 'Limonada Natural / Cerezada',
          descripcion: const Value('Vaso 16 oz recién preparada bien fría'),
          precio: 8000,
        ),
        ProductosCompanion.insert(
          categoriaId: idBebidas,
          nombre: 'Coca-Cola Personal 400ml',
          descripcion: const Value('Gaseosa fría personal'),
          precio: 5000,
        ),
      ];

      await batch((b) {
        for (final p in productosPrueba) {
          if (!existentes.contains(p.nombre.value.toLowerCase().trim())) {
            b.insert(productos, p);
          }
        }
      });
    }

    // 3. Asegurar meseros de prueba
    final meserosActuales = await select(meseros).get();
    if (meserosActuales.isEmpty || forzar) {
      final nombresExistentes =
          meserosActuales.map((m) => m.nombre.toLowerCase().trim()).toSet();
      for (final nombre in ['Carlos', 'Laura', 'Andrés', 'Valentina']) {
        if (!nombresExistentes.contains(nombre.toLowerCase())) {
          await into(meseros).insert(MeserosCompanion.insert(nombre: nombre));
        }
      }
    }

    // 4. Asegurar etiquetas por categoría
    await customStatement('''
      CREATE TABLE IF NOT EXISTS categoria_etiquetas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        categoria_id INTEGER NOT NULL,
        nombre TEXT NOT NULL,
        activa INTEGER NOT NULL DEFAULT 1
      )
    ''');
    final etiquetasCountRow = await customSelect(
      'SELECT COUNT(*) AS cnt FROM categoria_etiquetas',
    ).getSingle();
    final etiquetasCount = (etiquetasCountRow.data['cnt'] as int?) ?? 0;
    if (etiquetasCount == 0) {
      final etiquetasSeed = <MapEntry<int, String>>[
        MapEntry(idPicadas, 'Jugosa'),
        MapEntry(idPicadas, 'Chicharrón crocante'),
        MapEntry(idPicadas, 'Solo cerdo'),
        MapEntry(idPicadas, 'Sin guacamole'),
        MapEntry(idPicadas, 'Extra chimichurri'),
        if (idCarnes != idPicadas) ...[
          MapEntry(idCarnes, 'Término medio'),
          MapEntry(idCarnes, 'Término 3/4'),
          MapEntry(idCarnes, 'Bien asada'),
        ],
        MapEntry(idPorciones, 'Con salsa de ajo'),
        MapEntry(idPorciones, 'Extra limón'),
        MapEntry(idBebidas, 'Sin hielo'),
        MapEntry(idBebidas, 'Con limón'),
        MapEntry(idBebidas, 'Al clima'),
      ];
      for (final entry in etiquetasSeed) {
        await customStatement(
          'INSERT INTO categoria_etiquetas (categoria_id, nombre, activa) VALUES (?, ?, 1)',
          [entry.key, entry.value],
        );
      }
    }

    // 5. Asegurar tabla jornadas y crear jornada inicial de prueba con pedidos
    await customStatement('''
      CREATE TABLE IF NOT EXISTS jornadas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nombre TEXT NOT NULL,
        estado TEXT NOT NULL DEFAULT 'abierta',
        abierta_en TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        cerrada_en TEXT
      )
    ''');
    for (final colSql in [
      'ALTER TABLE pedidos ADD COLUMN jornada_id INTEGER',
      'ALTER TABLE pedidos ADD COLUMN referencia TEXT',
      'ALTER TABLE pedidos ADD COLUMN cliente TEXT',
      'ALTER TABLE pedidos ADD COLUMN mesero TEXT',
      'ALTER TABLE pedidos ADD COLUMN numero_turno INTEGER',
      'ALTER TABLE pedidos ADD COLUMN entregado INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE pedidos ADD COLUMN entregado_en INTEGER',
      'ALTER TABLE items_pedido ADD COLUMN entregado INTEGER NOT NULL DEFAULT 0',
    ]) {
      try {
        await customStatement(colSql);
      } catch (_) {}
    }

    final jornadasCountRow = await customSelect(
      'SELECT COUNT(*) AS cnt FROM jornadas',
    ).getSingle();
    final jornadasCount = (jornadasCountRow.data['cnt'] as int?) ?? 0;

    if (jornadasCount == 0) {
      final now = DateTime.now();
      final fechaSql =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
      final epochMs = now.millisecondsSinceEpoch;

      final jornadaId = await customInsert(
        "INSERT INTO jornadas (nombre, estado, abierta_en) VALUES (?, 'abierta', ?)",
        variables: [
          Variable<String>('Jornada ${now.day}/${now.month} (Prueba)'),
          Variable<String>(fechaSql),
        ],
      );

      final listaProductos = await select(productos).get();
      if (listaProductos.isNotEmpty) {
        final p1 = listaProductos[0];
        final p2 = listaProductos.length > 3 ? listaProductos[3] : p1;
        final pBebida = listaProductos.last;

        // Pedido 1: Mesa 1 (Abierto con productos para probar comanda y cobro)
        final pedido1Id = await customInsert(
          '''
          INSERT INTO pedidos (mesa_id, tipo, valor_domicilio, estado, creado_en, jornada_id, referencia, cliente, mesero, numero_turno, entregado)
          VALUES (NULL, 'mesa', 0, 'abierto', ?, ?, 'Mesa 1', 'Juan Pérez', 'Carlos', 1, 0)
          ''',
          variables: [Variable<int>(epochMs), Variable<int>(jornadaId)],
        );
        await into(itemsPedido).insert(
          ItemsPedidoCompanion.insert(
            pedidoId: pedido1Id,
            productoId: p1.id,
            nombreProducto: p1.nombre,
            precio: p1.precio,
            cantidad: const Value(1),
            adicionales: Value(jsonEncode(['Jugosa', 'Chicharrón crocante'])),
            nota: const Value('Bien caliente por favor'),
          ),
        );
        await into(itemsPedido).insert(
          ItemsPedidoCompanion.insert(
            pedidoId: pedido1Id,
            productoId: pBebida.id,
            nombreProducto: pBebida.nombre,
            precio: pBebida.precio,
            cantidad: const Value(2),
            adicionales: Value(jsonEncode(['Con limón'])),
          ),
        );

        // Pedido 2: Domicilio (Abierto con productos)
        final pedido2Id = await customInsert(
          '''
          INSERT INTO pedidos (mesa_id, tipo, valor_domicilio, estado, creado_en, jornada_id, referencia, cliente, mesero, numero_turno, entregado)
          VALUES (NULL, 'domicilio', 5000, 'abierto', ?, ?, 'Calle 45 #12-30 Apto 201', 'María Gómez', 'Laura', 2, 0)
          ''',
          variables: [Variable<int>(epochMs), Variable<int>(jornadaId)],
        );
        await into(itemsPedido).insert(
          ItemsPedidoCompanion.insert(
            pedidoId: pedido2Id,
            productoId: p2.id,
            nombreProducto: p2.nombre,
            precio: p2.precio,
            cantidad: const Value(1),
            adicionales: Value(jsonEncode(['Extra chimichurri'])),
            nota: const Value('Enviar cubiertos y servilletas'),
          ),
        );

        // Pedido 3: Mesa 3 (Abierto SIN productos para probar el estado vacío intuitivo)
        await customInsert(
          '''
          INSERT INTO pedidos (mesa_id, tipo, valor_domicilio, estado, creado_en, jornada_id, referencia, cliente, mesero, numero_turno, entregado)
          VALUES (NULL, 'mesa', 0, 'abierto', ?, ?, 'Mesa 3', 'Cliente nuevo', 'Andrés', 3, 0)
          ''',
          variables: [Variable<int>(epochMs), Variable<int>(jornadaId)],
        );
      }
    }

    // Marcar flag de seed completado
    if (flag == null) {
      await into(configuracion).insert(
        ConfiguracionCompanion.insert(
          clave: 'seed_datos_prueba_v1',
          valor: 'true',
        ),
      );
    }
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(name: 'barril_app');
  }
}
