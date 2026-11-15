# HWR-LEARN Native Recognition Pipeline Specification

This document provides the complete algorithmic specification of the HWR-LEARN handwriting recognition engine, ported natively from `reference/hwr_learn_improved.asm` and incorporating the required algorithmic fixes and modernizations.

---

## 1. High-Level Architecture

The handwriting recognition system processes user ink strokes through an 8-stage pipeline:

```
[Raw Pen / Mouse Strokes]
           │
           ▼
[1. Stroke Grouping & Connected-Letter Splitting]
           │
           ▼
[2. Line Assignment & Reading Order Sort]
           │
           ▼
[3. Robust Line Statistics & Geometric Reference Calculation]
           │
           ▼
[4. Grid Rasterization (8x8 & 5x7) & Feature Extraction]
           │
           ▼
[5. Multi-Model Scoring & Fusion]
   ├── [A] Nearest-Neighbour Seeds (4,369 font skeletons)
   ├── [B] Shift-Tolerant Learned Bank (Normalized distance + Trust bonus)
   ├── [C] 5x7 Multi-Prototype Matcher (134 base + learned prototypes)
   └── [D] Incremental Perceptron (62 classes, 64-bit input)
           │
           ▼
[6. Top-3 Candidate Ranking & Confidence Scoring]
           │
           ▼
[7. Word Grouping & Shape-Ambiguity Resolution]
           │
           ▼
[Recognized Character Stream with Confidence & Formatting]
```

---

## 2. Stroke Acquisition & Representation

- Each stroke consists of a sequence of 2D coordinates `[(x_0, y_0), (x_1, y_1), ..., (x_k, y_k)]`.
- The user draws with mouse, touch, or pen stylus.
- Smoothing: For visual display on the modern canvas, Catmull-Rom or Bezier spline interpolation is applied with anti-aliasing; however, the recognition engine consumes the exact raw sampled points.
- Bounding Box of stroke $i$:
  $$X_{\min, i} = \min_{j} x_{i,j}, \quad X_{\max, i} = \max_{j} x_{i,j}$$
  $$Y_{\min, i} = \min_{j} y_{i,j}, \quad Y_{\max, i} = \max_{j} y_{i,j}$$

---

## 3. Segmentation

### 3.1 Stroke Grouping into Glyphs (`MergeGroups`)
Strokes belonging to the same character (e.g., crossbars in 't', dots in 'i' and 'j', multi-stroke letters like 'E', 'H') are clustered based on spatial proximity:
- Horizontal tolerance: $\Delta X = 2\text{ px}$ (`MARGIN = 2`)
- Vertical tolerance: $\Delta Y = 16\text{ px}$ (`MARGIN_Y = 16`)
Two strokes $A$ and $B$ are merged if their bounding boxes expanded by $(\Delta X, \Delta Y)$ overlap:
$$\max(X_{\min, A}, X_{\min, B}) \le \min(X_{\max, A}, X_{\max, B}) + \Delta X$$
$$\text{and } \max(Y_{\min, A}, Y_{\min, B}) \le \min(Y_{\max, A}, Y_{\max, B}) + \Delta Y$$
Connected components are iteratively merged via union-find until no further merges occur.

### 3.2 Connected Letter Splitter (Fix 5)
When cursive or ligature writing joins letters into a single stroke (such as "ar" or "ou"), the merged glyph width is significantly larger than typical glyphs in that line:
- If glyph width $W > 1.75 \times \text{median\_glyph\_width}$ and $W > 28\text{ px}$:
  1. Compute the vertical projection histogram (column ink density $D(x)$ across all columns $x \in [X_{\min} + 0.25 W, X_{\max} - 0.25 W]$).
  2. Locate the prominent valley (minimum ink density) column $x_{\text{split}}$.
  3. If $D(x_{\text{split}}) \le 0.4 \times \text{peak\_density}$, split the stroke points / rasterized glyph at $x_{\text{split}}$ into two distinct glyphs.
  4. Both resulting glyphs are then processed independently.

---

## 4. Line Assignment & Reading Order

### 4.1 Vertical Line Clustering (`AssignLines`)
A glyph with vertical span $[Y_1, Y_2]$ and height $H = Y_2 - Y_1 + 1$ is tested against existing line vertical bounds $[LY_1, LY_2]$:
$$\text{overlap} = \max\left(0, \min(Y_2, LY_2) - \max(Y_1, LY_1) + 1\right)$$
A glyph fits an existing line if:
$$\text{overlap} \times 100 \ge 45 \times \min(H, LY_2 - LY_1 + 1)$$
If it fits, the line bounds are expanded to encompass the glyph. If it fits no existing line, a new line is spawned.

### 4.2 Top-to-Bottom Line Ranking & Left-to-Right Sorting (`SortChars`)
Lines are sorted by vertical center $Y_{\text{center}} = \frac{LY_1 + LY_2}{2}$ ascending.
Within each line, glyphs are sorted by left coordinate $X_1$ ascending.

---

## 5. Per-Line Statistics & Outlier Filtering (Fix 1)

In the original assembly, the line reference height was simply the tallest glyph in the line. A single long tail (such as an extended 'y' or exclamation point) caused ordinary letters like 'e', 'o', 'w' to be classified as tiny punctuation.

### 5.1 Outlier-Robust Reference Height (`RobustLR`)
For line $L$:
1. Collect heights of all "real" glyphs (width $> 12\text{ px}$ or height $> 12\text{ px}$).
2. Sort heights in ascending order: $H_0 \le H_1 \le \dots \le H_{k-1}$.
3. If $k \ge 3$:
   - Compute Median Height: $H_{\text{med}} = H_{\lfloor k/2 \rfloor}$.
   - Compute 75th Percentile Height: $H_{75} = H_{\lfloor 3k/4 \rfloor}$.
   - Define outlier cutoff:
     $$\text{Cap} = \max(1.6 \times H_{\text{med}}, 1.25 \times H_{75})$$
   - Line Reference Height $LR$ is set to the largest glyph height $\le \text{Cap}$.
4. If $k < 3$, $LR = \max(H)$.

### 5.2 Baseline & Spacing Thresholds
- **Baseline ($L_{\text{base}}$)**: Median bottom coordinate ($Y_2$) of real glyphs in line.
- **Word Space Gap Threshold ($L_{\text{gap}}$)**:
  $$L_{\text{gap}} = \text{clamp}(\text{round}(0.45 \times LR), 16, 60)$$
  Gaps between consecutive glyphs exceeding $L_{\text{gap}}$ generate space characters (`' '`).

### 5.3 Line Reference Heights ($LX$ and $LC$)
Using unambiguous glyphs in the line:
- $LX$ (x-height): median height of confirmed lowercase letters {'a', 'e', 'n', 'r'}.
- $LC$ (capital height): median height of confirmed capital letters {'A'..'Z'}.

---

## 6. Rasterization & Feature Extraction

Each glyph bounding box is mapped to two standardized binary grids:

### 6.1 8x8 Binary Grid (`GRID8`)
- Dimensions: 8 rows $\times$ 8 columns.
- Dynamic ink threshold:
  $$\text{DYN\_INKMIN}_8 = \text{clamp}\left(\left\lfloor \frac{W \times H}{350} \right\rfloor, 2, 14\right)$$
- Cell $(r, c)$ covering:
  $$y \in \left[Y_1 + \left\lfloor\frac{r \cdot H}{8}\right\rfloor, Y_1 + \left\lfloor\frac{(r+1) \cdot H}{8}\right\rfloor - 1\right]$$
  $$x \in \left[X_1 + \left\lfloor\frac{c \cdot W}{8}\right\rfloor, X_1 + \left\lfloor\frac{(c+1) \cdot W}{8}\right\rfloor - 1\right]$$
- If ink pixel count $\ge \text{DYN\_INKMIN}_8$, bit $(7 - c)$ in row $r$ is set to 1.
- **Auto-Centering (`AutoCenterGrid`)**:
  If the grid does not touch all 4 outer edges, it is shifted by $\pm 1$ cell horizontally and vertically to maximize alignment with seed skeletons.

### 6.2 5x7 Binary Grid (`G57`)
- Dimensions: 7 rows $\times$ 5 columns.
- Dynamic ink threshold:
  $$\text{DYN\_INKMIN}_{57} = \text{clamp}\left(\left\lfloor \frac{W \times H}{210} \right\rfloor, 1, 5\right)$$
- If cell ink $\ge \text{DYN\_INKMIN}_{57}$, bit $(4 - c)$ in row $r$ is set to 1.

### 6.3 Geometric Attributes
- Aspect Ratio: $\text{aspect} = \min\left(255, \left\lfloor \frac{W \times 16}{H} \right\rfloor\right)$.
- Height Ratio: $\text{ratio} = \min\left(255, \left\lfloor \frac{H \times 100}{LR} \right\rfloor\right)$.
- Classification Flags:
  - **Bit 0 (Tall)**: $\text{ratio} \ge \text{CASE\_T}$ (default 68%), or in uniform lines $H \ge \text{ABS\_T}$ (default 42 px).
  - **Bit 1 (Descender - Fix 4)**: Relaxed from 22% to 12%:
    $$(Y_2 - L_{\text{base}}) \times 100 > H \times 12$$
  - **Bit 2 (Tiny)**: $W \le 12$ and $H \le 12$, or $H \times 100 < 32 \times LR$ and $W \times 100 < 45 \times LR$.
  - **Bit 3 (Dash)**: $H \times 100 < 24 \times LR$ and $W \ge 2H$ and $W \times 100 \ge 28 \times LR$.
  - **Bit 4 (Uniform line / Absolute)**: Minimum line glyph height $\ge 78\% \times LR$.
  - **Bit 5 (Bank hit)**: Overridden by user-taught sample.

---

## 7. Multi-Model Scoring & Fusion

### 7.1 Seed Memory Matching [C]
- 4,369 pre-computed 8x8 font skeletons extracted from the assembly RODATA.
- For each character class $c \in [33..126]$:
  $$DK[c] = \min_{s \in \text{Seeds}(c)} \text{popcount}(\text{GRID8} \oplus s_{\text{grid}})$$

### 7.2 Shift-Tolerant Bank Distance [Fix 3 & Fix 2]
Given stored bank sample $(G_8, G_{57}, \text{aspect}_B, \text{flags}_B)$ for class $c$:
1. Compute 3x3 binary dilation `Dilate8` of both current $\text{GRID8}$ and stored $G_8$:
   $$\text{Dilate8}(G)[r, c] = \bigvee_{\Delta r \in \{-1,0,1\}} \bigvee_{\Delta c \in \{-1,0,1\}} G[r+\Delta r, c+\Delta c]$$
2. Shift-Tolerant 8x8 Distance (`TolDist8`):
   $$D_{\text{tol8}} = \text{popcount}(\text{GRID8} \land \neg \text{Dilate8}(G_8)) + \text{popcount}(G_8 \land \neg \text{Dilate8}(\text{GRID8}))$$
3. Exact 5x7 Distance:
   $$D_{57} = \sum_{r=0}^{6} \text{popcount}(G_{57}[r] \oplus \text{G57}[r])$$
4. Aspect Penalty:
   $$P_{\text{aspect}} = \left\lfloor \frac{|\text{aspect}_B - \text{aspect}|}{8} \right\rfloor$$
5. Case/Size Penalty:
   $$P_{\text{size}} = 4 \quad \text{if } (\text{flags}_B \oplus \text{flags}) \land 1 \text{ and } c \in \text{AmbiguousGroups, else } 0$$
6. Total Raw Bank Distance:
   $$D_{\text{raw}} = D_{\text{tol8}} + D_{57} + P_{\text{aspect}} + P_{\text{size}}$$
7. **Bank Distance Normalization & Trust Bonus (Fix 2)**:
   $$D_{\text{eff}} = \max\left(0, \left\lfloor \frac{D_{\text{raw}} \times 5}{8} \right\rfloor - 3\right)$$
   If $D_{\text{eff}} < DK[c]$, set $DK[c] = D_{\text{eff}}$.
8. **Outright Override Rule (Fix 2)**:
   If $\min(D_{\text{raw}}) \le 14$, the closest taught bank sample overrides outright:
   $$\text{BestClass} = \text{BankClass}, \quad \text{BANKHIT} = 1$$

### 7.3 5x7 Multi-Prototype Matcher [B]
- 134 base prototypes + dynamically added learned prototypes (up to 64).
- For each class $c$:
  $$DPR[c] = \min_{p \in \text{Prototypes}(c)} \sum_{r=0}^{6} \text{popcount}(p[r] \oplus \text{G57}[r])$$
  If class $c$ has no prototypes, $DPR[c] = 8$ (neutral penalty).

### 7.4 Trainable Perceptron [A]
- 62 classes (EMNIST order: 0..9, A..Z, a..z).
- Input vector $X \in \{0, 1\}^{64}$ from $\text{GRID8}$.
- Logit for class $i$:
  $$PSC[i] = \text{BIAS}[i] + \sum_{j=0}^{63} \text{WTS}[i, j] \cdot X[j]$$
  where $\text{WTS} \in [-127, 127]$, $\text{BIAS} \in \text{INT16}$.
- Let $PSMAX = \max_i PSC[i]$.

### 7.5 Score Fusion Formula
For each ASCII class $c \in [33..126]$:
$$F[c] = -16 \cdot DK[c] - 4 \cdot DPR[c] + \Delta_{\text{perc}}[c]$$
where:
$$\Delta_{\text{perc}}[c] = \begin{cases}
\left\lfloor \frac{PSC[\text{idx}(c)] - PSMAX}{8} \right\rfloor & \text{if } c \in \text{PerceptronClasses} \\
-12 & \text{otherwise}
\end{cases}$$

### 7.6 Top-3 Candidates & Confidence Estimation
- Candidates are sorted by fusion score $F[c]$ descending.
- Top candidate has score $F_1$, second $F_2$, third $F_3$.
- Margin to different shape group:
  $$\text{Margin} = F_1 - \max_{c \notin \text{Group}(c_1)} F[c]$$
- Normalized confidence percentage:
  $$\text{Conf}_i = \text{clamp}\left(50 + 2 \cdot (F_i - F_2), 5, 99\right) \quad \text{for } i \in \{1, 2, 3\}$$
  (If bank override triggered, candidate 1 receives 98% confidence).
- Character is marked **Sure (Green)** if $\text{Margin} \ge 32$ and no ambiguity flags are raised.
- Character is marked **Unsure (Red)** if $\text{Margin} < 32$ or flagged as borderline/ambiguous.

---

## 8. Ambiguity Resolution & Word Context

Look-alike shape families are resolved after initial scoring:
- Group 0: {C, c}
- Group 1: {K, k}
- Group 2: {M, m}
- Group 3: {O, o, 0}
- Group 4: {P, p}
- Group 5: {S, s, 5}
- Group 6: {U, u}
- Group 7: {V, v}
- Group 8: {W, w}
- Group 9: {X, x}
- Group 10: {Y, y}
- Group 11: {Z, z, 2}
- Group 12: {I, l, 1}
- Group 13: {B, 8}

### 8.1 Digit vs. Letter Disambiguation
For a word containing $N_{\text{digits}}$ digits and $N_{\text{letters}} = N_{\text{upper}} + N_{\text{lower}}$:
- If $N_{\text{digits}} > N_{\text{letters}}$, choose the digit variant.
- If $N_{\text{letters}} > N_{\text{digits}}$, choose the letter variant.
- If tied, retain raw classifier choice and mark confidence as unsure.

### 8.2 Case Disambiguation
- 'p', 'y': if descender flag (Bit 1) is active $\implies$ lowercase.
- Comparison with mid-line threshold:
  $$\text{Threshold} = \frac{LX + LC}{2}$$
- If glyph height $> \text{Threshold}$ and glyph is first in word $\implies$ uppercase.
- If in the middle of a predominantly lowercase word ($N_{\text{lower}} > N_{\text{upper}}$) $\implies$ lowercase.
- Borderline height (within $\pm 3\text{ px}$ of threshold) marks character as unsure.

---

## 9. Online Incremental Learning

Whenever the user selects a candidate or types a correction:
1. **Case Adaptation (`AdaptCase`)**:
   If changing between upper and lowercase of the same letter, update `CASE_T` or `ABS_T` so subsequent letters reflect the user's specific sizing style.
2. **Bank Storage (`AddBank`)**:
   Write the 8x8 grid, 5x7 grid, label, aspect, and flag to SQLite database with `synchronous=FULL` and WAL mode.
3. **Incremental Perceptron Training (`TrainGrid`)**:
   For target class $T$ and winning class $W \ne T$:
   $$\text{WTS}[T, j] \leftarrow \min(127, \text{WTS}[T, j] + 4) \quad \forall j \in \text{ActivePixels}$$
   $$\text{BIAS}[T] \leftarrow \text{BIAS}[T] + 8$$
   $$\text{WTS}[W, j] \leftarrow \max(-127, \text{WTS}[W, j] - 4) \quad \forall j \in \text{ActivePixels}$$
   $$\text{BIAS}[W] \leftarrow \text{BIAS}[W] - 8$$
   Iterate up to 12 epochs until $T$ wins.
4. **Prototype Learning (`AddProto`)**:
   Store the glyph's 5x7 grid in prototype memory.
5. **Anti-Catastrophic Forgetting Consolidation (`Consolidate`)**:
   Perform 2 sweeps over stored bank samples to ensure previously learned patterns remain correctly classified.

---

## 10. Legacy `LEARN.DAT` Binary Format

For importing legacy DOSBox training data:
- **Header (18 bytes)**:
  - `0x00..0x03`: Magic string `'HWR3'` (4 bytes)
  - `0x04..0x05`: `int16` `YOFF`
  - `0x06..0x07`: `int16` `CASE_T`
  - `0x08..0x09`: `int16` `ABS_T`
  - `0x0A..0x0B`: `uint16` `NBANK` (number of bank entries $\le 400$)
  - `0x0C..0x0D`: `uint16` `NLPROT` (number of learned prototypes $\le 64$)
  - `0x0E..0x0F`: `uint16` `BANKNXT`
  - `0x10..0x11`: `uint16` `LPNXT`
- **Bank Entries**: `NBANK * 18` bytes (8 bytes 8x8 grid, 7 bytes 5x7 grid, 1 byte ASCII, 1 byte flag, 1 byte aspect).
- **Prototypes**: `NLPROT * 8` bytes (7 bytes 5x7 grid, 1 byte ASCII).
- **Weights**: 3,968 bytes ($62 \times 64$ `int8`).
- **Biases**: 124 bytes ($62 \times \text{int16}$).
- **Checksum**: `uint16` arithmetic sum of all preceding payload bytes.
