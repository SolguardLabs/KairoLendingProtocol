# Política de seguridad

Kairo mantiene un proceso coordinado para recibir, evaluar y corregir hallazgos de seguridad relacionados con los contratos y herramientas de este repositorio.

## Versiones mantenidas

| Versión | Estado |
| --- | --- |
| Rama `main` | Mantenida |
| Última versión etiquetada | Mantenida |
| Versiones anteriores | Solo cuando se indique expresamente |

Los despliegues pueden incorporar parámetros o adaptadores diferentes. Incluya siempre la red, la dirección del contrato y el bloque de referencia al comunicar un hallazgo sobre una instancia concreta.

## Comunicación privada

Utilice el canal privado de avisos de seguridad del repositorio o el medio de contacto indicado por los mantenedores. No publique detalles técnicos en una incidencia, discusión, red social o canal comunitario antes de completar la coordinación.

Incluya, cuando sea posible:

- componente, versión o commit afectado;
- red, direcciones y bloque de referencia;
- condiciones previas necesarias;
- comportamiento esperado y comportamiento observado;
- impacto técnico y económico estimado;
- pasos mínimos para reproducirlo;
- trazas, pruebas o transacciones relevantes;
- cualquier medida temporal que reduzca el riesgo.

No adjunte claves privadas, frases semilla ni credenciales. Si el material contiene datos sensibles, solicite primero un canal cifrado.

## Proceso de respuesta

El equipo intentará seguir estos plazos, sin que constituyan una garantía contractual:

1. acuse de recibo en dos días laborables;
2. evaluación inicial en cinco días laborables;
3. actualización de estado al menos una vez por semana mientras continúe el análisis;
4. coordinación de corrección, despliegue y comunicación según el alcance confirmado.

La prioridad considera fondos en riesgo, permisos necesarios, reproducibilidad, alcance entre mercados y disponibilidad de medidas operativas.

## Alcance

Se consideran dentro del alcance:

- contratos incluidos en `src/`;
- contabilidad de reservas, participaciones y deuda;
- comprobaciones de garantía y liquidación;
- adaptadores de precio y modelos de tipos;
- controles de acceso, pausas y configuración de mercados;
- scripts de despliegue mantenidos en este repositorio;
- Kairo Lens y sus resultados cuando influyen en decisiones operativas.

Normalmente quedan fuera del alcance:

- copias modificadas por terceros;
- credenciales comprometidas fuera del repositorio;
- indisponibilidad de proveedores externos sin efecto sobre los contratos;
- interfaces o servicios que no estén mantenidos aquí;
- versiones sin mantenimiento;
- resultados derivados únicamente de parámetros de despliegue no recomendados.

El alcance final se determina durante la evaluación.

## Investigación responsable

Para proteger usuarios y redes:

- trabaje en una red local o bifurcación controlada siempre que sea posible;
- no acceda a datos ajenos ni degrade servicios;
- no retenga fondos que no le pertenezcan;
- limite las transacciones públicas al mínimo imprescindible;
- deténgase si una prueba puede afectar a terceros;
- preserve evidencias suficientes para una reproducción segura;
- coordine la publicación con los mantenedores.

El proyecto procurará no iniciar acciones contra investigaciones de buena fe que respeten esta política y la legislación aplicable. Esta declaración no autoriza actividades sobre sistemas de terceros ni sustituye asesoramiento jurídico.

## Dependencias y redes desplegadas

Un informe sobre una dependencia debe remitirse también a su mantenedor cuando corresponda. Si un hallazgo afecta a contratos ya desplegados, permita que el equipo prepare primero las medidas operativas necesarias.

Las direcciones oficiales, versiones y parámetros deben verificarse mediante los canales del proyecto. La presencia de código en este repositorio no confirma por sí sola que una instancia concreta esté administrada por Kairo.

## Divulgación coordinada

La fecha y el contenido de una comunicación pública se acordarán después de disponer de una corrección o de medidas razonables para proteger a los usuarios. El reconocimiento se realizará cuando la persona informante lo solicite y sea apropiado.

Gracias por contribuir a la seguridad de Kairo.
