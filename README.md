# Bill Insights: a private, on-device spending analyzer for iPhone

Import your **CIBC statements**, **Amazon order history**, and **photos or PDFs of bills and receipts**. The app pulls out every transaction, sorts it into a category, and shows where your money goes. It also points out subscriptions and unusual charges, and you can ask questions such as *"How much did I spend on food last month?"*

**Nothing leaves your phone.** Text recognition, categorization and the LLM all run on the device. The app makes no network requests.

| Tab | What it does |
|---|---|
| **Insights** | Monthly total vs. last month, a category donut, a 6‑month trend, subscriptions and their yearly cost, unusual charges, top merchants, and what you bought on Amazon. Also an **AI insight report** written by the on-device LLM. |
| **Transactions** | Search (it also searches Amazon product names), filter, and edit. When you change a category, the app learns from it. |
| **Import** | Files (PDF, CSV, images), the camera document scanner, Photos and screenshots, and the "Open in…" share sheet from the CIBC app, Mail or Files. |
| **Ask** | Chat with the on-device LLM. It answers by calling tools that query your real data, so it doesn't make up numbers. |
| **Settings** | Face ID lock, how Amazon orders are counted, imported documents (with their extracted text), CSV export, and wiping all data. |

---

## How it works

```
 PDF ─► PDFKit text ──┐
 Image/scan ─► Vision OCR ─┤
 CSV ─────────────────┴─► BillCore parsers ──(nothing found?)──► On-device LLM extraction
                                │
                                ▼
            Categoriser:  your corrections → CIBC hints → merchant rules
                          → NL-embedding nearest-neighbour (learns from you)
                          → on-device LLM for the leftovers
                                │
                                ▼
                     SwiftData (on device) ─► Analytics ─► Charts / LLM insights / Chat tools
```

### The "local ML" and "local LLM" parts

| Piece | Technology | Runs where |
|---|---|---|
| OCR for scans, photos and scanned PDFs | Apple **Vision** (`VNRecognizeTextRequest`, en‑CA / fr‑CA) | On device |
| PDF text | **PDFKit** (CIBC e‑statements have real text, so OCR isn't needed) | On device |
| Merchant categories | **NaturalLanguage** sentence embeddings + k‑nearest‑neighbour over the merchants you've labeled, plus prototype matching | On device |
| Reading receipts and bills, unknown statement layouts, insight reports, chat | Apple **Foundation Models** (the ~3B‑parameter Apple Intelligence LLM) with *guided generation* (`@Generable`), so output is always structured, plus **tool calling** for chat | On device, offline |

The deterministic parsers do most of the work (they're exact and fast). The LLM handles anything messy: paper receipts, phone and hydro bills, Amazon order screenshots, and statement formats the parsers don't know.

### Accuracy tips

1. **Best:** CIBC Online Banking → account → **Download transactions** → *Spreadsheet (CSV)*. These are exact amounts, with no OCR involved.
2. **Good:** CIBC **eStatement PDFs**. Credit card and chequing statements are both supported. For chequing statements, the parser uses the running balance to work out which lines are withdrawals and which are deposits.
3. **Amazon:** a card statement only says `AMAZON.CA $84.17`. To see *what* you bought, go to amazon.ca → **Request Your Data** → *Your Orders* and import `Retail.OrderHistory.1.csv`. Orders are matched to card charges by amount and date, so each charge shows its products and the spending isn't counted twice.
4. **Bills and receipts:** scan or screenshot them. The on-device LLM reads the merchant, date, total and line items.
5. Fix a category once and it's remembered for that merchant and used to train the categorizer.

---

## Install it on your iPhone

You need a **Mac with Xcode 26 or later** and a free Apple ID.

1. Clone this repo on your Mac and open `BillInsights.xcodeproj`.
2. Select the **BillInsights** target → *Signing & Capabilities* → choose your **Team** (your Apple ID). Change the bundle identifier to something unique, e.g. `com.yourname.billinsights`.
3. Plug in your iPhone (or pair it over Wi‑Fi). On the iPhone, turn on **Settings → Privacy & Security → Developer Mode**.
4. Pick your iPhone as the run destination and press **⌘R**.
5. The first time, trust the developer profile: **Settings → General → VPN & Device Management**.

> With a **free** Apple ID the app must be re-installed from Xcode every 7 days. A paid Apple Developer account ($99/yr) extends that to a year and lets you use TestFlight. Your data survives re-installs as long as you don't delete the app.

**Requirements**
- iOS 26 or later.
- The on-device LLM features need an **Apple Intelligence** iPhone (iPhone 15 Pro / 15 Pro Max, the iPhone 16 family, or newer) with Apple Intelligence turned on. On other iPhones the app still works: it falls back to the rule-based parsers, the embedding categorizer and rule-based insights. Only the Ask tab and the AI report are disabled.

**Try it quickly:** AirDrop or save the two files in [`SampleData/`](SampleData) to your phone (or the simulator) and import them.

---

## Project layout

```
BillInsights.xcodeproj         Xcode project (folder-synchronised, no file list to maintain)
BillInsights/
  App/                         App entry, tab bar, Face ID lock, "Open in…" handling
  Models/                      SwiftData models (LedgerEntry, ImportedDocument, MerchantRule)
  Services/                    PDF/OCR text extraction, import pipeline, Amazon order matching
  Intelligence/                Foundation Models wrapper, chat assistant + tools, NL categoriser
  Views/                       SwiftUI screens (Swift Charts)
Packages/BillCore/             Pure-Swift logic, unit tested:
  Parsers.swift                CIBC CSV, generic bank CSV, Amazon orders, CIBC credit-card & bank
                               statement text, receipt heuristics, document router
  Merchants.swift              Merchant name clean-up + Canadian merchant/category rules
  Analytics.swift              Totals, trends, subscriptions, anomalies, insight facts
  OrderMatcher.swift           Amazon order ↔ card charge matching
SampleData/                    Sample CIBC CSV + Amazon order history to try the app
project.yml                    Optional XcodeGen spec (regenerate the project with `xcodegen`)
```

Run the parser and analytics tests on a Mac:

```bash
cd Packages/BillCore && swift test
```

## Notes and limitations

- CIBC changes its PDF layout from time to time. If a statement imports with missing or odd lines, the CSV download is the reliable path. You can also check **Settings → Imported documents → Extracted text** to see what the parser received.
- Interac e‑Transfers and credit card payments are treated as **transfers**, so they aren't counted as spending (otherwise paying off your card would double-count). If an e‑Transfer is really rent or a purchase, change its category.
- The on-device model has a small context window (~4k tokens), so long statements are processed in chunks. Always double-check amounts on anything marked *"read by on-device AI"*.
