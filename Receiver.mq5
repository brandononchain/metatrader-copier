//+------------------------------------------------------------------+
//|                         MT5_Receiver_Simple.mq5                  |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

input string  RelayURL       = "http://127.0.0.1:8787";
input string  AuthToken      = "CHANGE_ME";
input int     PollMs         = 250;
input string  AllowedSymbols = "";        // "" or "XAUUSD,EURUSD"
input string  SymbolSuffix   = "";        // e.g. ".m", ".pro"
input double  LotMultiplier  = 1.0;       // source lots * multiplier
input bool    UseRiskPct     = false;     // risk sizing (overrides lots if true)
input double  RiskPct        = 0.50;      // % balance risk per trade
input ulong   Deviation      = 20;        // slippage/deviation
input int     MaxBatch       = 50;

CTrade trade;
int   latest_id   = 0;
ulong last_tickms = 0;

// ---------- utils ----------
bool sym_allowed(const string s) {
   if(AllowedSymbols=="") return true;
   string hay=","+AllowedSymbols+",", needle=","+s+",";
   return (StringFind(hay, needle) >= 0);
}
string map_symbol(const string s) {
   string out = s + SymbolSuffix;
   SymbolSelect(out, true);
   return out;
}

// ALWAYS use 3-arg SymbolInfoInteger; accept prop as int to avoid enum issues
bool sym_info_integer(const string sym, const int prop, long &val_out){
   val_out = 0;
   if(!SymbolInfoInteger(sym, (ENUM_SYMBOL_INFO_INTEGER)prop, val_out)){
      Print("SymbolInfoInteger failed: ", GetLastError(), " sym=", sym, " prop=", prop);
      return false;
   }
   return true;
}

// tiny JSON helpers
double jnum(const string obj, const string key){
   string pat="\""+key+"\":"; int p=StringFind(obj,pat); if(p<0) return 0.0;
   int s=p+(int)StringLen(pat), e=s;
   while(e<(int)StringLen(obj)){ uint ch=StringGetCharacter(obj,e); if(ch==',' || ch=='}') break; e++; }
   string v=StringSubstr(obj,s,e-s); StringReplace(v,"\"","");
   return (double)StringToDouble(v);
}
string jstr(const string obj, const string key){
   string pat="\""+key+"\":\""; int p=StringFind(obj,pat); if(p<0) return "";
   int s=p+(int)StringLen(pat); int e=StringFind(obj,"\"",s); if(e<0) return "";
   return StringSubstr(obj,s,e-s);
}

// HTTP (MT5 signature with uchar[])
bool post_json(const string url, const string json, string &resp){
   uchar data[];   StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
   uchar result[]; string hdrs="Content-Type: application/json\r\nAuthorization: "+AuthToken+"\r\n";
   string result_headers="";
   ResetLastError();
   int rc=WebRequest("POST", url, hdrs, 5000, data, result, result_headers);
   if(rc==-1){ Print("WebRequest failed. Add URL in Options. Err=",GetLastError()); return false; }
   resp=CharArrayToString(result,0,-1,CP_UTF8);
   return true;
}

// positions
bool has_position(const string sym){ return PositionSelect(sym); }
double pos_volume(const string sym){ return PositionSelect(sym)?PositionGetDouble(POSITION_VOLUME):0.0; }

// risk sizing
double lots_by_risk(const string sym, const ENUM_ORDER_TYPE type, const double sl_price){
   if(!UseRiskPct || sl_price<=0) return 0.0;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_val=bal*(RiskPct/100.0);
   double tick_val = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tick_size= SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tick_val<=0 || tick_size<=0) return 0.0;

   double px=(type==ORDER_TYPE_BUY || type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT)
              ? SymbolInfoDouble(sym,SYMBOL_ASK) : SymbolInfoDouble(sym,SYMBOL_BID);
   if(px<=0) return 0.0;

   double ticks = MathMax(1.0, MathAbs(px - sl_price)/tick_size);
   double lots  = risk_val / (ticks * tick_val);

   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vstep= SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(vmin<=0||vstep<=0||vmax<=0) return 0.0;

   lots = MathFloor(lots/vstep)*vstep;
   lots = MathMax(vmin, MathMin(vmax, lots));
   return lots;
}

// delete pendings (ticket-based selection)
void delete_matching_pendings(const string sym, const ENUM_ORDER_TYPE otype){
   int n=OrdersTotal();
   for(int idx=0; idx<n; idx++){
      ulong ticket=OrderGetTicket(idx);
      if(ticket==0) continue;
      if(!OrderSelect(ticket)) continue;
      string os=OrderGetString(ORDER_SYMBOL);
      ENUM_ORDER_TYPE ot=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(os==sym && ot==otype){
         trade.OrderDelete(ticket);
      }
   }
}

// ---------- mirror core ----------
void mirror_signal(const int rid,
                   const string action,
                   const string src_symbol,
                   const int    order_type_i,
                   const int    source_ticket,
                   const double lots_src,
                   const double price_src,
                   const double sl_src,
                   const double tp_src)
{
   if(!sym_allowed(src_symbol)) return;
   string sym = map_symbol(src_symbol);

   // Use SYMBOL_TRADE_MODE instead of SYMBOL_TRADING_ALLOWED
   long trade_mode=0;
   if(!sym_info_integer(sym, (int)SYMBOL_TRADE_MODE, trade_mode)) return;
   if((ENUM_SYMBOL_TRADE_MODE)trade_mode == SYMBOL_TRADE_MODE_DISABLED){
      Print("Trading disabled for ", sym); return;
   }

   ENUM_ORDER_TYPE otype=(ENUM_ORDER_TYPE)order_type_i;

   // size normalize
   double vol = lots_src * LotMultiplier;
   if(UseRiskPct && (otype==ORDER_TYPE_BUY || otype==ORDER_TYPE_SELL) && sl_src>0){
      double r=lots_by_risk(sym, otype, sl_src);
      if(r>0) vol=r;
   }
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vstep= SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(vmin<=0||vstep<=0||vmax<=0){ Print("Bad volume filters for ",sym); return; }
   vol = MathMax(vmin, MathMin(vmax, MathFloor(vol/vstep)*vstep));
   if(vol < vmin) vol = vmin;

   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);

   if(action=="OPEN"){
      if(otype==ORDER_TYPE_BUY || otype==ORDER_TYPE_SELL){
         double ask=SymbolInfoDouble(sym,SYMBOL_ASK), bid=SymbolInfoDouble(sym,SYMBOL_BID);
         req.action=TRADE_ACTION_DEAL; req.symbol=sym; req.magic=777001; req.type=otype;
         req.volume=vol; req.deviation=Deviation; req.price=(otype==ORDER_TYPE_BUY?ask:bid);
         req.sl=sl_src; req.tp=tp_src;
         if(!OrderSend(req,res)) Print("OrderSend market failed: ",_LastError);
      } else {
         req.action=TRADE_ACTION_PENDING; req.symbol=sym; req.magic=777001; req.type=otype;
         req.volume=vol; req.deviation=Deviation; req.price=price_src; req.sl=sl_src; req.tp=tp_src;
         if(!OrderSend(req,res)) Print("OrderSend pending failed: ",_LastError);
      }
   }
   else if(action=="MODIFY"){
      if(otype==ORDER_TYPE_BUY || otype==ORDER_TYPE_SELL){
         if(has_position(sym)){
            double cur=pos_volume(sym);
            if(cur - vol > vstep/2.0){
               double reduce=cur - vol;
               if(!trade.PositionClosePartial(sym, reduce, Deviation))
                  Print("PositionClosePartial failed: ", _LastError);
            }
            if(!trade.PositionModify(sym, sl_src, tp_src))
               Print("PositionModify failed: ", _LastError);
         }
      } else {
         // (optional) pending modify via comment mapping
      }
   }
   else if(action=="CLOSE"){
      if(otype==ORDER_TYPE_BUY || otype==ORDER_TYPE_SELL){
         if(has_position(sym)){
            if(!trade.PositionClose(sym, Deviation))
               Print("PositionClose failed: ", _LastError);
         }
      } else {
         delete_matching_pendings(sym, otype);
      }
   }
}

// ---------- polling ----------
bool pull_batch(){
   string payload=StringFormat("{\"since_id\":%d,\"max_batch\":%d}", latest_id, MaxBatch);
   string resp; if(!post_json(RelayURL+"/pull", payload, resp)) return false;

   int sp=StringFind(resp,"\"signals\":"); if(sp<0) return true;
   int a0=StringFind(resp,"[",sp), a1=StringFind(resp,"]",a0); if(a0<0||a1<0) return true;
   string arr=StringSubstr(resp,a0,a1-a0+1);

   int pos=0;
   while(true){
      int rp=StringFind(arr,"\"relay_id\":",pos); if(rp<0) break;
      int re=rp+11; while(re<(int)StringLen(arr)){ uint ch=StringGetCharacter(arr,re); if(ch==','||ch=='}') break; re++; }
      int rid=(int)StringToInteger(StringSubstr(arr,rp+11,re-(rp+11)));
      int is=StringFind(arr,"{",pos), ie=StringFind(arr,"}",re); if(is<0||ie<0) break;
      string item=StringSubstr(arr,is,ie-is+1); pos=ie+1;

      string action=jstr(item,"action");
      string symbol=jstr(item,"symbol");
      int    otype =(int)jnum(item,"order_type");
      int    stkt  =(int)jnum(item,"source_ticket");
      double lots  =jnum(item,"lots");
      double price =jnum(item,"price");
      double sl    =jnum(item,"sl");
      double tp    =jnum(item,"tp");

      mirror_signal(rid,action,symbol,otype,stkt,lots,price,sl,tp);
      if(rid>latest_id) latest_id=rid;
   }

   int lp=StringFind(resp,"\"latest_id\":");
   if(lp>=0){
      int e=StringFind(resp,"}",lp); if(e<0) e=(int)StringLen(resp);
      int lid=(int)StringToInteger(StringSubstr(resp,lp+12,e-(lp+12)));
      if(lid>latest_id) latest_id=lid;
   }
   return true;
}

// ---------- EA lifecycle ----------
int OnInit(){ EventSetTimer(1); return(INIT_SUCCEEDED); }
void OnDeinit(const int reason){ EventKillTimer(); }
void OnTimer(){ ulong now=GetTickCount(); if(now-last_tickms<(ulong)PollMs) return; last_tickms=now; pull_batch(); }
