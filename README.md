# POSify — Sistema POS para Restaurantes

![POSify](POSify.png)

**POSify** es una aplicación de punto de venta (POS) multiplataforma desarrollada en **Flutter**, diseñada para la gestión completa de pedidos en restaurantes y negocios de comida. Permite manejar jornadas de trabajo, pedidos de mesa y domicilio, catálogo de productos, impresión de tickets y reportes de ventas, todo desde un dispositivo móvil o de escritorio.

---

## Funcionalidades principales

- **Jornadas de trabajo** — Abre y cierra sesiones de trabajo diarias. Cada jornada agrupa todos los pedidos del turno y muestra un resumen de ventas al cerrar.
- **Pedidos de mesa y domicilio** — Crea pedidos diferenciando entre consumo en mesa y entregas a domicilio. Cada pedido lleva número de turno, referencia, datos del cliente y mesero asignado.
- **Catálogo de productos** — Gestión de productos organizados por categorías, con soporte para adicionales y precios personalizables.
- **Gestión de meseros** — Registro de meseros para asignarlos a los pedidos.
- **Impresión de tickets** — Generación e impresión de tickets vía **Bluetooth** a impresoras térmicas (protocolo ESC/POS), con vista previa y opción de guardar como PDF.
- **Historial y reportes** — Consulta el historial de jornadas cerradas filtrado por día, semana o mes. Visualiza totales de productos vendidos, domicilios, pedidos cancelados y resumen de ventas.
- **Exportación y backup** — Exporta datos a CSV y realiza copias de seguridad de la base de datos local.
- **Configuración del negocio** — Nombre del negocio, valor del domicilio, configuración de impresora y administración del catálogo desde un panel de administración integrado.

---

## Stack tecnológico

| Capa | Tecnología |
|---|---|
| Framework | Flutter (Dart) |
| Estado | Riverpod + riverpod_generator |
| Base de datos | Drift (SQLite ORM) con code generation |
| Inyección de dependencias | GetIt |
| Impresión Bluetooth | flutter_blue_plus + esc_pos_utils_plus |
| Generación de PDF | pdf + printing |
| Compartir archivos | share_plus |
| Exportación CSV | csv |
| Arquitectura | Clean Architecture (domain / data / presentation) |

---

## Arquitectura

El proyecto sigue los principios de **Clean Architecture** organizado por features:

```
lib/
├── core/              # Utilidades, constantes, errores, servicios compartidos
├── database/          # Tablas y configuración de Drift (SQLite)
└── features/
    ├── facturacion/   # Entidades de factura
    ├── impresion/     # Servicio Bluetooth, builder de tickets, PDF
    ├── pedidos/       # Jornadas, pedidos, mesas — capa de datos, dominio y UI
    └── productos/     # Catálogo de productos, categorías y adicionales
```

Cada feature separa claramente las capas de **dominio** (entidades y casos de uso), **datos** (repositorios y fuentes locales) y **presentación** (providers de Riverpod y pantallas Flutter).

---

## Plataformas soportadas

Android · iOS · Web · Windows · macOS · Linux

---

## Instalación local

```bash
# Clonar el repositorio
git clone <url-del-repo>
cd barril_app

# Instalar dependencias
flutter pub get

# Generar código (Drift + Riverpod)
dart run build_runner build --delete-conflicting-outputs

# Ejecutar
flutter run
```

Requiere Flutter 3.x o superior.

---

## Sobre el proyecto

Este proyecto nació como solución real para un restaurante de carnes, con el objetivo de reemplazar el proceso manual de toma de pedidos en papel. Fue desarrollado completamente desde cero priorizando una experiencia de uso rápida en dispositivos táctiles, funcionamiento **100% offline** con base de datos local, y la capacidad de imprimir tickets directamente desde el celular del cajero o mesero.
