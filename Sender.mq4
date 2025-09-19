//+------------------------------------------------------------------+
//|                                         MT4_Sender_Simple.mq4    |
//|        Minimal MT4 → Relay publisher (market + pending orders)   |
//+------------------------------------------------------------------+
#property strict

// ======= Inputs =======
input string  RelayURL      = "http://127.0.0.1:8787";
input string  AuthToken     = "CHANGE_ME";     // must match relay + receiver
input int     PollMs        = 250;             // scan interval
input int     MagicFilter   = -1;              // -1 = all magics
input string  SymbolFilter  = "";              // ""=all or "XAUUSD,EURUSD"
input bool    SendPending   = true;
input bool    SendMarket    = true;

// ======= State =======
datetime  g_lastScan = 0;
uint      g_lastTick = 0;

// Keep a local snapshot of open tickets so we can detect OPEN/MODIFY/CLOSE
struct TradeSnap {
   int    ticket;
   string symbol;
   int    type;      // 0=BUY,1=SELL, 2.. pending types
   double lots;
   double price;
   double sl;
   double tp;
   int    magic;
   string comment;
   int    version;
};
TradeSnap snaps[];   // dynamic array
int       snapsCount = 0;

// ======= Helpers =======
bool sym_allowed(string sym) {
   if(SymbolFilter=="") return true;
   string hay = "," + SymbolFilter + ",";
   string needle = "," + sym + ",";
   return (StringFind(hay, needle) >= 0);
}

int digits_of(string sym){
   int d = (int)MarketInfo(sym, MODE_DIGITS);
   if(d <= 0) d = Digits;
   return d;
}

int find_snap_index(int ticket){
   for(int i=0; i<snapsCount; i++){
      if(snaps[i].ticket == ticket) return i;
   }
   return -1;
}

string http_post(const string url, const string json, const string auth){
   // MT4 WebRequest signature:
   // int WebRequest(const string method,const string url,const string headers,
   //                int timeout,const char &data[],char &result[],string &result_headers)
   char data[];
   StringToCharArray(json, data, 0, WHOLE_ARRAY, CP_UTF8);
   char result[];
   string hdrs = "Content-Type: application/json\r\nAuthorization: " + auth + "\r\n";
   string result_headers = "";
   ResetLastError();
   int res = WebRequest("POST", url, hdrs, 5000, data, result, result_headers);
   if(res == -1){
      Print("WebRequest failed. Ensure URL is whitelisted in Options. Err=", GetLastError(), " URL=", url);
      return "";
   }
   return CharArrayToString(result, 0, -1, CP_UTF8);
}

void publish(const string action, const TradeSnap &s){
   int d = digits_of(s.symbol);
   // naive JSON (no escaping of comment quotes); keep comment simple
   string body = StringFormat(
      "{\"action\":\"%s\",\"source\":\"MT4\",\"symbol\":\"%s\",\"order_type\":%d,"
      "\"source_ticket\":%d,\"magic\":%d,\"comment\":\"%s\",\"lots\":%s,"
      "\"price\":%s,\"sl\":%s,\"tp\":%s,\"version\":%d}",
      action, s.symbol, s.type, s.ticket, s.magic, s.comment,
      DoubleToString(s.lots, 2),
      DoubleToString(s.price, d),
      DoubleToString(s.sl,    d),
      DoubleToString(s.tp,    d),
      s.version
   );
   string resp = http_post(RelayURL + "/publish", body, AuthToken);
   // Optional: Print("Published ", action, " ticket=", s.ticket, " resp=", resp);
}

// ======= Scanners =======
void scan_open_and_modify(){
   // Walk all current open market & pending orders
   int total = OrdersTotal();
   for(int i=0; i<total; i++){
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;

      int type = OrderType();
      bool isPending = (type >= 2);
      if(isPending && !SendPending) continue;
      if(!isPending && !SendMarket) continue;

      string sym = OrderSymbol();
      if(!sym_allowed(sym)) continue;

      int magic = OrderMagicNumber();
      if(MagicFilter != -1 && magic != MagicFilter) continue;

      int    ticket = OrderTicket();
      double lots   = OrderLots();
      double price  = OrderOpenPrice();
      double sl     = OrderStopLoss();
      double tp     = OrderTakeProfit();
      string comm   = OrderComment();

      int idx = find_snap_index(ticket);
      if(idx < 0){
         // New OPEN
         TradeSnap s;
         s.ticket=ticket; s.symbol=sym; s.type=type; s.lots=lots; s.price=price;
         s.sl=sl; s.tp=tp; s.magic=magic; s.comment=comm; s.version=1;

         // push back
         ArrayResize(snaps, snapsCount+1);
         snaps[snapsCount] = s;
         snapsCount++;

         publish("OPEN", s);
      } else {
         // Check modifications
         bool changed = false;
         if(MathAbs(snaps[idx].lots  - lots)  > 1e-6)              { snaps[idx].lots  = lots;  changed = true; }
         if(MathAbs(snaps[idx].price - price) > (Point/2.0))       { snaps[idx].price = price; changed = true; }
         if(MathAbs(snaps[idx].sl    - sl)    > (Point/2.0))       { snaps[idx].sl    = sl;    changed = true; }
         if(MathAbs(snaps[idx].tp    - tp)    > (Point/2.0))       { snaps[idx].tp    = tp;    changed = true; }
         if(changed){
            snaps[idx].version++;
            publish("MODIFY", snaps[idx]);
         }
      }
   }
}

void scan_closes_and_deletes(){
   // Any snapshot ticket not found in MODE_TRADES is considered CLOSED/DELETED
   for(int idx = snapsCount-1; idx >= 0; idx--){
      int ticket = snaps[idx].ticket;
      bool stillOpen = false;

      int total = OrdersTotal();
      for(int i=0; i<total; i++){
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderTicket() == ticket){ stillOpen = true; break; }
      }

      if(!stillOpen){
         snaps[idx].version++;
         publish("CLOSE", snaps[idx]);

         // remove element idx from array
         if(idx < snapsCount-1){
            // move last into idx
            snaps[idx] = snaps[snapsCount-1];
         }
         snapsCount--;
         ArrayResize(snaps, snapsCount);
      }
   }
}

// ======= MT4 Events =======
int OnInit(){
   // Use a second-based timer; we’ll throttle with PollMs inside OnTimer
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){
   EventKillTimer();
   // Clear array
   snapsCount = 0;
   ArrayResize(snaps, 0);
}

void OnTimer(){
   uint now = GetTickCount();
   if(now - g_lastTick < (uint)PollMs) return;
   g_lastTick = now;

   // Scan current book for OPENS/MODIFIES, then detect CLOSES
   scan_open_and_modify();
   scan_closes_and_deletes();
}
