//+------------------------------------------------------------------+
//|                 GOLDBOT HFT v15.0 - PROFIT MACHINE               |
//|          XAUUSD M5 - Institutional AI Scalper Engine             |
//|          PROFITABILITY FIX: Tighter SL + Wider TP + Smart Mgmt   |
//|                     MetaTrader 5 Build 3800+                     |
//+------------------------------------------------------------------+
//
// v15.0 CHANGELOG (vs v14 backtest results):
// PROBLEM: 70% win rate but avg loss ($137) was 2.48x avg win ($55)
//          => Negative expected value per trade
// 
// FIXES:
// 1. SL capped at 1.0 ATR (was 1.5) - reduces avg loss by ~33%
// 2. TP2 raised to 4.0R (was 3.0) - lets winners run further
// 3. TP1 partial close reduced to 35% (was 50%) - keeps more on runners
// 4. Faster breakeven at 0.3R (was 0.5) - protects capital sooner
// 5. Cooldown after 3 consecutive losses (pause 2 bars)
// 6. Time-based exit: close flat trades after 25 minutes
// 7. Candle quality filter: body must be > 40% of range
// 8. Stronger EMA slope requirement (0.04)
// 9. Adaptive lot sizing: scale up on winning streaks
// 10. Anti-reversal filter: don't open opposite to recent loser
//+------------------------------------------------------------------+

#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// ENUMS
//==================================================================

enum MARKET_STATE
{
   STATE_RANGE,
   STATE_TREND,
   STATE_EXPANSION
};

//==================================================================
// INPUTS
//==================================================================

input group "=== RISK MANAGEMENT ===================================="
input double I_RiskUSD               = 15.0;
input double I_MaxDailyLossPct       = 3.5;      // Tighter daily loss limit
input int    I_MaxSimultaneous       = 4;         // Reduced to 4 for quality
input int    I_Magic                 = 15000;

input group "=== EMA ENGINE ========================================"
input int    I_EMA_Fast              = 5;
input int    I_EMA_Mid               = 13;
input int    I_EMA_Slow              = 34;
input double I_EMA_SlopeMin          = 0.04;      // Slightly stricter

input group "=== VWAP ENGINE ======================================="
input int    I_RSI_Period            = 14;
input int    I_VWAP_Bars             = 50;

input group "=== UT ENGINE ========================================="
input int    I_ATR_Period            = 14;
input double I_UT_ATR_Mult           = 1.3;

input group "=== TP / SL ENGINE ===================================="
input double I_TP1_R                 = 1.2;       // TP1 at 1.2R (was 1.0)
input double I_TP2_R                 = 4.0;       // TP2 at 4.0R (was 3.0) - let winners RUN
input double I_TP1_ClosePct          = 35.0;      // Only close 35% at TP1 (was 50%)
input double I_TrailATR              = 0.6;
input double I_BreakevenR            = 0.3;       // Faster BE at 0.3R (was 0.5)
input double I_SL_MaxATR             = 1.0;       // CRITICAL: Max SL = 1.0 ATR (was 1.5)
input double I_SL_MinATR             = 0.3;       // Min SL

input group "=== HFT FILTERS ======================================="
input bool   I_UseVolatilityFilter   = true;
input bool   I_UseSpreadFilter       = true;
input bool   I_UseMomentumFilter     = true;
input bool   I_UseVolumeFilter       = true;
input bool   I_UseCandleQuality      = true;      // NEW: Candle body quality filter

input group "=== SESSIONS =========================================="
input bool   I_Asia                  = true;
input bool   I_London                = true;
input bool   I_NewYork               = true;
input bool   I_LateNY               = true;

input group "=== PULLBACK ENGINE ==================================="
input bool   I_UsePullbackEngine     = true;
input double I_PullbackDepth         = 0.382;

input group "=== MULTI-TIMEFRAME ==================================="
input bool   I_UseMTF                = true;
input int    I_MTF_EMA_Period        = 21;

input group "=== TRADE PROTECTION =================================="
input int    I_CooldownBars          = 2;         // NEW: Pause X bars after 3 consecutive losses
input int    I_MaxStaleMinutes       = 25;        // NEW: Close trade if flat after X minutes
input double I_StaleThresholdATR     = 0.15;      // NEW: "Flat" = profit < this * ATR
input int    I_MaxConsecLoss         = 3;         // NEW: Consecutive losses before cooldown
input bool   I_UseAntiReversal       = true;      // NEW: Don't open opposite to recent loser

//==================================================================
// HANDLES
//==================================================================

int hEMAFast;
int hEMAMid;
int hEMASlow;
int hATR;
int hRSI;
int hATR_M15;
int hEMA_M15;

//==================================================================
// GLOBALS
//==================================================================

datetime g_lastBar         = 0;
double   g_dayBalance      = 0;
bool     g_halt            = false;
double   g_utBuy           = 0.0;
double   g_utSell          = 0.0;
int      g_dailyTrades     = 0;
int      g_dailyWins       = 0;
int      g_dailyLosses     = 0;
datetime g_lastEntryTime   = 0;
int      g_consecLosses    = 0;       // Consecutive loss counter
datetime g_cooldownUntil   = 0;       // Cooldown expiry
int      g_lastLossDir     = 0;       // Direction of last losing trade
double   g_dailyProfit     = 0;       // Track daily P/L for scaling

//==================================================================
// INIT
//==================================================================

int OnInit()
{
   trade.SetExpertMagicNumber(I_Magic);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   hEMAFast = iMA(_Symbol, PERIOD_M5, I_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMAMid  = iMA(_Symbol, PERIOD_M5, I_EMA_Mid, 0, MODE_EMA, PRICE_CLOSE);
   hEMASlow = iMA(_Symbol, PERIOD_M5, I_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hATR     = iATR(_Symbol, PERIOD_M5, I_ATR_Period);
   hRSI     = iRSI(_Symbol, PERIOD_M5, I_RSI_Period, PRICE_CLOSE);
   hATR_M15 = iATR(_Symbol, PERIOD_M15, I_ATR_Period);
   hEMA_M15 = iMA(_Symbol, PERIOD_M15, I_MTF_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(hEMAFast == INVALID_HANDLE ||
      hEMAMid  == INVALID_HANDLE ||
      hEMASlow == INVALID_HANDLE ||
      hATR     == INVALID_HANDLE ||
      hRSI     == INVALID_HANDLE ||
      hATR_M15 == INVALID_HANDLE ||
      hEMA_M15 == INVALID_HANDLE)
      return INIT_FAILED;

   Print("GOLDBOT v15.0 PROFIT MACHINE INITIALIZED");
   return INIT_SUCCEEDED;
}

//==================================================================
// DEINIT
//==================================================================

void OnDeinit(const int reason)
{
   if(hEMAFast != INVALID_HANDLE)  IndicatorRelease(hEMAFast);
   if(hEMAMid  != INVALID_HANDLE)  IndicatorRelease(hEMAMid);
   if(hEMASlow != INVALID_HANDLE)  IndicatorRelease(hEMASlow);
   if(hATR     != INVALID_HANDLE)  IndicatorRelease(hATR);
   if(hRSI     != INVALID_HANDLE)  IndicatorRelease(hRSI);
   if(hATR_M15 != INVALID_HANDLE)  IndicatorRelease(hATR_M15);
   if(hEMA_M15 != INVALID_HANDLE)  IndicatorRelease(hEMA_M15);

   Print("GOLDBOT v15.0 Session: Trades=", g_dailyTrades,
         " Wins=", g_dailyWins, " Losses=", g_dailyLosses);
}

//==================================================================
// BUFFER VALUE
//==================================================================

double BV(int handle, int shift)
{
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, 0, shift, 1, arr) <= 0)
      return 0.0;
   return arr[0];
}

//==================================================================
// VWAP
//==================================================================

double VWAP()
{
   double hi[], lo[], cl[];
   long vol[];

   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   ArraySetAsSeries(cl, true);
   ArraySetAsSeries(vol, true);

   if(CopyHigh(_Symbol, PERIOD_M5, 1, I_VWAP_Bars, hi) <= 0)   return 0;
   if(CopyLow(_Symbol, PERIOD_M5, 1, I_VWAP_Bars, lo) <= 0)    return 0;
   if(CopyClose(_Symbol, PERIOD_M5, 1, I_VWAP_Bars, cl) <= 0)   return 0;
   if(CopyTickVolume(_Symbol, PERIOD_M5, 1, I_VWAP_Bars, vol) <= 0) return 0;

   double pv = 0;
   double tv = 0;

   for(int i = 0; i < I_VWAP_Bars; i++)
   {
      double tp = (hi[i] + lo[i] + cl[i]) / 3.0;
      pv += tp * vol[i];
      tv += vol[i];
   }

   if(tv <= 0)
      return cl[0];

   return pv / tv;
}

//==================================================================
// MARKET REGIME
//==================================================================

MARKET_STATE GetMarketState()
{
   double atr     = BV(hATR, 1);
   double atrSlow = BV(hATR, 10);
   double ef      = BV(hEMAFast, 1);
   double es      = BV(hEMASlow, 1);
   double trend   = MathAbs(ef - es);

   if(trend > atr * 1.0)
      return STATE_TREND;

   if(atr > atrSlow * 1.2)
      return STATE_EXPANSION;

   return STATE_RANGE;
}

//==================================================================
// MULTI-TIMEFRAME TREND
//==================================================================

int MTF_Trend()
{
   if(!I_UseMTF)
      return 0;

   double ema15   = BV(hEMA_M15, 1);
   double price15 = iClose(_Symbol, PERIOD_M15, 1);

   if(price15 > ema15) return 1;
   if(price15 < ema15) return -1;
   return 0;
}

//==================================================================
// VOLATILITY FILTER
//==================================================================

bool VolatilityFilter()
{
   if(!I_UseVolatilityFilter)
      return true;

   double atrNow = BV(hATR, 1);

   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(hATR, 0, 1, 40, arr) <= 0)
      return false;

   double avg = 0;
   for(int i = 0; i < 40; i++)
      avg += arr[i];
   avg /= 40.0;

   if(atrNow < avg * 0.85)
      return false;

   double body = MathAbs(
      iClose(_Symbol, PERIOD_M5, 1) -
      iOpen(_Symbol, PERIOD_M5, 1)
   );

   if(body < atrNow * 0.20)
      return false;

   return true;
}

//==================================================================
// VOLUME FILTER
//==================================================================

bool InstitutionalVolume()
{
   if(!I_UseVolumeFilter)
      return true;

   long vol[];
   ArraySetAsSeries(vol, true);
   if(CopyTickVolume(_Symbol, PERIOD_M5, 1, 30, vol) <= 0)
      return false;

   double avg = 0;
   for(int i = 5; i < 30; i++)
      avg += vol[i];
   avg /= 25.0;

   return vol[1] > avg * 1.15;
}

//==================================================================
// SPREAD FILTER
//==================================================================

bool SpreadOK()
{
   if(!I_UseSpreadFilter)
      return true;

   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double atr = BV(hATR, 1);
   double maxSpread = (atr / _Point) * 0.15;

   return spread <= maxSpread;
}

//==================================================================
// CANDLE QUALITY FILTER (NEW)
// Requires candle body to be significant portion of range
// Filters out doji/indecision candles that lead to whipsaw
//==================================================================

bool CandleQualityBuy()
{
   if(!I_UseCandleQuality)
      return true;

   double open1  = iOpen(_Symbol, PERIOD_M5, 1);
   double close1 = iClose(_Symbol, PERIOD_M5, 1);
   double high1  = iHigh(_Symbol, PERIOD_M5, 1);
   double low1   = iLow(_Symbol, PERIOD_M5, 1);

   double body  = close1 - open1;  // Positive for bullish
   double range = high1 - low1;

   if(range <= 0) return false;

   // Must be bullish candle with body > 40% of range
   if(body <= 0) return false;
   if(body / range < 0.40) return false;

   // Upper wick should not be excessive (< 30% of range)
   double upperWick = high1 - close1;
   if(upperWick / range > 0.30) return false;

   return true;
}

bool CandleQualitySell()
{
   if(!I_UseCandleQuality)
      return true;

   double open1  = iOpen(_Symbol, PERIOD_M5, 1);
   double close1 = iClose(_Symbol, PERIOD_M5, 1);
   double high1  = iHigh(_Symbol, PERIOD_M5, 1);
   double low1   = iLow(_Symbol, PERIOD_M5, 1);

   double body  = open1 - close1;  // Positive for bearish
   double range = high1 - low1;

   if(range <= 0) return false;

   if(body <= 0) return false;
   if(body / range < 0.40) return false;

   // Lower wick should not be excessive
   double lowerWick = close1 - low1;
   if(lowerWick / range > 0.30) return false;

   return true;
}

//==================================================================
// MOMENTUM (2 of 3 candles)
//==================================================================

bool MomentumBuy()
{
   if(!I_UseMomentumFilter)
      return true;

   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double c2 = iClose(_Symbol, PERIOD_M5, 2);
   double c3 = iClose(_Symbol, PERIOD_M5, 3);

   int score = 0;
   if(c1 > c2) score++;
   if(c2 > c3) score++;
   if(c1 > c3) score++;

   return score >= 2;
}

bool MomentumSell()
{
   if(!I_UseMomentumFilter)
      return true;

   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double c2 = iClose(_Symbol, PERIOD_M5, 2);
   double c3 = iClose(_Symbol, PERIOD_M5, 3);

   int score = 0;
   if(c1 < c2) score++;
   if(c2 < c3) score++;
   if(c1 < c3) score++;

   return score >= 2;
}

//==================================================================
// SESSION FILTER
//==================================================================

bool InSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int hm = dt.hour * 100 + dt.min;

   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;

   if(hm >= 2300 || hm < 200)
      return false;

   if(I_Asia && hm >= 200 && hm < 800)
      return true;

   if(I_London && hm >= 700 && hm < 1300)
      return true;

   if(I_NewYork && hm >= 1200 && hm < 2000)
      return true;

   if(I_LateNY && hm >= 2000 && hm < 2300)
      return true;

   return false;
}

//==================================================================
// ENTRY SPACING (min 3 minutes between entries)
//==================================================================

bool EntrySpacingOK()
{
   if(g_lastEntryTime == 0)
      return true;
   return (TimeCurrent() - g_lastEntryTime) >= 180;
}

//==================================================================
// COOLDOWN CHECK (NEW)
// After I_MaxConsecLoss consecutive losses, pause I_CooldownBars bars
//==================================================================

bool CooldownOK()
{
   if(g_cooldownUntil == 0)
      return true;
   return TimeCurrent() >= g_cooldownUntil;
}

//==================================================================
// ANTI-REVERSAL CHECK (NEW)
// Don't immediately open in the opposite direction of a recent loss
//==================================================================

bool AntiReversalOK(int dir)
{
   if(!I_UseAntiReversal)
      return true;

   if(g_lastLossDir == 0)
      return true;

   // If last loss was BUY, don't immediately SELL (and vice versa)
   // This prevents whipsaw where bot keeps flipping direction and losing
   if(g_lastLossDir == -dir && g_consecLosses >= 2)
      return false;

   return true;
}

//==================================================================
// DYNAMIC RISK (IMPROVED - aggressive when winning)
//==================================================================

double DynamicRisk()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = ((balance - equity) / balance) * 100.0;

   double risk = I_RiskUSD;

   // Drawdown protection
   if(dd >= 2) risk *= 0.70;
   if(dd >= 4) risk *= 0.50;
   if(dd >= 6) risk *= 0.25;

   // Scale UP when on a winning streak with low drawdown
   if(g_dailyTrades > 5 && dd < 0.5)
   {
      double winRate = (double)g_dailyWins / g_dailyTrades;
      if(winRate > 0.70)
         risk *= 1.25;      // +25% boost on hot streak
      else if(winRate > 0.60)
         risk *= 1.10;      // +10% boost
   }

   // Scale DOWN after consecutive losses
   if(g_consecLosses >= 2)
      risk *= 0.75;
   if(g_consecLosses >= 3)
      risk *= 0.60;

   return risk;
}

//==================================================================
// LOT SIZE
//==================================================================

double LotSize(double slDist)
{
   double riskUSD = DynamicRisk();

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0)
      return 0.01;

   double lot  = riskUSD / (slDist / tickSize * tickValue);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);

   return lot;
}

//==================================================================
// SL CALCULATION (CRITICAL FIX - much tighter SL)
// Problem: avg loss was $137 vs avg win $55 (2.48x ratio)
// Fix: Cap SL at 1.0 ATR max, use 3-bar structure
//==================================================================

double SLBuy()
{
   double low1 = iLow(_Symbol, PERIOD_M5, 1);
   double low2 = iLow(_Symbol, PERIOD_M5, 2);
   double low3 = iLow(_Symbol, PERIOD_M5, 3);
   double atr  = BV(hATR, 1);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double swingLow = MathMin(low1, MathMin(low2, low3));
   double slDist = (ask - swingLow) + (atr * 0.10);

   // CRITICAL: Cap at I_SL_MaxATR (default 1.0 ATR)
   if(slDist > atr * I_SL_MaxATR)
      slDist = atr * I_SL_MaxATR;

   // Min SL to avoid stops that are too tight
   if(slDist < atr * I_SL_MinATR)
      slDist = atr * I_SL_MinATR;

   return slDist;
}

double SLSell()
{
   double high1 = iHigh(_Symbol, PERIOD_M5, 1);
   double high2 = iHigh(_Symbol, PERIOD_M5, 2);
   double high3 = iHigh(_Symbol, PERIOD_M5, 3);
   double atr   = BV(hATR, 1);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double swingHigh = MathMax(high1, MathMax(high2, high3));
   double slDist = (swingHigh - bid) + (atr * 0.10);

   if(slDist > atr * I_SL_MaxATR)
      slDist = atr * I_SL_MaxATR;

   if(slDist < atr * I_SL_MinATR)
      slDist = atr * I_SL_MinATR;

   return slDist;
}

//==================================================================
// TOTAL POSITIONS
//==================================================================

int TotalPositions()
{
   int total = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk))                    continue;
      if(PositionGetInteger(POSITION_MAGIC) != I_Magic)  continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
      total++;
   }
   return total;
}

//==================================================================
// COUNT DIRECTIONAL POSITIONS
//==================================================================

int CountDirectionalPositions(int dir)
{
   int total = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk))                    continue;
      if(PositionGetInteger(POSITION_MAGIC) != I_Magic)  continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(dir == 1 && type == POSITION_TYPE_BUY)   total++;
      if(dir == -1 && type == POSITION_TYPE_SELL)  total++;
   }
   return total;
}

//==================================================================
// OPEN TRADE
//==================================================================

void OpenTrade(int dir, double slDist, string signalName)
{
   if(TotalPositions() >= I_MaxSimultaneous)
      return;

   // Max 3 positions in same direction
   if(CountDirectionalPositions(dir) >= 3)
      return;

   if(!EntrySpacingOK())
      return;

   if(!CooldownOK())
      return;

   if(!AntiReversalOK(dir))
      return;

   // Candle quality check
   if(dir == 1 && !CandleQualityBuy()) return;
   if(dir == -1 && !CandleQualitySell()) return;

   // MTF confirmation
   int mtf = MTF_Trend();
   if(I_UseMTF && mtf != 0)
   {
      if(dir == 1 && mtf == -1) return;
      if(dir == -1 && mtf == 1) return;
   }

   double lot = LotSize(slDist);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double tpDist = slDist * I_TP2_R;
   bool ok = false;

   if(dir == 1)
   {
      ok = trade.Buy(lot, _Symbol, ask, ask - slDist, ask + tpDist);
   }
   else
   {
      ok = trade.Sell(lot, _Symbol, bid, bid + slDist, bid - tpDist);
   }

   if(ok)
   {
      g_lastEntryTime = TimeCurrent();
      g_dailyTrades++;
      Print("OPEN ", (dir == 1 ? "BUY" : "SELL"),
            " [", signalName, "] LOT=", lot,
            " SL=", slDist, " TP=", tpDist,
            " ConsecLoss=", g_consecLosses);
   }
}

//==================================================================
// EMA ENGINE
//==================================================================

void SignalEMA()
{
   double ef  = BV(hEMAFast, 1);
   double em  = BV(hEMAMid, 1);
   double es  = BV(hEMASlow, 1);
   double ef2 = BV(hEMAFast, 2);

   double atr = BV(hATR, 1);
   double slope = MathAbs(ef - ef2) / atr;

   if(slope < I_EMA_SlopeMin)
      return;

   bool crossBuy  = (ef2 <= em && ef > em && em > es);
   bool alignBuy  = (ef > em && em > es && slope > I_EMA_SlopeMin * 2.5);

   bool crossSell = (ef2 >= em && ef < em && em < es);
   bool alignSell = (ef < em && em < es && slope > I_EMA_SlopeMin * 2.5);

   bool buy  = crossBuy || alignBuy;
   bool sell = crossSell || alignSell;

   if(buy)
   {
      if(!MomentumBuy()) return;
      if(!InstitutionalVolume()) return;
      OpenTrade(1, SLBuy(), "EMA");
   }

   if(sell)
   {
      if(!MomentumSell()) return;
      if(!InstitutionalVolume()) return;
      OpenTrade(-1, SLSell(), "EMA");
   }
}

//==================================================================
// VWAP ENGINE
//==================================================================

void SignalVWAP()
{
   double price = iClose(_Symbol, PERIOD_M5, 1);
   double vwap  = VWAP();
   double rsi   = BV(hRSI, 1);
   double atr   = BV(hATR, 1);
   double dist  = (price - vwap) / atr;

   bool buy  = (dist > -0.4 && dist < 1.3 && rsi > 47 && rsi < 73);
   bool sell = (dist < 0.4 && dist > -1.3 && rsi > 27 && rsi < 53);

   if(buy)
   {
      if(!MomentumBuy()) return;
      if(!InstitutionalVolume()) return;
      OpenTrade(1, SLBuy(), "VWAP");
   }

   if(sell)
   {
      if(!MomentumSell()) return;
      if(!InstitutionalVolume()) return;
      OpenTrade(-1, SLSell(), "VWAP");
   }
}

//==================================================================
// UT BOT
//==================================================================

bool UTBuy(double atr, double price)
{
   double k = atr * I_UT_ATR_Mult;

   if(g_utBuy <= 0)
      g_utBuy = price - k;

   g_utBuy = (price > g_utBuy)
      ? MathMax(g_utBuy, price - k)
      : price - k;

   return price > g_utBuy;
}

bool UTSell(double atr, double price)
{
   double k = atr * I_UT_ATR_Mult;

   if(g_utSell <= 0)
      g_utSell = price + k;

   g_utSell = (price < g_utSell)
      ? MathMin(g_utSell, price + k)
      : price + k;

   return price < g_utSell;
}

//==================================================================
// UT ENGINE
//==================================================================

void SignalUT()
{
   double atr   = BV(hATR, 1);
   double price = iClose(_Symbol, PERIOD_M5, 1);

   bool buy  = UTBuy(atr, price);
   bool sell = UTSell(atr, price);

   double ef = BV(hEMAFast, 1);
   double em = BV(hEMAMid, 1);

   if(buy && ef > em)
   {
      if(!MomentumBuy()) return;
      if(!InstitutionalVolume()) return;
      OpenTrade(1, SLBuy(), "UT");
   }

   if(sell && ef < em)
   {
      if(!MomentumSell()) return;
      if(!InstitutionalVolume()) return;
      OpenTrade(-1, SLSell(), "UT");
   }
}

//==================================================================
// PULLBACK ENGINE
//==================================================================

void SignalPullback()
{
   if(!I_UsePullbackEngine)
      return;

   double ef  = BV(hEMAFast, 1);
   double em  = BV(hEMAMid, 1);
   double es  = BV(hEMASlow, 1);
   double atr = BV(hATR, 1);
   double rsi = BV(hRSI, 1);

   bool uptrend   = (ef > em && em > es);
   bool downtrend = (ef < em && em < es);

   double price = iClose(_Symbol, PERIOD_M5, 1);
   double high5 = 0, low5 = 999999;

   for(int i = 1; i <= 5; i++)
   {
      double h = iHigh(_Symbol, PERIOD_M5, i);
      double l = iLow(_Symbol, PERIOD_M5, i);
      if(h > high5) high5 = h;
      if(l < low5)  low5  = l;
   }

   double range = high5 - low5;
   if(range <= 0) return;

   if(uptrend)
   {
      double pullback = (high5 - price) / range;
      if(pullback >= I_PullbackDepth * 0.8 && pullback <= I_PullbackDepth * 1.5)
      {
         if(rsi > 42 && rsi < 63)
         {
            if(iClose(_Symbol, PERIOD_M5, 1) > iOpen(_Symbol, PERIOD_M5, 1))
            {
               OpenTrade(1, SLBuy(), "PULLBACK");
            }
         }
      }
   }

   if(downtrend)
   {
      double pullback = (price - low5) / range;
      if(pullback >= I_PullbackDepth * 0.8 && pullback <= I_PullbackDepth * 1.5)
      {
         if(rsi > 37 && rsi < 58)
         {
            if(iClose(_Symbol, PERIOD_M5, 1) < iOpen(_Symbol, PERIOD_M5, 1))
            {
               OpenTrade(-1, SLSell(), "PULLBACK");
            }
         }
      }
   }
}

//==================================================================
// RSI DIVERGENCE ENGINE
//==================================================================

void SignalRSIDivergence()
{
   double rsi1 = BV(hRSI, 1);
   double rsi5 = BV(hRSI, 5);

   double low1  = iLow(_Symbol, PERIOD_M5, 1);
   double low5  = iLow(_Symbol, PERIOD_M5, 5);
   double high1 = iHigh(_Symbol, PERIOD_M5, 1);
   double high5 = iHigh(_Symbol, PERIOD_M5, 5);

   double ef = BV(hEMAFast, 1);
   double em = BV(hEMAMid, 1);

   // Bullish divergence
   if(low1 < low5 && rsi1 > rsi5 && rsi1 < 45 && ef > em)
   {
      if(!InstitutionalVolume()) return;
      OpenTrade(1, SLBuy(), "RSI_DIV");
   }

   // Bearish divergence
   if(high1 > high5 && rsi1 < rsi5 && rsi1 > 55 && ef < em)
   {
      if(!InstitutionalVolume()) return;
      OpenTrade(-1, SLSell(), "RSI_DIV");
   }
}

//==================================================================
// PARTIAL CLOSE AT TP1
//==================================================================

void PartialCloseTP1()
{
   if(I_TP1_ClosePct <= 0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk))                    continue;
      if(PositionGetInteger(POSITION_MAGIC) != I_Magic)  continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;

      int    type = (int)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double vol  = PositionGetDouble(POSITION_VOLUME);

      double current = (type == POSITION_TYPE_BUY)
         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double slDist = MathAbs(open - sl);
      if(slDist <= 0) continue;

      double tp1Level = slDist * I_TP1_R;
      double profit   = (type == POSITION_TYPE_BUY)
         ? (current - open) : (open - current);

      if(profit >= tp1Level)
      {
         double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

         double closeVol = MathFloor((vol * I_TP1_ClosePct / 100.0) / step) * step;
         closeVol = MathMax(closeVol, minLot);

         if(closeVol >= vol)
            continue;

         // Only partial close once
         double origLot = LotSize(slDist);
         if(vol < origLot * 0.85)
            continue;

         if(trade.PositionClosePartial(tk, closeVol))
         {
            g_dailyWins++;
            g_consecLosses = 0;  // Reset consecutive losses on win
            Print("PARTIAL TP1 ticket=", tk, " closed=", closeVol);
         }
      }
   }
}

//==================================================================
// BREAKEVEN ENGINE
//==================================================================

void MoveToBreakeven()
{
   if(I_BreakevenR <= 0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk))                    continue;
      if(PositionGetInteger(POSITION_MAGIC) != I_Magic)  continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;

      int    type = (int)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      double current = (type == POSITION_TYPE_BUY)
         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double slDist = MathAbs(open - sl);
      if(slDist <= 0) continue;

      double profit = (type == POSITION_TYPE_BUY)
         ? (current - open) : (open - current);

      double rr = profit / slDist;

      if(rr >= I_BreakevenR)
      {
         double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                         SymbolInfoDouble(_Symbol, SYMBOL_BID);

         if(type == POSITION_TYPE_BUY)
         {
            double beSL = open + spread;
            if(sl < beSL)
               trade.PositionModify(tk, beSL, tp);
         }
         else
         {
            double beSL = open - spread;
            if(sl > beSL || sl == 0)
               trade.PositionModify(tk, beSL, tp);
         }
      }
   }
}

//==================================================================
// TRAILING ENGINE (improved - starts earlier, tighter trail)
//==================================================================

void ManageTrailing()
{
   double atr = BV(hATR, 1);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk))                    continue;
      if(PositionGetInteger(POSITION_MAGIC) != I_Magic)  continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;

      int    type = (int)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      double current = (type == POSITION_TYPE_BUY)
         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profit = (type == POSITION_TYPE_BUY)
         ? (current - open) : (open - current);

      double rr = profit / atr;
      double trail;

      // Start trailing at 0.5R
      if(rr < 0.5) continue;

      if(rr < 1.0)
         trail = atr * 0.9;
      else if(rr < 2.0)
         trail = atr * 0.7;
      else if(rr < 3.0)
         trail = atr * 0.5;
      else
         trail = atr * 0.35;   // Very tight at high profit

      if(type == POSITION_TYPE_BUY)
      {
         double nsl = current - trail;
         if(nsl > sl)
            trade.PositionModify(tk, nsl, tp);
      }
      else
      {
         double nsl = current + trail;
         if(nsl < sl || sl == 0)
            trade.PositionModify(tk, nsl, tp);
      }
   }
}

//==================================================================
// STALE TRADE EXIT (NEW)
// Close positions that haven't moved in our favor after X minutes
// This prevents holding losing positions that drift into big SL hits
//==================================================================

void CloseStalePositions()
{
   if(I_MaxStaleMinutes <= 0)
      return;

   double atr = BV(hATR, 1);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk))                    continue;
      if(PositionGetInteger(POSITION_MAGIC) != I_Magic)  continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;

      int    type = (int)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int elapsed = (int)(TimeCurrent() - openTime) / 60;

      if(elapsed < I_MaxStaleMinutes)
         continue;

      double current = (type == POSITION_TYPE_BUY)
         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profit = (type == POSITION_TYPE_BUY)
         ? (current - open) : (open - current);

      // If trade is "flat" (small profit or small loss) after max time, close it
      if(profit < atr * I_StaleThresholdATR && profit > -(atr * I_SL_MaxATR * 0.5))
      {
         if(trade.PositionClose(tk))
         {
            if(profit >= 0)
            {
               g_dailyWins++;
               g_consecLosses = 0;
            }
            else
            {
               g_dailyLosses++;
               g_consecLosses++;
               g_lastLossDir = (type == POSITION_TYPE_BUY) ? 1 : -1;
            }
            Print("STALE EXIT ticket=", tk, " profit=", profit,
                  " elapsed=", elapsed, "min");
         }
      }
   }
}

//==================================================================
// DAILY PROTECTION
//==================================================================

void DailyProtection()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   static int lastDay = -1;

   if(lastDay != dt.day)
   {
      lastDay         = dt.day;
      g_dayBalance    = AccountInfoDouble(ACCOUNT_BALANCE);
      g_halt          = false;
      g_dailyTrades   = 0;
      g_dailyWins     = 0;
      g_dailyLosses   = 0;
      g_consecLosses  = 0;
      g_cooldownUntil = 0;
      g_lastLossDir   = 0;
      g_dailyProfit   = 0;
   }

   double current = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = ((g_dayBalance - current) / g_dayBalance) * 100.0;
   g_dailyProfit = current - g_dayBalance;

   if(dd >= I_MaxDailyLossPct)
      g_halt = true;
}

//==================================================================
// TRACK CLOSED POSITIONS (results tracking + cooldown trigger)
//==================================================================

void TrackClosedPositions()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime dayStart = TimeCurrent() - dt.hour * 3600 - dt.min * 60 - dt.sec;

   if(!HistorySelect(dayStart, TimeCurrent()))
      return;

   static int lastDeals = 0;
   int totalDeals = HistoryDealsTotal();

   if(totalDeals <= lastDeals)
   {
      lastDeals = totalDeals;
      return;
   }

   for(int i = lastDeals; i < totalDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != I_Magic) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);

      if(profit > 0)
      {
         g_dailyWins++;
         g_consecLosses = 0;
         g_lastLossDir = 0;
      }
      else if(profit < 0)
      {
         g_dailyLosses++;
         g_consecLosses++;

         int dealType = (int)HistoryDealGetInteger(ticket, DEAL_TYPE);
         // DEAL_TYPE_SELL means closing a BUY, DEAL_TYPE_BUY means closing a SELL
         g_lastLossDir = (dealType == DEAL_TYPE_SELL) ? 1 : -1;

         // Trigger cooldown after consecutive losses
         if(g_consecLosses >= I_MaxConsecLoss)
         {
            g_cooldownUntil = TimeCurrent() + I_CooldownBars * 300;
            Print("COOLDOWN ACTIVATED: ", g_consecLosses,
                  " consecutive losses. Pausing ", I_CooldownBars, " bars.");
         }
      }
   }

   lastDeals = totalDeals;
}

//==================================================================
// MAIN
//==================================================================

void OnTick()
{
   // Position management on every tick
   ManageTrailing();
   MoveToBreakeven();
   PartialCloseTP1();
   CloseStalePositions();

   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(bar == g_lastBar)
      return;
   g_lastBar = bar;

   DailyProtection();
   TrackClosedPositions();

   if(g_halt)
      return;

   if(!InSession())
      return;

   if(!SpreadOK())
      return;

   if(!VolatilityFilter())
      return;

   MARKET_STATE state = GetMarketState();

   // All engines run in all states with priority order
   if(state == STATE_TREND)
   {
      SignalEMA();
      SignalUT();
      SignalPullback();
      SignalVWAP();
   }
   else if(state == STATE_EXPANSION)
   {
      SignalUT();
      SignalVWAP();
      SignalEMA();
      SignalRSIDivergence();
   }
   else
   {
      SignalVWAP();
      SignalRSIDivergence();
      SignalPullback();
      SignalEMA();
   }
}

//==================================================================
// TESTER SCORE
//==================================================================

double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   if(trades < 30)
      return 0;

   double pf  = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd  = TesterStatistics(STAT_BALANCE_DD_RELATIVE);
   double net = TesterStatistics(STAT_PROFIT);
   double wr  = TesterStatistics(STAT_PROFIT_TRADES) / trades;

   if(dd > 12) return 0;
   if(pf < 1.0) return 0;  // Reject losing configs

   // Score: profit factor * win rate * net profit * trade volume bonus
   return pf * wr * (net / 1000.0) * MathSqrt(trades / 100.0);
}
