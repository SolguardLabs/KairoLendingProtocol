# Contribuir a Kairo

## Flujo

1. Cree una rama desde `main`.
2. Mantenga cada cambio centrado en una única responsabilidad.
3. Añada pruebas para los límites, errores y redondeos afectados.
4. Actualice documentación e interfaces cuando cambie el contrato público.
5. Ejecute la validación completa antes de abrir una solicitud de cambios.

```bash
bash scripts/bootstrap.sh
bash scripts/ci.sh
```

## Criterios de revisión

- efecto sobre custodia, deuda, reservas e índices;
- orden de actualización de estado y llamadas externas;
- redondeo y precisión entre WAD, RAY, puntos básicos y decimales nativos;
- vigencia y normalización de precios;
- permisos, pausa y transferencia de administración;
- tamaño de runtime y compatibilidad de integración;
- eventos suficientes para reconstrucción y reconciliación.

No incluya secretos, direcciones personales ni material sensible en commits, incidencias o trazas. Los hallazgos de seguridad se comunican mediante [SECURITY.md](./SECURITY.md), no mediante una solicitud pública.
