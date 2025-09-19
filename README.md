# MT4 → MT5 Copy Trading Bridge

A fast, local copy trading bridge that mirrors trades from an **MT4 account** into an **MT5 account** running on the same Windows VPS.

- **Relay:** Python FastAPI server (localhost)  
- **Sender EA (MT4):** Publishes trade events (open, modify, close, delete) to the relay  
- **Receiver EA (MT5):** Polls the relay and mirrors trades with flexible risk & symbol mapping  

---

## 📐 Architecture

```

MT4 Terminal ──► Sender EA ──► Python Relay ──► Receiver EA ──► MT5 Terminal

````

- Communication is strictly local (`127.0.0.1`) → ultra-low latency, no DLLs required  
- Events are published by MT4 as JSON → Relay stores in queue → MT5 pulls and executes  
- Supports market and pending orders, modifies, and closes  

---

## ⚙️ Installation

### 1. Python Relay
```bash
pip install fastapi uvicorn pydantic
python mt_relay.py
````

* Save the relay script as `mt_relay.py`
* Run on your VPS
* Confirm health endpoint: open [http://127.0.0.1:8787/health](http://127.0.0.1:8787/health)

---

### 2. MT4 Sender EA

1. Copy `MT4_Sender_Simple.mq4` into:
   `MQL4/Experts/`
2. Compile in **MetaEditor**
3. Attach to **one chart** (any symbol, any timeframe)
4. In MT4:

   * Go to **Tools → Options → Expert Advisors**
   * Enable **Allow WebRequest for listed URL**
   * Add: `http://127.0.0.1:8787`

---

### 3. MT5 Receiver EA

1. Copy `MT5_Receiver_Simple.mq5` into:
   `MQL5/Experts/`
2. Compile in **MetaEditor**
3. Attach to **one chart** (any symbol)
4. In MT5:

   * Go to **Tools → Options → Expert Advisors**
   * Enable **Allow WebRequest for listed URL**
   * Add: `http://127.0.0.1:8787`

---

## 🎛 Input Settings

### MT4 Sender EA

| Input          | Description                                                                 |
| -------------- | --------------------------------------------------------------------------- |
| `RelayURL`     | URL of relay (default: `http://127.0.0.1:8787`)                             |
| `AuthToken`    | Must match between relay, sender, and receiver                              |
| `PollMs`       | Scan interval in ms (default `250`)                                         |
| `MagicFilter`  | If `-1`, copy all trades. Otherwise only trades with this magic number      |
| `SymbolFilter` | Comma-separated list of symbols to copy (e.g. `XAUUSD,EURUSD`). Empty = all |
| `SendPending`  | Copy pending orders (`true/false`)                                          |
| `SendMarket`   | Copy market orders (`true/false`)                                           |

---

### MT5 Receiver EA

| Input            | Description                                            |
| ---------------- | ------------------------------------------------------ |
| `RelayURL`       | Same as sender                                         |
| `AuthToken`      | Same as sender                                         |
| `PollMs`         | Polling interval (default `250`)                       |
| `AllowedSymbols` | Comma-separated list to copy. Empty = all              |
| `SymbolSuffix`   | Append broker suffix (e.g. `.m`, `.pro`)               |
| `LotMultiplier`  | Multiply source lots by this factor                    |
| `UseRiskPct`     | If true, override lot size with risk-based calculation |
| `RiskPct`        | % of balance risked per trade (if above enabled)       |
| `Deviation`      | Maximum slippage in points                             |
| `MaxBatch`       | Max number of signals per pull                         |

---

## 🔄 Symbol Mapping

* If symbols differ between MT4 and MT5 (e.g. `XAUUSD` → `XAUUSD.m`), set the `SymbolSuffix` input in MT5 Receiver
* Relay forwards symbols as-is; Receiver handles suffix adjustments
* For **non-suffix mappings** (e.g. `GER30` → `DE40`), extend `map_symbol()` in EA or add a `symbol_map` dictionary in the relay

---

## 🧩 Best Practices

* **Test on demo** accounts first
* **Check suffixes** carefully; mismatches = no trades copied
* Keep both MT4 & MT5 terminals + relay on the **same VPS**
* Use a strong `AuthToken` (relay only listens on localhost, but still)
* For crash safety: extend relay with SQLite persistence

---

## 🛠 Roadmap

* ✅ MT4 → MT5 one-way copying
* 🔄 Optional MT5 → MT4 feedback
* 📈 Advanced risk/margin filters
* 🔧 Persistent trade mapping with SQLite

---

## 📜 License

MIT — use freely at your own risk.
Always comply with your broker’s terms of service.
