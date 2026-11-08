# Defectos inyectados en el dataset sintético OAAF

Generado con `generar_datos_oaaf.py`, semilla 22891. Periodo 01/10/2024 – 30/09/2026.

## Cifras de control

| Concepto | Cantidad |
|---|---:|
| Filas del CSV de movimientos (con duplicados) | 51.636 |
| Movimientos únicos (id_movimiento distintos) | 50.986 |
| Viajeros distintos | 11.650 |
| Alertas en el JSON (con duplicados) | 2.022 |
| Alertas únicas | 1.999 |
| Filas del catálogo de puestos (Excel) | 9 |
| Puestos distintos | 8 |

## Defectos deliberados

| Defecto | Filas afectadas |
|---|---:|
| CSV fecha_hora en formato dd/mm/aaaa hh:mm | 3.569 |
| CSV fecha_hora en formato ISO con 'T' | 1.423 |
| CSV fecha_hora vacía o inválida (no convertible) | 30 |
| CSV puesto escrito como texto libre en vez de 'PC-CDE-PA' | 830 |
| CSV puesto escrito como texto libre en vez de 'PC-ENC-SR' | 455 |
| CSV puesto escrito como texto libre en vez de 'PC-ASU-AE' | 423 |
| CSV puesto escrito como texto libre en vez de 'PC-PJC-FS' | 170 |
| CSV puesto con código huérfano (no existe en el catálogo) | 180 |
| CSV sentido con variantes (E, S, entrada, Salida, ING, EGR...) | 2.549 |
| CSV nacionalidad vacía | 255 |
| CSV nacionalidad como nombre o en minúsculas (Brasil, argentina, bra) | 896 |
| CSV nacionalidad con código inexistente (XXX) | 40 |
| CSV motivo_viaje vacío | 357 |
| CSV motivo_viaje en mayúsculas/minúsculas o con espacios | 1.530 |
| CSV medio_transporte sin tilde (Omnibus, Aereo) | 540 |
| CSV minutos_control vacío | 510 |
| CSV minutos_control negativo o cero | 90 |
| CSV minutos_control outlier (>= 600 min) | 45 |
| CSV codigo_viajero vacío | 70 |
| CSV plazo_autorizado_dias faltante en una ENTRADA de extranjero | 102 |
| CSV filas duplicadas exactas (mismo id_movimiento) | 650 |
| JSON emitida en formato dd/mm/aaaa hh:mm | 99 |
| JSON tipo.codigo en minúsculas | 79 |
| JSON tipo.nivel con mayúsculas/acentos distintos | 59 |
| JSON id_movimiento huérfano (no existe en el CSV) | 19 |
| JSON inspeccion.resultado nulo con inspección secundaria realizada | 25 |
| JSON puesto escrito 'CDE' en vez de 'PC-CDE-PA' | 43 |
| JSON alertas duplicadas (mismo id_alerta) | 23 |
| XLSX ciudad abreviada ('CDE') | 1 |
| XLSX ciudad con espacios (' Encarnación ') | 1 |
| XLSX departamento sin tilde ('Alto Parana') | 1 |
| XLSX tipo_puesto en minúsculas ('terrestre') | 1 |
| XLSX coordenadas como texto con coma decimal | 1 |
| XLSX dotacion_personal vacía | 1 |
| XLSX puesto repetido: fila vieja con error ('Amambai') y fila corregida posterior | 1 |

Una misma fila puede tener más de un defecto. Las cantidades son de inyección; el perfilado del ETL mide lo que efectivamente queda en los archivos.
