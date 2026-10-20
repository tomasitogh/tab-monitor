# Latencia

Objetivo: promedio menor a 45 ms desde que algo cambia en la Mac hasta que se ve en la tablet,
p95 menor a 60 ms y nunca más de 80 ms durante 10 minutos de uso real.

## Línea de base

| Qué | Promedio | p95 | Máximo | Cómo se midió | Fecha |
|---|---|---|---|---|---|
| Duet Display (prueba gratis), por cable | — | — | — | filmación en cámara lenta | — |

## Presupuesto estimado

| Tramo | Estimación | Medido |
|---|---|---|
| Captura + codificación en la Mac | 8–20 ms | — |
| Cable USB con adb | 1–3 ms | — |
| Decodificación en la tablet | 5–15 ms | — |
| Mostrar en pantalla | 0–17 ms | — |

## Registro de cambios

Cada cambio que afecte la latencia, con su medición antes y después.

| Fecha | Cambio | Antes (prom / p95) | Después (prom / p95) | Notas |
|---|---|---|---|---|
