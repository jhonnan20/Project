//+------------------------------------------------------------------+
//|                 GOLDBOT HFT v13.0 - DEVIL MODE                   |
//|          XAUUSD M5 - Institutional AI Scalper Engine             |
//|          ULTRA OPTIMIZED - HIGH PROFIT FACTOR VERSION            |
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

input group "??? DEVIL MODE RISK ????????????????????????????????????"
input double I_RiskUSD               = 15.0;
input double I_MaxDailyLossPct       = 4.0;
input int    I_MaxSimultaneous       = 3;
input int    I_Magic                 = 13000;

input group "??? EMA ENGINE ????????????????????????????????????????"
input int    I_EMA_Fast              = 5;
input int    I_EMA_Mid               = 13;
input int    I_EMA_Slow              = 34;
input double I_EMA_SlopeMin          = 0.05;

input group "??? VWAP ENGINE ???????????????????????????????????????"
input int    I_RSI_Period            = 14;
input int    I_VWAP_Bars             = 50;

input group "??? UT ENGINE ?????????????????????????????????????????"
input int    I_ATR_Period            = 14;
input double I_UT_ATR_Mult           = 1.4;

input group "??? TP / SL ENGINE ????????????????????????????????????"
input double I_TP1_R                 = 1.0;
input double I_TP2_R                 = 3.0;
input double I_TrailATR              = 0.6;

input group "??? HFT FILTERS ???????????????????????????????????????"
input bool   I_UseVolatilityFilter   = true;
input bool   I_UseSpreadFilter       = true;
input bool   I_UseMomentumFilter     = true;
input bool   I_UseVolumeFilter       = true;

input group "??? SESSIONS ??????????????????????????????????????????"
input bool   I_Asia                  = true;
input bool   I_London                = true;
input bool   I_NewYork               = true;

//==================================================================
// HANDLES
//==================================================================

int hEMAFast;
int hEMAMid;
int hEMASlow;
int hATR;
int hRSI;

//==================================================================
// GLOBALS
//==================================================================

datetime g_lastBar=0;

double g_dayBalance=0;
bool   g_halt=false;

double g_utBuy=0.0;
double g_utSell=0.0;

//==================================================================
// INIT
//==================================================================

int OnInit()
{
   trade.SetExpertMagicNumber(I_Magic);

   trade.SetDeviationInPoints(20);

   trade.SetTypeFilling(ORDER_FILLING_IOC);

   hEMAFast=iMA(_Symbol,PERIOD_M5,I_EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   hEMAMid=iMA(_Symbol,PERIOD_M5,I_EMA_Mid,0,MODE_EMA,PRICE_CLOSE);
   hEMASlow=iMA(_Symbol,PERIOD_M5,I_EMA_Slow,0,MODE_EMA,PRICE_CLOSE);

   hATR=iATR(_Symbol,PERIOD_M5,I_ATR_Period);

   hRSI=iRSI(_Symbol,PERIOD_M5,I_RSI_Period,PRICE_CLOSE);

   if(
      hEMAFast==INVALID_HANDLE ||
      hEMAMid==INVALID_HANDLE ||
      hEMASlow==INVALID_HANDLE ||
      hATR==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE
   )
      return INIT_FAILED;

   Print("GOLDBOT DEVIL MODE INITIALIZED");

   return INIT_SUCCEEDED;
}

//==================================================================
// BUFFER VALUE
//==================================================================

double BV(int handle,int shift)
{
   double arr[];

   ArraySetAsSeries(arr,true);

   if(CopyBuffer(handle,0,shift,1,arr)<=0)
      return 0.0;

   return arr[0];
}

//==================================================================
// VWAP
//==================================================================

double VWAP()
{
   double hi[],lo[],cl[];
   long vol[];

   ArraySetAsSeries(hi,true);
   ArraySetAsSeries(lo,true);
   ArraySetAsSeries(cl,true);
   ArraySetAsSeries(vol,true);

   if(CopyHigh(_Symbol,PERIOD_M5,1,I_VWAP_Bars,hi)<=0)
      return 0;

   if(CopyLow(_Symbol,PERIOD_M5,1,I_VWAP_Bars,lo)<=0)
      return 0;

   if(CopyClose(_Symbol,PERIOD_M5,1,I_VWAP_Bars,cl)<=0)
      return 0;

   if(CopyTickVolume(_Symbol,PERIOD_M5,1,I_VWAP_Bars,vol)<=0)
      return 0;

   double pv=0;
   double tv=0;

   for(int i=0;i<I_VWAP_Bars;i++)
   {
      double tp=(hi[i]+lo[i]+cl[i])/3.0;

      pv+=tp*vol[i];

      tv+=vol[i];
   }

   if(tv<=0)
      return cl[0];

   return pv/tv;
}

//==================================================================
// MARKET REGIME
//==================================================================

MARKET_STATE GetMarketState()
{
   double atr=BV(hATR,1);

   double atrSlow=BV(hATR,10);

   double ef=BV(hEMAFast,1);
   double es=BV(hEMASlow,1);

   double trend=MathAbs(ef-es);

   if(trend>atr*1.1)
      return STATE_TREND;

   if(atr>atrSlow*1.3)
      return STATE_EXPANSION;

   return STATE_RANGE;
}

//==================================================================
// VOLATILITY FILTER
//==================================================================

bool VolatilityFilter()
{
   if(!I_UseVolatilityFilter)
      return true;

   double atrNow=BV(hATR,1);

   double arr[];

   ArraySetAsSeries(arr,true);

   if(CopyBuffer(hATR,0,1,40,arr)<=0)
      return false;

   double avg=0;

   for(int i=0;i<40;i++)
      avg+=arr[i];

   avg/=40.0;

   if(atrNow<avg*1.10)
      return false;

   double body=MathAbs(
      iClose(_Symbol,PERIOD_M5,1)-
      iOpen(_Symbol,PERIOD_M5,1)
   );

   if(body<atrNow*0.35)
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

   ArraySetAsSeries(vol,true);

   if(CopyTickVolume(_Symbol,PERIOD_M5,1,30,vol)<=0)
      return false;

   double avg=0;

   for(int i=5;i<30;i++)
      avg+=vol[i];

   avg/=25.0;

   return vol[1]>avg*1.4;
}

//==================================================================
// SPREAD FILTER
//==================================================================

bool SpreadOK()
{
   if(!I_UseSpreadFilter)
      return true;

   double spread=SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);

   double atr=BV(hATR,1);

   double maxSpread=(atr/_Point)*0.12;

   return spread<=maxSpread;
}

//==================================================================
// MOMENTUM
//==================================================================

bool MomentumBuy()
{
   double c1=iClose(_Symbol,PERIOD_M5,1);
   double c2=iClose(_Symbol,PERIOD_M5,2);
   double c3=iClose(_Symbol,PERIOD_M5,3);

   return c1>c2 && c2>c3;
}

bool MomentumSell()
{
   double c1=iClose(_Symbol,PERIOD_M5,1);
   double c2=iClose(_Symbol,PERIOD_M5,2);
   double c3=iClose(_Symbol,PERIOD_M5,3);

   return c1<c2 && c2<c3;
}

//==================================================================
// SESSION FILTER
//==================================================================

bool InSession()
{
   MqlDateTime dt;

   TimeToStruct(TimeGMT(),dt);

   int hm=dt.hour*100+dt.min;

   if(dt.day_of_week==0 || dt.day_of_week==6)
      return false;

   if(hm>=2200 && hm<=2330)
      return false;

   if(hm>=0 && hm<=300)
      return false;

   if(I_Asia && hm>=500 && hm<700)
      return true;

   if(I_London && hm>=700 && hm<1200)
      return true;

   if(I_NewYork && hm>=1230 && hm<1900)
      return true;

   return false;
}

//==================================================================
// FAKE BREAKOUT FILTER
//==================================================================

bool FakeBreakoutBuy()
{
   double low1=iLow(_Symbol,PERIOD_M5,1);
   double low2=iLow(_Symbol,PERIOD_M5,2);

   double close1=iClose(_Symbol,PERIOD_M5,1);

   return low1<low2 && close1>low2;
}

bool FakeBreakoutSell()
{
   double high1=iHigh(_Symbol,PERIOD_M5,1);
   double high2=iHigh(_Symbol,PERIOD_M5,2);

   double close1=iClose(_Symbol,PERIOD_M5,1);

   return high1>high2 && close1<high2;
}

//==================================================================
// DYNAMIC RISK
//==================================================================

double DynamicRisk()
{
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);

   double dd=((balance-equity)/balance)*100.0;

   double risk=I_RiskUSD;

   if(dd>=2)
      risk*=0.7;

   if(dd>=4)
      risk*=0.5;

   if(dd>=6)
      risk*=0.3;

   return risk;
}

//==================================================================
// LOT SIZE
//==================================================================

double LotSize(double slDist)
{
   double riskUSD=DynamicRisk();

   double tickValue=
      SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);

   double tickSize=
      SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);

   if(tickValue<=0 || tickSize<=0)
      return 0.01;

   double lot=
      riskUSD/(slDist/tickSize*tickValue);

   double step=
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   double minLot=
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   double maxLot=
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);

   lot=MathFloor(lot/step)*step;

   lot=MathMax(lot,minLot);

   lot=MathMin(lot,maxLot);

   return lot;
}

//==================================================================
// SL
//==================================================================

double SLBuy()
{
   double low1=iLow(_Symbol,PERIOD_M5,1);
   double low2=iLow(_Symbol,PERIOD_M5,2);

   double atr=BV(hATR,1);

   double low=MathMin(low1,low2);

   return (
      SymbolInfoDouble(_Symbol,SYMBOL_ASK)-low
   )+(atr*0.25);
}

double SLSell()
{
   double high1=iHigh(_Symbol,PERIOD_M5,1);
   double high2=iHigh(_Symbol,PERIOD_M5,2);

   double atr=BV(hATR,1);

   double high=MathMax(high1,high2);

   return (
      high-SymbolInfoDouble(_Symbol,SYMBOL_BID)
   )+(atr*0.25);
}

//==================================================================
// TOTAL POSITIONS
//==================================================================

int TotalPositions()
{
   int total=0;

   for(int i=0;i<PositionsTotal();i++)
   {
      ulong tk=PositionGetTicket(i);

      if(!PositionSelectByTicket(tk))
         continue;

      if(PositionGetInteger(POSITION_MAGIC)!=I_Magic)
         continue;

      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;

      total++;
   }

   return total;
}

//==================================================================
// OPEN TRADE
//==================================================================

void OpenTrade(int dir,double slDist)
{
   if(TotalPositions()>=I_MaxSimultaneous)
      return;

   double lot=LotSize(slDist);

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   double tpDist=slDist*I_TP2_R;

   bool ok=false;

   if(dir==1)
   {
      ok=trade.Buy(
         lot,
         _Symbol,
         ask,
         ask-slDist,
         ask+tpDist
      );
   }
   else
   {
      ok=trade.Sell(
         lot,
         _Symbol,
         bid,
         bid+slDist,
         bid-tpDist
      );
   }

   if(ok)
   {
      Print(
         "OPEN ",
         dir==1?"BUY":"SELL",
         " LOT=",lot
      );
   }
}

//==================================================================
// EMA ENGINE
//==================================================================

void SignalEMA()
{
   double ef=BV(hEMAFast,1);
   double em=BV(hEMAMid,1);
   double es=BV(hEMASlow,1);

   double ef2=BV(hEMAFast,2);

   double atr=BV(hATR,1);

   double slope=MathAbs(ef-ef2)/atr;

   if(slope<I_EMA_SlopeMin)
      return;

   bool buy=(ef2<=em && ef>em && em>es);

   bool sell=(ef2>=em && ef<em && em<es);

   if(buy)
   {
      if(!MomentumBuy()) return;
      if(!InstitutionalVolume()) return;
      if(!FakeBreakoutBuy()) return;

      OpenTrade(1,SLBuy());
   }

   if(sell)
   {
      if(!MomentumSell()) return;
      if(!InstitutionalVolume()) return;
      if(!FakeBreakoutSell()) return;

      OpenTrade(-1,SLSell());
   }
}

//==================================================================
// VWAP ENGINE
//==================================================================

void SignalVWAP()
{
   double price=iClose(_Symbol,PERIOD_M5,1);

   double vwap=VWAP();

   double rsi=BV(hRSI,1);

   double atr=BV(hATR,1);

   double dist=(price-vwap)/atr;

   bool buy=(dist>-0.15 && dist<1.0 && rsi>50 && rsi<72);

   bool sell=(dist<0.15 && dist>-1.0 && rsi>28 && rsi<50);

   if(buy)
   {
      if(!MomentumBuy()) return;
      if(!InstitutionalVolume()) return;

      OpenTrade(1,SLBuy());
   }

   if(sell)
   {
      if(!MomentumSell()) return;
      if(!InstitutionalVolume()) return;

      OpenTrade(-1,SLSell());
   }
}

//==================================================================
// UT BOT
//==================================================================

bool UTBuy(double atr,double price)
{
   double k=atr*I_UT_ATR_Mult;

   if(g_utBuy<=0)
      g_utBuy=price-k;

   g_utBuy=
      (price>g_utBuy)
      ? MathMax(g_utBuy,price-k)
      : price-k;

   return price>g_utBuy;
}

bool UTSell(double atr,double price)
{
   double k=atr*I_UT_ATR_Mult;

   if(g_utSell<=0)
      g_utSell=price+k;

   g_utSell=
      (price<g_utSell)
      ? MathMin(g_utSell,price+k)
      : price+k;

   return price<g_utSell;
}

//==================================================================
// UT ENGINE
//==================================================================

void SignalUT()
{
   double atr=BV(hATR,1);

   double price=iClose(_Symbol,PERIOD_M5,1);

   bool buy=UTBuy(atr,price);

   bool sell=UTSell(atr,price);

   double ef=BV(hEMAFast,1);
   double em=BV(hEMAMid,1);

   if(buy && ef>em)
   {
      if(!MomentumBuy()) return;
      if(!InstitutionalVolume()) return;

      OpenTrade(1,SLBuy());
   }

   if(sell && ef<em)
   {
      if(!MomentumSell()) return;
      if(!InstitutionalVolume()) return;

      OpenTrade(-1,SLSell());
   }
}

//==================================================================
// TRAILING ENGINE
//==================================================================

void ManagePositions()
{
   double atr=BV(hATR,1);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);

      if(!PositionSelectByTicket(tk))
         continue;

      if(PositionGetInteger(POSITION_MAGIC)!=I_Magic)
         continue;

      int type=(int)PositionGetInteger(POSITION_TYPE);

      double open=
         PositionGetDouble(POSITION_PRICE_OPEN);

      double sl=
         PositionGetDouble(POSITION_SL);

      double tp=
         PositionGetDouble(POSITION_TP);

      double current=
         (type==POSITION_TYPE_BUY)
         ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
         : SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double rr=MathAbs(current-open)/atr;

      double trail;

      if(rr<1.0)
         continue;

      if(rr<2.0)
         trail=atr*0.9;
      else if(rr<4.0)
         trail=atr*0.7;
      else
         trail=atr*0.5;

      if(type==POSITION_TYPE_BUY)
      {
         double nsl=current-trail;

         if(nsl>sl)
            trade.PositionModify(tk,nsl,tp);
      }
      else
      {
         double nsl=current+trail;

         if(nsl<sl || sl==0)
            trade.PositionModify(tk,nsl,tp);
      }
   }
}

//==================================================================
// DAILY PROTECTION
//==================================================================

void DailyProtection()
{
   MqlDateTime dt;

   TimeToStruct(TimeCurrent(),dt);

   static int lastDay=-1;

   if(lastDay!=dt.day)
   {
      lastDay=dt.day;

      g_dayBalance=
         AccountInfoDouble(ACCOUNT_BALANCE);

      g_halt=false;
   }

   double current=
      AccountInfoDouble(ACCOUNT_BALANCE);

   double dd=
      ((g_dayBalance-current)/g_dayBalance)*100.0;

   if(dd>=I_MaxDailyLossPct)
      g_halt=true;
}

//==================================================================
// MAIN
//==================================================================

void OnTick()
{
   ManagePositions();

   datetime bar=iTime(_Symbol,PERIOD_M5,0);

   if(bar==g_lastBar)
      return;

   g_lastBar=bar;

   DailyProtection();

   if(g_halt)
      return;

   if(!InSession())
      return;

   if(!SpreadOK())
      return;

   if(!VolatilityFilter())
      return;

   MARKET_STATE state=GetMarketState();

   if(state==STATE_TREND)
   {
      SignalEMA();
      SignalUT();
   }
   else if(state==STATE_EXPANSION)
   {
      SignalUT();
      SignalVWAP();
   }
   else
   {
      SignalVWAP();
   }
}

//==================================================================
// TESTER SCORE
//==================================================================

double OnTester()
{
   double trades=
      TesterStatistics(STAT_TRADES);

   if(trades<50)
      return 0;

   double pf=
      TesterStatistics(STAT_PROFIT_FACTOR);

   double dd=
      TesterStatistics(STAT_BALANCE_DD_RELATIVE);

   double net=
      TesterStatistics(STAT_PROFIT);

   double wr=
      TesterStatistics(STAT_PROFIT_TRADES)/trades;

   if(dd>10)
      return 0;

   return pf*wr*(net/1000.0);
}
