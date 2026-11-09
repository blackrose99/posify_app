# 📱 POSify — Sistema POS para Restaurantes

![POSify](POSify.png)

[![Descargar APK](https://img.shields.io/badge/Descargar%20APK-v1.0.0%20(Release)-success?style=for-the-badge&logo=android&logoColor=white)](https://github.com/blackrose99/posify_app/releases/latest/download/app-release.apk)
[![GitHub Releases](https://img.shields.io/badge/GitHub-Releases-blue?style=for-the-badge&logo=github)](https://github.com/blackrose99/posify_app/releases)
[![Plataforma Android](https://img.shields.io/badge/Plataforma-Android%20%7C%20iOS%20%7C%20Escritorio-orange?style=for-the-badge&logo=flutter)](https://flutter.dev)
[![100% Offline](https://img.shields.io/badge/Modo-100%25%20Offline%20Local-purple?style=for-the-badge&logo=sqlite)](https://sqlite.org)

**POSify** es una aplicación de punto de venta (POS) y comanda móvil multiplataforma desarrollada en **Flutter**, diseñada para agilizar la gestión de pedidos, cobros, cocina, domicilios e impresión de tickets en restaurantes, bares y negocios de comida. Funciona **100% offline**, almacenando toda la información localmente en el dispositivo sin depender de internet.

---

## 📥 DESCARGA DIRECTA DE LA APK (Lista para usar)

> 🚀 **¿Eres cliente o usuario final?** No necesitas compilar el código. Puedes descargar e instalar la versión lista para usar directamente en tu celular o tablet Android:

### 🔗 Enlaces de Descarga

| Opción | Enlace |
|---|---|
| 🟢 **Descarga Directa (Recomendada)** | **[👉 Descargar app-release.apk (Última versión)](https://github.com/blackrose99/posify_app/releases/latest/download/app-release.apk)** |
| 📦 **Todas las Versiones y Novedades** | **[📂 Ver catálogo de Releases en GitHub](https://github.com/blackrose99/posify_app/releases)** |

---

### 📲 Cómo instalar en Android (Paso a paso)

1. **Descarga el archivo**: Toca el botón verde de **[Descargar app-release.apk](https://github.com/blackrose99/posify_app/releases/latest/download/app-release.apk)** desde el navegador de tu celular o tablet.
2. **Abrir el instalador**: Cuando termine la descarga, abre el archivo desde el panel de notificaciones o desde tu carpeta de **Descargas** (administrador de archivos).
3. **Permitir orígenes desconocidos**: Si Android te muestra una advertencia de seguridad, toca en **Ajustes** y activa la opción **"Permitir desde esta fuente"** (o "Instalar aplicaciones de fuentes desconocidas").
4. **Instalar / Actualizar**: Confirma tocando en **Instalar** (o **Actualizar** si ya la tenías instalada). ¡Listo! Ya puedes abrir POSify.

---

### 🛡️ ¡IMPORTANTE: Conservación de tus datos al actualizar!

> [!IMPORTANT]
> **NO desinstales la aplicación existente para actualizar a una nueva versión.**
> Si ya tienes POSify instalado con tus productos, mesas y ventas reales:
> 1. Descarga el nuevo archivo `app-release.apk`.
> 2. Ábrelo y selecciona **"Actualizar"**.
> 3. Android conservará intacta toda tu base de datos, historial y configuraciones.
>
> La aplicación utiliza migraciones automáticas no destructivas (`CREATE TABLE IF NOT EXISTS` y `ALTER TABLE`). Además, **se eliminaron todas las inserciones automáticas de datos de prueba**, garantizando que tu base de datos de producción nunca sea alterada ni reiniciada.

---

## 🌟 Novedades y Características Recientes

### 💳 Medios de Pago Parametrizables
- **Configuración centralizada**: Administra qué métodos de pago acepta tu negocio desde el panel de configuración (**Configuración** ➔ **Medios de Pago**).
- **Efectivo y Transferencias**: Activa o desactiva pagos en efectivo y transferencias electrónicas.
- **Canales de transferencia personalizados**: Configura tus cuentas activas para recibir pagos:
  - **Nequi** (número de celular / llave Bre-B).
  - **Daviplata**.
  - **Bre-B** (Llaves interoperables).
  - **Bancolombia, Dale, Movii u otras cuentas bancarias** con número, nombre de titular e identificación.
- **Cobro guiado**: Al presionar **Cobrar / Cerrar** en cualquier pedido, el sistema solicita seleccionar si el pago fue en Efectivo o por Transferencia (permitiendo elegir la cuenta de destino).

### 🧾 Datos de Pago en el Pie del Ticket de Venta
- En cada factura entregada al cliente (ticket térmico Bluetooth ESC/POS de 58mm/80mm, impresión raster o comprobante PDF), se imprimen en el pie de página (**footer**) las cuentas y números para transferir configurados, junto con un mensaje de agradecimiento.

### 📊 Desglose de Ventas en Informes de Jornada
- Consulta el balance exacto de cada turno de trabajo discriminando:
  - **Total de ventas en Efectivo** (monto y cantidad de pedidos).
  - **Total de ventas por Transferencia** (monto, cantidad de pedidos y desglose por cada cuenta: Nequi, Daviplata, Bre-B, etc.).
- Informes disponibles en pantalla, exportables a archivo **CSV** e imprimibles en formato ticket POS térmico.

### 🔍 Corrección de Fuentes Grandes y Textos Recortados
- **Escala de fuentes protegida**: Evita desbordamientos de pantalla (`RIGHT OVERFLOWED BY 12 PIXELS` o `BOTTOM OVERFLOWED`) cuando el usuario tiene configurada la fuente del celular en tamaño grande/accesibilidad.
- **Catálogo de productos legible**: Las tarjetas de productos en toma de pedidos ahora cuentan con espacio suficiente para nombres largos de hasta 2 líneas (`Personal solo chicharrón`, `Coca Cola 330ml`), precio destacado y botones cómodos de añadir (+ / -), evitando que los meseros tengan que adivinar productos con nombres cortados como `pers...` o `coca...`.
- **Filtros y botones adaptables**: Las etiquetas de pedidos abiertos, cerrados, cancelados y botones de acción se acomodan automáticamente sin recortarse.

### ⚡ Optimización de Consultas
- Consultas por lote (batch query `IN (...)`) para pedidos e ítems, eliminando tiempos de espera innecesarios y optimizando el rendimiento general del dispositivo.

---

## 📋 Funcionalidades Principales

- **Jornadas de trabajo** — Abre y cierra sesiones diarias con control de base inicial, conteo de pedidos y arqueo de caja.
- **Pedidos de mesa y domicilio** — Diferencia pedidos de mesa vs. domicilio, con turnos secuenciales, referencia, mesero asignado y estado de preparación.
- **Comanda para cocina** — Imprime tickets específicos de cocina con los productos y adicionales solicitados.
- **Impresión Bluetooth ESC/POS** — Conexión directa a impresoras térmicas portátiles o de mostrador de 58mm y 80mm.
- **Exportación y Backup** — Exportación de reportes a CSV y respaldo de base de datos local SQLite.

---

## 🛠️ Stack Tecnológico

| Capa | Tecnología |
|---|---|
| **Framework** | Flutter 3.x (Dart) |
| **Arquitectura** | Clean Architecture (Domain / Data / Presentation) |
| **Gestión de Estado** | Riverpod + riverpod_generator |
| **Base de Datos Local** | Drift (SQLite ORM) con esquema protegido |
| **Inyección de Dependencias** | GetIt |
| **Impresión Bluetooth** | flutter_blue_plus + esc_pos_utils_plus |
| **Documentos y Tickets** | pdf + printing |
| **Exportación** | csv + share_plus |

---

## 🏗️ Para Desarrolladores

### Requisitos previos
- Flutter SDK (versión 3.24 o superior recomendada)
- Android SDK instalado y configurado

### Instalación local del código fuente
```bash
# Clonar el repositorio
git clone https://github.com/blackrose99/posify_app.git
cd posify_app

# Descargar dependencias
flutter pub get

# Generar código de Drift y Riverpod (si se modifican entidades)
dart run build_runner build --delete-conflicting-outputs

# Ejecutar en emulador o dispositivo conectado
flutter run
```

### Compilar nuevo APK Release
Para generar el archivo APK de producción que se subirá a GitHub Releases:
```bash
flutter build apk --release
```
El archivo compilado se genera en:
`build/app/outputs/flutter-apk/app-release.apk`

---

## 📄 Licencia

Este proyecto está protegido bajo derechos de autor. Consulta los términos de uso antes de su distribución comercial.
