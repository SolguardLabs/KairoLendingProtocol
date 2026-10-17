# Modelo económico

## Unidades

Kairo mantiene importes de activos en los decimales nativos del token, porcentajes en puntos básicos y tipos e índices en precisión RAY (`10^27`). Los precios se normalizan antes de combinar activos distintos.

## Participaciones de suministro

Al aportar `A` activos, el usuario recibe participaciones según el valor vigente del mercado:

```text
shares = A × totalShares / totalSupplyAssets
exchangeRate = totalSupplyAssets × RAY / totalShares
```

En el primer depósito la relación parte de una unidad. Las conversiones de entrada y salida especifican el sentido de redondeo para no entregar más activos de los representados.

## Utilización y curva de tipos

```text
availableCash = tokenBalance(pool) - totalReserves
utilization = totalBorrowAssets / (availableCash + totalBorrowAssets)
```

La curva tiene una pendiente antes de la utilización óptima y otra después:

```text
r_b(U) = base + slope1 × U / U_opt                    si U <= U_opt
r_b(U) = base + slope1 + slope2 × (U-U_opt)/(1-U_opt) si U > U_opt
r_s(U) = r_b(U) × U × (1-reserveFactor)
```

Los tipos se expresan por segundo. El índice de deuda convierte el tiempo transcurrido en crecimiento acumulado:

```text
borrowIndex(t1) = borrowIndex(t0) × (RAY + borrowRate × elapsed) / RAY
currentDebt = principal × borrowIndex(t1) / positionIndex
```

## Valoración de una cuenta

Para cada garantía se calcula el valor en una unidad común y se aplican dos factores distintos:

```text
borrowCapacity = Σ(collateralValue_i × LTV_i)
liquidationCapacity = Σ(collateralValue_i × liquidationThreshold_i)
debtValue = Σ(debt_j × price_j)
healthFactor = liquidationCapacity / debtValue
```

El LTV limita nueva deuda; el umbral de liquidación determina cuándo una posición existente deja de ser segura. La separación crea un colchón antes de la liquidación.

## Liquidación

La devolución está acotada por el factor de cierre, la deuda pendiente y la garantía disponible. La garantía entregada incorpora un incentivo:

```text
maxRepay = debt × closeFactor
seizeValue = repayValue × (BPS + liquidationBonus) / BPS
seizeAssets = seizeValue / collateralPrice
```

La cotización debe recalcularse inmediatamente antes de enviar la transacción. No es una reserva de precio ni garantiza que el estado siga siendo idéntico al minarse.

## Reservas

Una parte del interés acumulado se asigna a reservas:

```text
interest = newTotalBorrow - oldTotalBorrow
reserveAccrual = interest × reserveFactor
```

Las reservas reducen la liquidez retirable y solo pueden salir mediante el rol de tesorería. El receptor operativo se mantiene separado de la administración del mercado.

## Ejemplo simplificado

Con 1.000.000 USDC suministrados, 600.000 prestados y 20.000 en reservas:

```text
availableCash = 400.000 - 20.000 = 380.000
utilization = 600.000 / (380.000 + 600.000) = 61,22 %
```

Si la utilización óptima es 80 %, el mercado permanece en la primera pendiente. Si la deuda crece manteniendo la misma liquidez, el coste marginal aumenta y, tras el punto óptimo, lo hace con la segunda pendiente.

## Límites del modelo

Las fórmulas on-chain no sustituyen análisis de liquidez externa, correlación, latencia del oráculo ni concentración de prestatarios. Esos riesgos se incorporan mediante límites, escenarios de estrés y procedimientos de gobierno.
