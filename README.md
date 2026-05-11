# GOLDBOT HFT - XAUUSD Institutional AI Scalper

Expert Advisor para MetaTrader 5 optimizado para XAUUSD en timeframe M5.

## Versiones

### v13.0 (Original)
- 3 motores de senal (EMA, VWAP, UT Bot)
- Filtros: Volatilidad, Spread, Momentum, Volumen
- 3 posiciones simultaneas maximo
- Trailing stop basico

### v14.0 (Optimizado - Mas Operaciones)
- +2 motores de senal nuevos: Pullback re-entry y RSI Divergence
- Sesiones expandidas: 2:00-23:00 GMT
- Filtros relajados para mas senales
- Cierre parcial en TP1, breakeven automatico
- 5 posiciones simultaneas

### v15.0 (PROFIT MACHINE - Fix de Rentabilidad)
**Problema detectado en backtesting v14:**
- Win rate 70.21% (excelente) pero perdida neta de -$7,343
- Avg Win: $55.46 vs Avg Loss: $137.55 (ratio 2.48x)
- Las perdidas eran demasiado grandes comparadas con las ganancias

**Fixes criticos:**
- **SL max 1.0 ATR** (era 1.5) - reduce perdida promedio ~33%
- **TP2 a 4.0R** (era 3.0) - deja correr los ganadores mas
- **TP1 parcial solo 35%** (era 50%) - mantiene mas volumen en runners
- **Breakeven a 0.3R** (era 0.5) - protege capital mas rapido
- **Cooldown automatico** despues de 3 perdidas consecutivas
- **Salida por tiempo** (25 min) para trades estancados
- **Filtro de calidad de vela** (body > 40% del rango)
- **Anti-reversal** no abre opuesto a la ultima perdida
- **Lot sizing agresivo** +25% en rachas ganadoras, -40% en perdedoras
- **Trailing mas agresivo** desde 0.5R con trail adaptativo

## Instalacion

1. Copiar `GOLDBOT_HFT_v15.mq5` a `MQL5/Experts/`
2. Compilar en MetaEditor
3. Adjuntar al grafico XAUUSD M5
4. Configurar inputs segun preferencia

## Inputs Principales v15.0

| Input | Default | Descripcion |
|-------|---------|-------------|
| I_RiskUSD | 15.0 | Riesgo por trade en USD |
| I_MaxDailyLossPct | 3.5 | Max perdida diaria % |
| I_MaxSimultaneous | 4 | Max posiciones simultaneas |
| I_TP1_R | 1.2 | R-multiple para TP1 |
| I_TP2_R | 4.0 | R-multiple para TP2 (dejar correr) |
| I_TP1_ClosePct | 35.0 | % a cerrar en TP1 |
| I_BreakevenR | 0.3 | R-multiple para mover a BE |
| I_SL_MaxATR | 1.0 | Max SL en multiplos de ATR |
| I_CooldownBars | 2 | Barras de pausa tras perdidas consecutivas |
| I_MaxStaleMinutes | 25 | Cerrar trades estancados despues de X min |
| I_MaxConsecLoss | 3 | Perdidas consecutivas antes de cooldown |
| I_UseCandleQuality | true | Filtro de calidad de vela |
| I_UseAntiReversal | true | Anti-whipsaw en reversales |
