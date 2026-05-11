//+------------------------------------------------------------------+
//|                 GOLDBOT HFT v14.0 - DEVIL MODE ULTRA             |
//|          XAUUSD M5 - Institutional AI Scalper Engine             |
//|          MAX FREQUENCY + MAX PROFIT OPTIMIZATION                 |
//|                     MetaTrader 5 Build 3800+                     |
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

input group "=== DEVIL MODE RISK ==================================="
input double I_RiskUSD               = 15.0;
input double I_MaxDailyLossPct       = 4.0;
input int    I_MaxSimultaneous       = 5;         // Increased from 3 to 5
input int    I_Magic                 = 14000;

input group "=== EMA ENGINE ========================================"
input int    I_EMA_Fast              = 5;
input int    I_EMA_Mid               = 13;
input int    I_EMA_Slow              = 34;
input double I_EMA_SlopeMin          = 0.03;      // Relaxed from 0.05

input group "=== VWAP ENGINE ======================================="
input int    I_RSI_Period            = 14;
input int    I_VWAP_Bars             = 50;

input group "=== UT ENGINE ========================================="
input int    I_ATR_Period            = 14;
input double I_UT_ATR_Mult           = 1.2;       // Tighter from 1.4

input group "=== TP / SL ENGINE ===================================="
input double I_TP1_R                 = 1.0;
input double I_TP2_R                 = 3.0;
input double I_TP1_ClosePct          = 50.0;      // NEW: Partial close % at TP1
input double I_TrailATR              = 0.6;
input double I_BreakevenR            = 0.5;       // NEW: Move SL to BE at this R

input group "=== HFT FILTERS ======================================="
input bool   I_UseVolatilityFilter   = true;
input bool   I_UseSpreadFilter       = true;
input bool   I_UseMomentumFilter     = true;
input bool   I_UseVolumeFilter       = true;

input group "=== SESSIONS =========================================="
input bool   I_Asia                  = true;
input bool   I_London                = true;
input bool   I_NewYork               = true;
input bool   I_LateNY               = true;       // NEW: Late NY session

input group "=== PULLBACK ENGINE ==================================="
input bool   I_UsePullbackEngine     = true;       // NEW: Pullback re-entry
input double I_PullbackDepth         = 0.382;      // Fib level for pullback

input group "=== MULTI-TIMEFRAME ==================================="
input bool   I_UseMTF                = true;        // NEW: M15 trend confirmation
input int    I_MTF_EMA_Period        = 21;

//==================================================================
// HANDLES
//==================================================================

int hEMAFast;
int hEMAMid;
int hEMASlow;
int hATR;
int hRSI;
int hATR_M15;        // NEW: M15 ATR
int hEMA_M15;        // NEW: M15 EMA for trend

//==================================================================
// GLOBALS
//==================================================================

datetime g_lastBar      = 0;
double   g_dayBalance   = 0;
bool     g_halt         = false;
double   g_utBuy        = 0.0;
double   g_utSell       = 0.0;
int      g_dailyTrades  = 0;      // NEW: Track daily trades
int      g_dailyWins    = 0;      // NEW: Track daily wins
datetime g_lastEntryTime = 0;     // NEW: Prevent rapid-fire entries

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

   // NEW: Multi-timeframe handles
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

   Print("GOLDBOT DEVIL MODE v14.0 ULTRA INITIALIZED");

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

   Print("GOLDBOT v14.0 Daily Stats: Trades=", g_dailyTrades, " Wins=", g_dailyWins);
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
// BUFFER VALUE M15
//==================================================================

double BV_M15(int handle, int shift)
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
   double atr    = BV(hATR, 1);
   double atrSlow = BV(hATR, 10);
   double ef     = BV(hEMAFast, 1);
   double es     = BV(hEMASlow, 1);
   double trend  = MathAbs(ef - es);

   if(trend > atr * 1.0)           // Relaxed from 1.1
      return STATE_TREND;

   if(atr > atrSlow * 1.2)         // Relaxed from 1.3
      return STATE_EXPANSION;

   return STATE_RANGE;
}

//==================================================================
// MULTI-TIMEFRAME TREND (NEW)
//==================================================================

int MTF_Trend()
{
   if(!I_UseMTF)
      return 0;

   double ema15    = BV_M15(hEMA_M15, 1);
   double price15  = iClose(_Symbol, PERIOD_M15, 1);

   if(price15 > ema15)
      return 1;    // Bullish
   if(price15 < ema15)
      return -1;   // Bearish

   return 0;        // Neutral
}

//==================================================================
// VOLATILITY FILTER (RELAXED)
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

   // Relaxed: was 1.10, now 0.85
   if(atrNow < avg * 0.85)
      return false;

   double body = MathAbs(
      iClose(_Symbol, PERIOD_M5, 1) -
      iOpen(_Symbol, PERIOD_M5, 1)
   );

   // Relaxed: was 0.35, now 0.20
   if(body < atrNow * 0.20)
      return false;

   return true;
}

//==================================================================
// VOLUME FILTER (RELAXED)
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

   // Relaxed: was 1.4, now 1.1
   return vol[1] > avg * 1.1;
}

//==================================================================
// SPREAD FILTER (RELAXED)
//==================================================================

bool SpreadOK()
{
   if(!I_UseSpreadFilter)
      return true;

   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double atr = BV(hATR, 1);

   // Relaxed: was 0.12, now 0.18
   double maxSpread = (atr / _Point) * 0.18;

   return spread <= maxSpread;
}

//==================================================================
// MOMENTUM (RELAXED - 2 of 3 candles)
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

   // Relaxed: 2 of 3 conditions instead of all 3
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
// SESSION FILTER (EXPANDED)
//==================================================================

bool InSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int hm = dt.hour * 100 + dt.min;

   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;

   // Only block critical low-liquidity window
   if(hm >= 2300 || hm < 200)
      return false;

   // Expanded Asia: 2:00 - 8:00
   if(I_Asia && hm >= 200 && hm < 800)
      return true;

   // Expanded London: 7:00 - 13:00 (overlap with Asia)
   if(I_London && hm >= 700 && hm < 1300)
      return true;

   // Expanded New York: 12:00 - 20:00 (overlap with London)
   if(I_NewYork && hm >= 1200 && hm < 2000)
      return true;

   // NEW: Late NY session: 20:00 - 23:00
   if(I_LateNY && hm >= 2000 && hm < 2300)
      return true;

   return false;
}

//==================================================================
// MINIMUM ENTRY SPACING (NEW)
// Prevent opening trades too rapidly (min 2 minutes apart)
//==================================================================

bool EntrySpacingOK()
{
   if(g_lastEntryTime == 0)
      return true;

   return (TimeCurrent() - g_lastEntryTime) >= 120;
}

//==================================================================
// DYNAMIC RISK (IMPROVED)
//==================================================================

double DynamicRisk()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = ((balance - equity) / balance) * 100.0;

   double risk = I_RiskUSD;

   if(dd >= 2)
      risk *= 0.75;
   if(dd >= 4)
      risk *= 0.5;
   if(dd >= 6)
      risk *= 0.3;

   // NEW: Slight boost when winning (confidence scaling)
   double winRate = 0;
   if(g_dailyTrades > 3)
   {
      winRate = (double)g_dailyWins / g_dailyTrades;
      if(winRate > 0.65 && dd < 1.0)
         risk *= 1.15;
   }

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
// SL CALCULATION (IMPROVED - tighter SL)
//==================================================================

double SLBuy()
{
   double low1 = iLow(_Symbol, PERIOD_M5, 1);
   double low2 = iLow(_Symbol, PERIOD_M5, 2);
   double low3 = iLow(_Symbol, PERIOD_M5, 3);
   double atr  = BV(hATR, 1);

   double low = MathMin(low1, MathMin(low2, low3));

   double slDist = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - low) + (atr * 0.15);

   // Cap SL to max 1.5 ATR
   if(slDist > atr * 1.5)
      slDist = atr * 1.5;

   // Min SL of 0.3 ATR
   if(slDist < atr * 0.3)
      slDist = atr * 0.3;

   return slDist;
}

double SLSell()
{
   double high1 = iHigh(_Symbol, PERIOD_M5, 1);
   double high2 = iHigh(_Symbol, PERIOD_M5, 2);
   double high3 = iHigh(_Symbol, PERIOD_M5, 3);
   double atr   = BV(hATR, 1);

   double high = MathMax(high1, MathMax(high2, high3));

   double slDist = (high - SymbolInfoDouble(_Symbol, SYMBOL_BID)) + (atr * 0.15);

   if(slDist > atr * 1.5)
      slDist = atr * 1.5;

   if(slDist < atr * 0.3)
      slDist = atr * 0.3;

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
      if(!PositionSelectByTicket(tk))         continue;
      if(PositionGetInteger(POSITION_MAGIC) != I_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      total++;
   }
   return total;
}

//==================================================================
// COUNT DIRECTIONAL POSITIONS (NEW)
//==================================================================

int CountDirectionalPositions(int dir)
{
   int total = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk))         continue;
      if(PositionGetInteger(POSITION_MAGIC) != I_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(dir == 1 && type == POSITION_TYPE_BUY)   total++;
      if(dir == -1 && type == POSITION_TYPE_SELL)  total++;
   }
   return total;
}

//==================================================================
// OPEN TRADE (IMPROVED)
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

   // MTF confirmation: don't trade against M15 trend
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
      ok = trade.Buy(
         lot, _Symbol, ask,
         ask - slDist,
         ask + tpDist
      );
   }
   else
   {
      ok = trade.Sell(
         lot, _Symbol, bid,
         bid + slDist,
         bid - tpDist
      );
   }

   if(ok)
   {
      g_lastEntryTime = TimeCurrent();
      g_dailyTrades++;
      Print("OPEN ", (dir == 1 ? "BUY" : "SELL"),
            " [", signalName, "] LOT=", lot,
            " SL=", slDist, " TP=", tpDist);
   }
}

//==================================================================
// EMA ENGINE (RELAXED - removed fake breakout requirement)
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

   // Relaxed: crossover OR strong alignment
   bool crossBuy  = (ef2 <= em && ef > em && em > es);
   bool alignBuy  = (ef > em && em > es && slope > I_EMA_SlopeMin * 2);

   bool crossSell = (ef2 >= em && ef < em && em < es);
   bool alignSell = (ef < em && em < es && slope > I_EMA_SlopeMin * 2);

   bool buy  = crossBuy || alignBuy;
   bool sell = crossSell || alignSell;

   if(buy)
   {
      if(!MomentumBuy()) return;
      if(!InstitutionalVolume()) return;
      // Removed FakeBreakoutBuy() requirement
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
// VWAP ENGINE (EXPANDED RANGES)
//==================================================================

void SignalVWAP()
{
   double price = iClose(_Symbol, PERIOD_M5, 1);
   double vwap  = VWAP();
   double rsi   = BV(hRSI, 1);
   double atr   = BV(hATR, 1);
   double dist  = (price - vwap) / atr;

   // Expanded ranges: was [-0.15, 1.0] now [-0.5, 1.5]
   // RSI: was [50, 72] now [45, 75]
   bool buy  = (dist > -0.5 && dist < 1.5 && rsi > 45 && rsi < 75);

   // Expanded: was [-1.0, 0.15] now [-1.5, 0.5]
   // RSI: was [28, 50] now [25, 55]
   bool sell = (dist < 0.5 && dist > -1.5 && rsi > 25 && rsi < 55);

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
// PULLBACK ENGINE (NEW)
// Enters on pullbacks within a strong trend
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

   // Strong uptrend: all EMAs aligned bullish
   bool uptrend  = (ef > em && em > es);
   // Strong downtrend: all EMAs aligned bearish
   bool downtrend = (ef < em && em < es);

   double price = iClose(_Symbol, PERIOD_M5, 1);
   double high5 = 0, low5 = 999999;

   // Find 5-bar high/low for pullback measurement
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
      // Price pulled back to Fib level from recent high
      double pullback = (high5 - price) / range;
      if(pullback >= I_PullbackDepth * 0.8 && pullback <= I_PullbackDepth * 1.5)
      {
         // RSI not oversold (still in trend)
         if(rsi > 40 && rsi < 65)
         {
            // Bullish candle confirmation
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
         if(rsi > 35 && rsi < 60)
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
// RSI DIVERGENCE ENGINE (NEW)
// Detects bullish/bearish RSI divergences for entries
//==================================================================

void SignalRSIDivergence()
{
   double rsi1 = BV(hRSI, 1);
   double rsi5 = BV(hRSI, 5);

   double price1 = iClose(_Symbol, PERIOD_M5, 1);
   double price5 = iClose(_Symbol, PERIOD_M5, 5);
   double low1   = iLow(_Symbol, PERIOD_M5, 1);
   double low5   = iLow(_Symbol, PERIOD_M5, 5);
   double high1  = iHigh(_Symbol, PERIOD_M5, 1);
   double high5  = iHigh(_Symbol, PERIOD_M5, 5);

   double ef = BV(hEMAFast, 1);
   double em = BV(hEMAMid, 1);

   // Bullish divergence: price makes lower low, RSI makes higher low
   if(low1 < low5 && rsi1 > rsi5 && rsi1 < 45 && ef > em)
   {
      if(!InstitutionalVolume()) return;
      OpenTrade(1, SLBuy(), "RSI_DIV");
   }

   // Bearish divergence: price makes higher high, RSI makes lower high
   if(high1 > high5 && rsi1 < rsi5 && rsi1 > 55 && ef < em)
   {
      if(!InstitutionalVolume()) return;
      OpenTrade(-1, SLSell(), "RSI_DIV");
   }
}

//==================================================================
// PARTIAL CLOSE AT TP1 (NEW)
//==================================================================

void PartialCloseTP1()
{
   if(I_TP1_ClosePct <= 0)
      return;

   double atr = BV(hATR, 1);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk))         continue;
      if(PositionGetInteger(POSITION_MAGIC) != I_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
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

      // Check if price reached TP1
      if(profit >= tp1Level)
      {
         double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

         double closeVol = MathFloor((vol * I_TP1_ClosePct / 100.0) / step) * step;
         closeVol = MathMax(closeVol, minLot);

         if(closeVol >= vol)
            continue; // Don't close everything, leave runner

         // Only partial close once: check if volume already reduced
         double originalLot = LotSize(slDist);
         if(vol < originalLot * 0.9)
            continue; // Already partially closed

         trade.PositionClosePartial(tk, closeVol);
         g_dailyWins++;
         Print("PARTIAL CLOSE TP1 ticket=", tk, " vol=", closeVol);
      }
   }
}

//==================================================================
// BREAKEVEN ENGINE (NEW)
//==================================================================

void MoveToBreakeven()
{
   if(I_BreakevenR <= 0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk))         continue;
      if(PositionGetInteger(POSITION_MAGIC) != I_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
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

      // Move to breakeven when profit reaches I_BreakevenR
      if(rr >= I_BreakevenR)
      {
         double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                         SymbolInfoDouble(_Symbol, SYMBOL_BID);

         double beSL;
         if(type == POSITION_TYPE_BUY)
         {
            beSL = open + spread; // BE + spread
            if(sl < beSL)
               trade.PositionModify(tk, beSL, tp);
         }
         else
         {
            beSL = open - spread;
            if(sl > beSL || sl == 0)
               trade.PositionModify(tk, beSL, tp);
         }
      }
   }
}

//==================================================================
// TRAILING ENGINE (IMPROVED - starts earlier)
//==================================================================

void ManagePositions()
{
   double atr = BV(hATR, 1);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk))         continue;
      if(PositionGetInteger(POSITION_MAGIC) != I_Magic) continue;

      // Allow trailing on all symbols with this magic
      int type = (int)PositionGetInteger(POSITION_TYPE);

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      double current = (type == POSITION_TYPE_BUY)
         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      double rr = MathAbs(current - open) / atr;
      double trail;

      // Start trailing earlier: from 0.6R instead of 1.0R
      if(rr < 0.6)
         continue;

      if(rr < 1.0)
         trail = atr * 1.0;      // Wide trail early
      else if(rr < 2.0)
         trail = atr * 0.8;
      else if(rr < 4.0)
         trail = atr * 0.6;
      else
         trail = atr * 0.4;      // Tighter trail at high R

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
// DAILY PROTECTION (IMPROVED)
//==================================================================

void DailyProtection()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   static int lastDay = -1;

   if(lastDay != dt.day)
   {
      lastDay       = dt.day;
      g_dayBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
      g_halt        = false;
      g_dailyTrades = 0;
      g_dailyWins   = 0;
   }

   double current = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = ((g_dayBalance - current) / g_dayBalance) * 100.0;

   if(dd >= I_MaxDailyLossPct)
      g_halt = true;
}

//==================================================================
// CLOSE RESULT TRACKER (NEW)
// Track wins from fully closed positions
//==================================================================

void TrackClosedPositions()
{
   static int lastDeals = 0;

   int totalDeals = HistoryDealsTotal();
   if(totalDeals <= lastDeals)
   {
      lastDeals = totalDeals;
      return;
   }

   // Check if there's history available today
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime dayStart = TimeCurrent() - dt.hour * 3600 - dt.min * 60 - dt.sec;

   if(!HistorySelect(dayStart, TimeCurrent()))
   {
      lastDeals = totalDeals;
      return;
   }

   for(int i = lastDeals; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != I_Magic) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      if(profit > 0)
         g_dailyWins++;
   }

   lastDeals = totalDeals;
}

//==================================================================
// MAIN (IMPROVED)
//==================================================================

void OnTick()
{
   // Position management runs every tick
   ManagePositions();
   MoveToBreakeven();
   PartialCloseTP1();

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

   // ALL engines run in ALL market states (with priority order)
   // This maximizes trade opportunities
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
   else // STATE_RANGE
   {
      SignalVWAP();
      SignalRSIDivergence();
      SignalPullback();
      SignalEMA();
   }
}

//==================================================================
// TESTER SCORE (IMPROVED)
//==================================================================

double OnTester()
{
   double trades = TesterStatistics(STAT_TRADES);
   if(trades < 30)       // Lowered from 50 to allow more configs
      return 0;

   double pf  = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd  = TesterStatistics(STAT_BALANCE_DD_RELATIVE);
   double net = TesterStatistics(STAT_PROFIT);
   double wr  = TesterStatistics(STAT_PROFIT_TRADES) / trades;

   if(dd > 12)           // Relaxed from 10
      return 0;

   // Enhanced score: rewards more trades + higher win rate
   return pf * wr * (net / 1000.0) * MathSqrt(trades / 100.0);
}
