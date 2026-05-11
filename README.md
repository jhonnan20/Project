# GOLDBOT HFT - XAUUSD Institutional AI Scalper

Expert Advisor para MetaTrader 5 optimizado para XAUUSD en timeframe M5.

## Versiones

### v13.0 (Original)
- 3 motores de senal (EMA, VWAP, UT Bot)
- Filtros: Volatilidad, Spread, Momentum, Volumen
- 3 posiciones simultaneas maximo
- Trailing stop basico

### v14.0 (Optimizado - Mas Operaciones Exitosas)
Mejoras principales:
- **+2 motores de senal nuevos**: Pullback re-entry y RSI Divergence
- **Sesiones expandidas**: Cobertura de 2:00 a 23:00 GMT (antes habia gaps)
- **Filtros relajados**: Volatilidad, volumen y momentum menos restrictivos
- **Cierre parcial en TP1**: Asegura ganancias al 50% en TP1
- **Breakeven automatico**: Mueve SL a breakeven a 0.5R
- **Trailing mejorado**: Inicia desde 0.6R con trail adaptativo
- **5 posiciones simultaneas** (antes 3)
- **Confirmacion multi-timeframe**: M15 EMA para filtrar entradas contra-tendencia
- **Todos los motores activos en todos los estados de mercado**
- **Gestion de riesgo con confidence scaling**: Boost leve cuando winrate > 65%
- **Mejor score de optimizacion**: Premia mas trades + win rate

## Instalacion

1. Copiar el archivo `.mq5` a `MQL5/Experts/`
2. Compilar en MetaEditor
3. Adjuntar al grafico XAUUSD M5
4. Configurar inputs segun preferencia

## Inputs Principales

| Input | Default | Descripcion |
|-------|---------|-------------|
| I_RiskUSD | 15.0 | Riesgo por trade en USD |
| I_MaxDailyLossPct | 4.0 | Max perdida diaria % |
| I_MaxSimultaneous | 5 | Max posiciones simultaneas |
| I_TP1_ClosePct | 50.0 | % a cerrar en TP1 |
| I_BreakevenR | 0.5 | R-multiple para mover a BE |
| I_UsePullbackEngine | true | Activar motor de pullback |
| I_UseMTF | true | Confirmacion multi-timeframe |
