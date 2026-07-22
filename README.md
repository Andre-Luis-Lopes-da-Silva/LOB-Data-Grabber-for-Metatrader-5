# LOB Data Grabber for Metatrader 5

MetaTrader 5 Expert Advisor for collecting ordered limit order book (LOB) snapshots and exporting classical, dynamic, smoothed, and raw depth features to a semicolon-delimited CSV file.

**Version:** 3.10  
**Author:** André Luís Lopes da Silva  
**Platform:** MetaTrader 5 / MQL5  
**Default sampling:** one valid snapshot per second (but it can be changed, depending on availability of your brokerage)   
**Default depth:** five bid levels and five ask levels

> This program is a data collector, not a trading strategy. It does not submit, modify, or close orders and does not claim that any recorded metric is profitable or predictive by itself.

## 1. What the EA does

The EA subscribes to the MetaTrader 5 Depth of Market for a selected symbol, reads the complete snapshot returned by `MarketBookGet()`, reconstructs the best bid and ask levels in an explicit price order, computes LOB features, and writes the results to CSV.

Its main functions are:

1. subscribe to the symbol's market book;
2. read the complete book on a millisecond timer;
3. aggregate duplicate entries at the same price;
4. sort bids from highest to lowest price and asks from lowest to highest price;
5. reject empty or crossed/inverted snapshots;
6. retain up to five levels on each side;
7. calculate contemporaneous LOB metrics;
8. calculate one-sample changes (`d*` columns);
9. calculate exponential moving averages (`EMA_*` columns);
10. optionally save raw price and volume at each level;
11. buffer rows in memory and flush them periodically to disk.

The explicit ordering is essential. The EA does **not** assume that the array returned by `MarketBookGet()` is already arranged as best-to-worst bid and ask levels.

## 2. Processing workflow

For every accepted second, the EA follows this sequence:

1. `MarketBookGet()` retrieves the current book.
2. `BOOK_TYPE_BUY` entries are inserted in descending price order.
3. `BOOK_TYPE_SELL` entries are inserted in ascending price order.
4. Entries at the same price are aggregated.
5. The snapshot is discarded unless both sides exist and `BidPrice1 < AskPrice1`.
6. The EA calculates the raw, derived, delta, and EMA variables.
7. One row is added to the in-memory CSV buffer.
8. The buffer is written to disk every `InpFlushIntervalSec` seconds and again when the EA is removed.

Although `InpTimerMs` may be lower than 1,000 ms, a guard allows at most one saved row per server-time second. Therefore, this version is a **one-second snapshot collector**, not an event-by-event or millisecond book recorder.

## 3. Requirements

- MetaTrader 5 with access to Depth of Market for the selected symbol.
- A broker/data feed that exposes the book through the MQL5 Market Book API.
- The symbol must be visible and subscribed in Market Watch.
- The EA must remain attached to an open chart while data are collected.
- Algorithmic trading permission is normally required for EA execution in MT5, even though this EA sends no trades.

The quality and meaning of the output depend on the broker's feed. Market depth, volume units, update frequency, aggregation rules, and historical availability can differ across brokers and venues.

## 4. Installation

1. Save the source as `LOB Data Grabber MT5.mq5`.
2. In MetaTrader 5, open **File > Open Data Folder**.
3. Copy the file into `MQL5/Experts/`.
4. Open MetaEditor and compile the file.
5. Return to MT5 and refresh the **Expert Advisors** list.
6. Open a chart for the instrument to be collected.
7. Attach the EA to the chart.
8. Confirm the inputs and check the **Experts** and **Journal** tabs for initialization errors.

## 5. Inputs

| Input | Default | Meaning |
|---|---:|---|
| `InpSymbolInput` | empty | Symbol to collect. When empty, the chart symbol (`_Symbol`) is used. |
| `InpLevels` | `5` | Number of levels retained per side. Valid range: 1 to 5. Five is recommended and is the configuration for which the feature set was designed. |
| `InpTimerMs` | `1000` | Timer interval in milliseconds. The code still saves at most one row per server-time second. |
| `InpEmaPeriod` | `5` | EMA period in accepted snapshots. At one row per second, this is approximately five seconds, but gaps change the elapsed-time interpretation. |
| `InpFlushIntervalSec` | `10` | Approximate interval between disk flushes. |
| `InpFileName` | `Metrics` | Base name of the output file. |
| `InpSaveRawLevels` | `true` | Adds raw prices and volumes for five bid and five ask levels. |

The generated filename follows:

```text
<InpFileName>_YYYYMMDD_HHMMSS.csv
```

Example:

```text
Metrics_20260722_091500.csv
```

## 6. Where the CSV is saved

The code uses `FileOpen()` without `FILE_COMMON`. In a normal MT5 session, the CSV is therefore written inside the terminal's file sandbox:

```text
<MetaTrader data folder>/MQL5/Files/
```

Use **File > Open Data Folder** in MT5 and then open `MQL5/Files` to locate it. Strategy Tester executions use the tester's own file sandbox.

The file is ANSI encoded, uses a semicolon (`;`) as delimiter, and uses CRLF line endings.

## 7. Output groups

The output columns are organized in six groups:

1. time and market prices;
2. basic book metrics;
3. proximity-weighted and book-shape metrics;
4. one-sample deltas;
5. exponential moving averages;
6. optional raw levels.

Notation used below:

- $B_i$: bid volume at level $i$, where level 1 is the best bid;
- $A_i$: ask volume at level $i$, where level 1 is the best ask;
- $P_i^B$, $P_i^A$: bid and ask prices at level $i$;
- $L$: configured number of levels;
- $D_B=\sum_i B_i$, $D_A=\sum_i A_i$, and $D=D_B+D_A$;
- `point`: `SYMBOL_POINT` for the selected symbol.

## 8. Timestamp and price columns

| Column | Definition and interpretation |
|---|---|
| `Timestamp` | `TimeCurrent()` formatted to whole seconds. It is MT5 server time, not an exchange sequence number and not a millisecond timestamp. |
| `LastPrice` | Current `SYMBOL_LAST`. Depending on the feed, it may remain unchanged between trades. |
| `Bid` | Best reconstructed bid, equal to `BidPrice1`. |
| `Ask` | Best reconstructed ask, equal to `AskPrice1`. |

## 9. Basic LOB metrics

### `Ratio`

$$
\displaystyle\boldsymbol{\mathrm{Ratio}=\frac{D_B}{D_A}}
$$

Values above 1 indicate more displayed bid depth than ask depth across the retained levels; values below 1 indicate the opposite. The fallback is 0 when the denominator is zero.

This is a conventional depth-ratio representation, but the exact name and aggregation depth are not standardized across the literature.

### `Imbalance`

\[
\mathrm{Imbalance}=\frac{D_B-D_A}{D_B+D_A}
\]

This is a multi-level displayed-depth imbalance bounded by \([-1,1]\) when volumes are non-negative. Positive values indicate bid-side dominance; negative values indicate ask-side dominance.

It is related to the broad order-book imbalance literature, but it must not be confused with the event-based **Order Flow Imbalance (OFI)** of Cont, Kukanov, and Stoikov. This EA's `Imbalance` is calculated from a snapshot of resting depth, not from additions, cancellations, and executions at the best quotes.

### `TotalDepth`

\[
\mathrm{TotalDepth}=D_B+D_A
\]

Total displayed volume across the retained bid and ask levels. It is a liquidity/depth measure, not a guarantee that the displayed quantity can be executed without change.

### `SlopeBid` and `SlopeAsk`

Each slope is the ordinary least-squares coefficient from regressing the side's displayed volume on the zero-based level index:

\[
V_i=\beta_0+\beta_1 i+\varepsilon_i.
\]

The exported value is \(\beta_1\). A positive slope means volume tends to increase away from the best quote; a negative slope means it tends to decrease. These are implementation-specific linear summaries of book shape, not a canonical estimator with a single original paper.

### `Spread`

\[
\mathrm{Spread}=\frac{P_1^A-P_1^B}{\mathrm{point}}
\]

Quoted bid-ask spread expressed in platform points. A point is not necessarily the same as the exchange's minimum tick, so users should verify the symbol specification.

### `TopRatio`

\[
\mathrm{TopRatio}=\frac{B_1+A_1}{D}
\]

Fraction of the retained depth located at the best bid and best ask together. High values indicate that displayed liquidity is concentrated at the touch.

This exact formula is a project-specific concentration statistic.

### `ImbalN1`

\[
\mathrm{ImbalN1}=\frac{B_1-A_1}{B_1+A_1}
\]

Classical top-of-book queue imbalance. It compares the displayed queues at the best bid and best ask and ranges from -1 to 1. Positive values indicate a larger best-bid queue.

The direct research reference for this use is Gould and Bonart (2016), who studied queue imbalance as a predictor of the direction of the next mid-price move. Their empirical result does not imply that the metric is universally predictive for every instrument, venue, sampling method, or trading cost regime.

### `ImbalDeep`

\[
\mathrm{ImbalDeep}=
\frac{\sum_{i=2}^{L}B_i-\sum_{i=2}^{L}A_i}
{\sum_{i=2}^{L}B_i+\sum_{i=2}^{L}A_i}
\]

Imbalance beyond the best quotes. It separates deeper displayed liquidity from the top-level queue. This exact split is implementation-specific.

### `DepthDelta`

\[
\mathrm{DepthDelta}_t=D_t-D_{t-1}
\]

Change in retained total depth between consecutive accepted samples. It mixes new orders, cancellations, executions, price-level shifts, and any feed changes occurring between snapshots.

### `MicroPriceDist`

First, the EA calculates the top-of-book volume-weighted microprice:

\[
\mathrm{MicroPrice}=
\frac{P_1^B A_1+P_1^A B_1}{B_1+A_1}.
\]

Then it exports:

\[
\mathrm{MicroPriceDist}=
\frac{\mathrm{LastPrice}-\mathrm{MicroPrice}}{\mathrm{point}}.
\]

The cross-weighting moves the estimate toward the ask when the bid queue is larger and toward the bid when the ask queue is larger. Stoikov's micro-price research provides the principal reference for microprice as a high-frequency estimate of future prices. The EA exports distance from the last trade to its static top-level microprice, not Stoikov's full empirical state-dependent estimator.

### `AggBuy` and `AggSell`

\[
\mathrm{AggBuy}_t=\max(0,A_{1,t-1}-A_{1,t})
\]

\[
\mathrm{AggSell}_t=\max(0,B_{1,t-1}-B_{1,t})
\]

These are **heuristic top-queue depletion proxies**. A fall in best-ask volume is treated as possible buying aggression, and a fall in best-bid volume as possible selling aggression.

They are not true aggressor-side trade volume. They cannot distinguish executions from cancellations, replenishment, or a change in the best price. Use trade/tick flags or Times & Trades data when actual aggressor classification is required. The conceptual relation to order-book events is discussed by Cont, Kukanov, and Stoikov, but the formulas above are specific to this EA and are not their OFI definition.

## 10. Proximity-weighted and book-shape metrics

### `WeightedImbalance`

With \(w_i=L-i+1\), so that the nearest level receives the largest weight:

\[
\mathrm{WeightedImbalance}=
\frac{\sum_i w_iB_i-\sum_i w_iA_i}
{\sum_i w_iB_i+\sum_i w_iA_i}.
\]

For five levels, the weights are 5, 4, 3, 2, and 1. This metric emphasizes liquidity closer to execution. The general idea of using multiple LOB levels is supported by multi-level imbalance research, but this exact linear weighting scheme is a project-specific design choice and has no claimed single original source.

### `PressureBid`, `PressureAsk`, and `PressureRatio`

\[
\mathrm{PressureBid}=\sum_{i=1}^{L}\frac{B_i}{i},
\qquad
\mathrm{PressureAsk}=\sum_{i=1}^{L}\frac{A_i}{i}
\]

\[
\mathrm{PressureRatio}=
\frac{\mathrm{PressureBid}}{\mathrm{PressureAsk}}.
\]

These variables discount depth by its level number, giving the best quotes the highest contribution. They are custom proximity-weighted pressure measures, not standardized academic indicators.

### `WeightedMicroPrice` and `WeightedMicroDist`

\[
\mathrm{WeightedMicroPrice}=
\frac{P_1^B\,\mathrm{PressureAsk}+P_1^A\,\mathrm{PressureBid}}
{\mathrm{PressureBid}+\mathrm{PressureAsk}}
\]

\[
\mathrm{WeightedMicroDist}=
\frac{\mathrm{LastPrice}-\mathrm{WeightedMicroPrice}}{\mathrm{point}}.
\]

This extends the top-level microprice idea by replacing the two best-queue volumes with the EA's multi-level pressure measures. It is therefore a custom extension inspired by microprice, not the original Stoikov estimator.

### `DepthConc2`, `DepthConc3`, and `DepthConc5`

\[
\mathrm{DepthConc}k=
\frac{\sum_{i=1}^{k}(B_i+A_i)}{D}.
\]

They report the fraction of retained depth found in the nearest 2, 3, or 5 levels. With `InpLevels = 5`, `DepthConc5` is mechanically 1 whenever total depth is positive; it serves mainly as a consistency field. With fewer configured levels, zero-filled unused slots mean the same caveat applies relative to the retained book.

These exact concentration ratios are descriptive project features.

### `BookEntropy`

For the ten-element vector containing five bid and five ask volumes:

\[
p_j=\frac{V_j}{\sum_kV_k},
\qquad
\mathrm{BookEntropy}=
\frac{-\sum_jp_j\ln p_j}{\ln(10)}.
\]

Zero-volume elements contribute zero. The result is intended to lie in \([0,1]\): lower values mean volume is concentrated in fewer price-side cells; higher values mean it is more evenly distributed.

The mathematical foundation is Shannon entropy (Shannon, 1948). Its application to the ten LOB cells and the normalization by `ln(10)` are implementation choices made in this EA. When fewer than five levels are populated, the fixed ten-cell normalization should be considered when comparing samples.

### `BookSymmetry`

\[
\mathrm{BookSymmetry}=1-|\mathrm{Imbalance}|.
\]

The metric equals 1 when retained bid and ask depth are equal and approaches 0 as one side dominates. This exact transformation is project-specific.

### `BookConvexity`

\[
\mathrm{BookConvexity}=
\frac{\sum_{i=1}^{2}(B_i+A_i)}
{\sum_{i=3}^{L}(B_i+A_i)}.
\]

It compares near-touch depth with farther retained depth. Values above 1 mean more depth is concentrated in the first two levels; values below 1 mean more is located farther away.

Order-book shape and depth profiles are established research topics, including Bouchaud, Mézard, and Potters (2002). However, this ratio is a **simple custom proxy** and should not be presented as the canonical convexity estimator from that literature. For `InpLevels <= 2`, the denominator is zero and the code returns 0, so the field is not meaningful under that configuration.

## 11. Dynamic delta columns

Every `d*` variable is the current raw value minus the value from the previous **accepted snapshot**:

\[
dX_t=X_t-X_{t-1}.
\]

The columns are:

- `dRatio`
- `dImbalance`
- `dTotalDepth`
- `dSpread`
- `dMicroDist`
- `dSlopeBid`
- `dSlopeAsk`
- `dWeightedImbalance`
- `dPressureRatio`
- `dWeightedMicroDist`
- `dDepthConc2`
- `dBookEntropy`

They are commonly one-second changes under uninterrupted collection, but they are not guaranteed to represent exactly one elapsed second. If a snapshot is missing or rejected, the next delta spans the gap between accepted rows. The first valid row has delta values equal to zero.

## 12. EMA columns

For each smoothed variable, the EA uses:

\[
\alpha=\frac{2}{N+1},
\qquad
\mathrm{EMA}_t=\mathrm{EMA}_{t-1}+\alpha(X_t-\mathrm{EMA}_{t-1}),
\]

where \(N=\texttt{InpEmaPeriod}\). The first accepted observation initializes the EMA to the raw value.

The output contains EMA versions of the raw metrics, not of the `d*` metrics:

- `EMA_Ratio`, `EMA_Imbalance`, `EMA_TotalDepth`
- `EMA_SlopeBid`, `EMA_SlopeAsk`, `EMA_Spread`
- `EMA_TopRatio`, `EMA_ImbalN1`, `EMA_ImbalDeep`
- `EMA_DepthDelta`, `EMA_MicroDist`
- `EMA_AggBuy`, `EMA_AggSell`
- `EMA_WeightedImbalance`
- `EMA_PressureBid`, `EMA_PressureAsk`, `EMA_PressureRatio`
- `EMA_WeightedMicroDist`
- `EMA_DepthConc2`, `EMA_DepthConc3`, `EMA_DepthConc5`
- `EMA_BookEntropy`, `EMA_BookSymmetry`, `EMA_BookConvexity`

EMA is a standard smoothing operator. Here its purpose is noise reduction; it does not transform a descriptive LOB feature into a validated trading signal.

## 13. Raw level columns

When `InpSaveRawLevels = true`, the EA appends:

```text
BidPrice1;BidVol1;AskPrice1;AskVol1; ... ;BidPrice5;BidVol5;AskPrice5;AskVol5
```

Level 1 is always the best reconstructed quote. Bid prices must descend with level number, and ask prices must ascend. Unavailable/unretained array positions are exported as zero.

Saving raw levels is strongly recommended because it permits independent recalculation, schema auditing, order validation, and the construction of future features without rerunning the live collection.

## 14. Data-quality checks

The EA implements the following safeguards:

- validates `InpLevels` in the range 1 to 5;
- fails initialization if the book subscription cannot be opened;
- scans the complete returned book instead of assuming provider array order;
- rejects non-positive price or volume entries during level insertion;
- falls back to `volume_real` only when integer `volume` is non-positive;
- aggregates duplicate entries at the same price;
- requires at least one bid and one ask;
- rejects a snapshot when best bid is greater than or equal to best ask;
- limits output to one row per server-time second;
- flushes buffered lines periodically and at deinitialization.

Recommended post-collection validation:

1. verify that timestamps are strictly increasing within each file;
2. verify `Bid == BidPrice1` and `Ask == AskPrice1`;
3. verify `Bid < Ask`;
4. verify descending bid prices and ascending ask prices for populated levels;
5. verify non-negative volumes;
6. record coverage, missing seconds, first timestamp, and last timestamp from the file contents rather than trusting the filename date;
7. do not assume that every file covers a complete trading session;
8. recompute key metrics from raw levels and compare them with the exported columns.

## 15. Important limitations

### Snapshot data are not event data

Several book changes can occur between two one-second observations. The collector cannot reconstruct their order, distinguish all additions from cancellations and trades, or measure queue priority.

### Displayed liquidity is not executed liquidity

Resting quantities may be cancelled, replenished, hidden, or modified. Book imbalance measures displayed supply and demand at the observed instant.

### `AggBuy` and `AggSell` are not trade signs

They are queue-depletion proxies contaminated by cancellation and price changes. They must not be described as true buyer- or seller-initiated volume.

### The CSV timestamp has one-second resolution

The file does not preserve exchange timestamps, milliseconds, event sequence numbers, or network latency.

### Missing rows are possible

The EA writes no row when `MarketBookGet()` fails, one side is empty, or the reconstructed book is crossed/invalid. Deltas and EMAs advance by accepted observation, not by a guaranteed wall-clock interval.

### Features depend on the configured depth

Results obtained with different `InpLevels` values are not directly equivalent. Several formulas and the fixed ten-cell entropy representation were designed primarily for five levels.

### Raw arrays always contain five slots

The CSV raw-level loop and entropy vector use five positions per side even when fewer levels are configured or available. Missing positions are zero. Interpret entropy, concentration, and convexity accordingly.

### No trading edge is asserted

The EA only creates research data. Predictive and economic value must be tested out of sample with executable bid/ask prices, transaction costs, latency assumptions, session separation, and leakage-free validation.

## 16. Minimal Python loading example

```python
from pathlib import Path
import pandas as pd

path = Path("Metrics_20260722_091500.csv")

df = pd.read_csv(path, sep=";", encoding="latin-1")
df["Timestamp"] = pd.to_datetime(df["Timestamp"], errors="coerce")
df = df.sort_values("Timestamp").reset_index(drop=True)

assert (df["Bid"] < df["Ask"]).all()
assert (df["Bid"] == df["BidPrice1"]).all()
assert (df["Ask"] == df["AskPrice1"]).all()

print(df.shape)
print(df[["Timestamp", "Bid", "Ask", "ImbalN1", "Imbalance"]].head())
```

For multiple files, use the timestamps inside each file to identify the actual observation date and coverage. Do not infer session completeness from filenames.

## 17. Metric provenance summary

| Metric family | Status | Closest defensible source |
|---|---|---|
| Best-level queue imbalance (`ImbalN1`) | Classical formula | Gould & Bonart (2016) |
| Multi-level depth imbalance (`Imbalance`) | Conventional extension | Broad LOB/depth-imbalance literature; exact depth aggregation is implementation-dependent |
| Microprice | Classical top-of-book construction | Stoikov (2018) |
| `WeightedMicroPrice` | Custom extension | Inspired by microprice; exact pressure substitution is original to this implementation |
| Event/order-flow interpretation | Related theory, not equivalent formula | Cont, Kukanov & Stoikov (2014) |
| `AggBuy`, `AggSell` | Custom and limited proxy | No claim of canonical origin; not OFI and not true aggressor volume |
| Book entropy | Shannon measure applied to LOB cells | Shannon (1948); LOB mapping and normalization are custom |
| Book shape, slopes, concentration | Descriptive LOB family | Bouchaud, Mézard & Potters (2002); exact formulas here are custom |
| `WeightedImbalance`, `Pressure*` | Custom proximity weighting | No single original reference claimed |
| `BookSymmetry`, `BookConvexity` | Custom summary statistics | Related to book-shape research; exact formulas are custom |
| `d*` features | First differences | Standard time-series transformation |
| `EMA_*` features | Exponential smoothing | Standard smoothing transformation |

## 18. References

1. Gould, M. D., & Bonart, J. (2016). *Queue Imbalance as a One-Tick-Ahead Price Predictor in a Limit Order Book*. Market Microstructure and Liquidity, 2(2), 1650006. https://arxiv.org/abs/1512.03492
2. Stoikov, S. (2018). *The Micro-Price: A High-Frequency Estimator of Future Prices*. Quantitative Finance, 18(12), 1959-1966. https://papers.ssrn.com/sol3/papers.cfm?abstract_id=2970694
3. Cont, R., Kukanov, A., & Stoikov, S. (2014). *The Price Impact of Order Book Events*. Journal of Financial Econometrics, 12(1), 47-88. https://arxiv.org/abs/1011.6402
4. Bouchaud, J.-P., Mézard, M., & Potters, M. (2002). *Statistical Properties of Stock Order Books: Empirical Results and Models*. Quantitative Finance, 2, 251-256. https://arxiv.org/abs/cond-mat/0203511
5. Shannon, C. E. (1948). *A Mathematical Theory of Communication*. Bell System Technical Journal, 27, 379-423 and 623-656. https://ieeexplore.ieee.org/document/6773024
6. MQL5 documentation: *MarketBookAdd*, *MarketBookGet*, *EventSetMillisecondTimer*, and *FileOpen*. https://www.mql5.com/en/docs/marketinformation/marketbookadd

## 19. Suggested citation of the software

Until a formal software archive or DOI is available, cite the collector with its author, title, version, platform, and year:

```text
Lopes da Silva, A. L. (2026). LOB Data Grabber for Metatrader 5 (Version 3.10)
[MetaTrader 5 Expert Advisor].
```

## 20. License

This Expert Advisor is under GNU General Public License version 3.0 (GPL v3). 
