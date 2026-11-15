#ifndef HWR_STATIC
#ifndef HWR_BUILD_DLL
#define HWR_BUILD_DLL
#endif
#endif
#include "hwr_driver.h"
#include "hwr_data.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define MARGIN_X 2
#define MARGIN_Y 16
#define CLS_NOISE 1

typedef struct {
    HWRPoint points[HWR_MAX_POINTS_PER_STROKE];
    int count;
    int min_x, max_x, min_y, max_y;
} InternalStroke;

typedef struct {
    uint8_t grid8[8];
    uint8_t grid57[7];
    char label;
    uint8_t aspect;
    uint8_t flags;
    int is_tiny;
    uint8_t tiny_key;
} BankEntry;

typedef struct {
    uint8_t grid57[7];
    char label;
} LearnedProto;

/* Internal Driver State */
static InternalStroke g_strokes[HWR_MAX_STROKES];
static int g_num_strokes = 0;

static int8_t g_weights[62 * 64];
static int16_t g_biases[62];

static BankEntry g_bank[HWR_MAX_BANK_SAMPLES];
static int g_num_bank = 0;

static LearnedProto g_learned_protos[64];
static int g_num_learned_protos = 0;

static int g_case_t = 68;
static int g_abs_t = 42;
static int g_mode = 0; // 0=AUTO, 1=ABC, 2=abc, 3=123

static uint8_t g_pop_lut[256];
static int g_initialized = 0;

/* Helper: Popcount */
static inline int popcnt8(uint8_t b) {
    return g_pop_lut[b];
}

/* Helper: 3x3 Dilation */
static void dilate8(const uint8_t in_grid[8], uint8_t out_grid[8]) {
    uint8_t horiz[8];
    for (int r = 0; r < 8; r++) {
        uint8_t v = in_grid[r];
        horiz[r] = (v | (v << 1) | (v >> 1)) & 0xFF;
    }
    for (int r = 0; r < 8; r++) {
        uint8_t v = horiz[r];
        uint8_t up = (r > 0) ? horiz[r - 1] : 0;
        uint8_t dn = (r < 7) ? horiz[r + 1] : 0;
        out_grid[r] = (v | up | dn) & 0xFF;
    }
}

/* Helper: Shift-tolerant 8x8 distance */
static int tol_dist8(const uint8_t grid_a[8], const uint8_t grid_b[8]) {
    uint8_t da[8], db[8];
    dilate8(grid_a, da);
    dilate8(grid_b, db);
    int dist = 0;
    for (int r = 0; r < 8; r++) {
        dist += popcnt8((uint8_t)(grid_a[r] & (~db[r])));
        dist += popcnt8((uint8_t)(grid_b[r] & (~da[r])));
    }
    return dist;
}

/* Helper: 62-class mapping */
static int char_to_cls_idx(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    if (c >= 'a' && c <= 'z') return c - 'a' + 36;
    return -1;
}

static char cls_idx_to_char(int idx) {
    if (idx >= 0 && idx <= 9) return '0' + idx;
    if (idx >= 10 && idx <= 35) return 'A' + (idx - 10);
    if (idx >= 36 && idx <= 61) return 'a' + (idx - 36);
    return '?';
}

static int mode_ok(int mode, char c) {
    if (mode == 0) return 1;
    if (mode == 1) return (c >= 'A' && c <= 'Z');
    if (mode == 2) return (c >= 'a' && c <= 'z');
    if (mode == 3) return (c >= '0' && c <= '9');
    return 1;
}

/* Lifecycle */
HWR_API void hwr_init(void) {
    for (int i = 0; i < 256; i++) {
        int cnt = 0;
        for (int b = 0; b < 8; b++) {
            if (i & (1 << b)) cnt++;
        }
        g_pop_lut[i] = (uint8_t)cnt;
    }
    memcpy(g_weights, HWR_ORIG_WEIGHTS, sizeof(g_weights));
    memcpy(g_biases, HWR_ORIG_BIASES, sizeof(g_biases));
    g_num_strokes = 0;
    g_num_bank = 0;
    g_num_learned_protos = 0;
    g_case_t = 68;
    g_abs_t = 42;
    g_mode = 0;
    g_initialized = 1;
}

HWR_API void hwr_reset(void) {
    hwr_init();
}

HWR_API void hwr_set_mode(int32_t mode) {
    g_mode = mode;
}

HWR_API void hwr_clear_strokes(void) {
    g_num_strokes = 0;
}

static void add_single_stroke(const HWRPoint* pts, int n) {
    if (g_num_strokes >= HWR_MAX_STROKES || n <= 0) return;
    InternalStroke* s = &g_strokes[g_num_strokes];
    s->count = n;
    int min_x = (int)pts[0].x, max_x = min_x;
    int min_y = (int)pts[0].y, max_y = min_y;

    for (int i = 0; i < n; i++) {
        s->points[i] = pts[i];
        int px = (int)pts[i].x;
        int py = (int)pts[i].y;
        if (px < min_x) min_x = px;
        if (px > max_x) max_x = px;
        if (py < min_y) min_y = py;
        if (py > max_y) max_y = py;
    }
    s->min_x = min_x; s->max_x = max_x;
    s->min_y = min_y; s->max_y = max_y;
    g_num_strokes++;
}

HWR_API int32_t hwr_add_stroke(const HWRPoint* pts, int32_t count) {
    if (!g_initialized) hwr_init();
    if (g_num_strokes >= HWR_MAX_STROKES || count <= 0) return 0;

    int n = count;
    if (n > HWR_MAX_POINTS_PER_STROKE) n = HWR_MAX_POINTS_PER_STROKE;

    // Fix 5: Split touching cursive letters ("ar", "ou")
    int min_x = (int)pts[0].x, max_x = min_x;
    int min_y = (int)pts[0].y, max_y = min_y;
    for (int i = 0; i < n; i++) {
        if ((int)pts[i].x < min_x) min_x = (int)pts[i].x;
        if ((int)pts[i].x > max_x) max_x = (int)pts[i].x;
        if ((int)pts[i].y < min_y) min_y = (int)pts[i].y;
        if ((int)pts[i].y > max_y) max_y = (int)pts[i].y;
    }
    int w = max_x - min_x + 1;
    int h = max_y - min_y + 1;

    if (w >= 28 && w >= (int)(h * 1.60f) && n >= 15) {
        int density[256];
        int bins = w;
        if (bins > 255) bins = 255;
        memset(density, 0, sizeof(density));
        for (int i = 0; i < n; i++) {
            int b = (int)(((pts[i].x - min_x) * (bins - 1)) / (w > 0 ? w : 1));
            if (b >= 0 && b < bins) density[b]++;
        }
        int min_b = bins * 30 / 100;
        int max_b = bins * 70 / 100;
        int valley_b = -1;
        int min_d = 999999;
        for (int b = min_b; b <= max_b; b++) {
            if (density[b] < min_d) {
                min_d = density[b];
                valley_b = b;
            }
        }
        if (valley_b > 0 && min_d <= 3) {
            float split_x = min_x + (float)valley_b * (float)w / (float)bins;
            int split_idx = -1;
            float min_dist = 999999.0f;
            for (int i = 5; i < n - 5; i++) {
                float d = fabsf(pts[i].x - split_x);
                if (d < min_dist) {
                    min_dist = d;
                    split_idx = i;
                }
            }
            if (split_idx >= 5 && split_idx < n - 5) {
                int gap = (split_idx + 2 < n - 2) ? 2 : 1;
                add_single_stroke(pts, split_idx);
                add_single_stroke(pts + split_idx + gap, n - split_idx - gap);
                return g_num_strokes;
            }
        }
    }

    add_single_stroke(pts, n);
    return g_num_strokes;
}

HWR_API int32_t hwr_get_stroke_count(void) {
    return g_num_strokes;
}

HWR_API int32_t hwr_get_sample_count(void) {
    return g_num_bank;
}

/* Auto-centering for 8x8 grid */
static void auto_center_grid8(uint8_t grid[8]) {
    uint8_t row_or = 0;
    for (int r = 0; r < 8; r++) row_or |= grid[r];
    if (row_or == 0) return;

    if (!(row_or & 0x80) && (row_or & 0x01)) {
        for (int r = 0; r < 8; r++) grid[r] = (uint8_t)((grid[r] << 1) & 0xFF);
    } else if ((row_or & 0x80) && !(row_or & 0x01)) {
        for (int r = 0; r < 8; r++) grid[r] = (uint8_t)(grid[r] >> 1);
    }

    if (grid[0] == 0 && grid[7] != 0) {
        for (int r = 0; r < 7; r++) grid[r] = grid[r + 1];
        grid[7] = 0;
    } else if (grid[7] == 0 && grid[0] != 0) {
        for (int r = 7; r > 0; r--) grid[r] = grid[r - 1];
        grid[0] = 0;
    }
}

/* Rasterize strokes into 8x8 and 5x7 binary grids */
static void rasterize_glyph(
    const int* stroke_indices, int num_s,
    int gx1, int gy1, int gx2, int gy2,
    uint8_t out_grid8[8], uint8_t out_g57[7]
) {
    int w = gx2 - gx1 + 2;
    int h = gy2 - gy1 + 2;
    if (w <= 0) w = 1;
    if (h <= 0) h = 1;

    uint8_t* pix = (uint8_t*)calloc(w * h, sizeof(uint8_t));

    for (int si = 0; si < num_s; si++) {
        const InternalStroke* s = &g_strokes[stroke_indices[si]];
        for (int i = 0; i < s->count; i++) {
            int x = (int)s->points[i].x - gx1;
            int y = (int)s->points[i].y - gy1;
            if (i == 0) {
                for (int dy = 0; dy <= 1; dy++) {
                    for (int dx = 0; dx <= 1; dx++) {
                        int ny = y + dy, nx = x + dx;
                        if (ny >= 0 && ny < h && nx >= 0 && nx < w) pix[ny * w + nx] = 1;
                    }
                }
            } else {
                int px = (int)s->points[i - 1].x - gx1;
                int py = (int)s->points[i - 1].y - gy1;
                int steps = abs(x - px) > abs(y - py) ? abs(x - px) : abs(y - py);
                if (steps == 0) steps = 1;
                for (int step = 0; step <= steps; step++) {
                    int cx = px + (x - px) * step / steps;
                    int cy = py + (y - py) * step / steps;
                    for (int dy = 0; dy <= 1; dy++) {
                        for (int dx = 0; dx <= 1; dx++) {
                            int ny = cy + dy, nx = cx + dx;
                            if (ny >= 0 && ny < h && nx >= 0 && nx < w) pix[ny * w + nx] = 1;
                        }
                    }
                }
            }
        }
    }

    /* 8x8 Grid */
    int dyn8 = (w * h) / 350;
    if (dyn8 < 2) dyn8 = 2;
    if (dyn8 > 14) dyn8 = 14;

    for (int r = 0; r < 8; r++) {
        out_grid8[r] = 0;
        int y1 = (r * h) / 8;
        int y2 = ((r + 1) * h) / 8 - 1;
        if (y2 < y1) y2 = y1;
        for (int c = 0; c < 8; c++) {
            int x1 = (c * w) / 8;
            int x2 = ((c + 1) * w) / 8 - 1;
            if (x2 < x1) x2 = x1;
            int cnt = 0;
            for (int y = y1; y <= y2 && y < h; y++) {
                for (int x = x1; x <= x2 && x < w; x++) {
                    if (pix[y * w + x]) cnt++;
                }
            }
            if (cnt >= dyn8) out_grid8[r] |= (1 << (7 - c));
        }
    }
    auto_center_grid8(out_grid8);

    /* 5x7 Grid */
    int dyn57 = (w * h) / 210;
    if (dyn57 < 1) dyn57 = 1;
    if (dyn57 > 5) dyn57 = 5;

    for (int r = 0; r < 7; r++) {
        out_g57[r] = 0;
        int y1 = (r * h) / 7;
        int y2 = ((r + 1) * h) / 7 - 1;
        if (y2 < y1) y2 = y1;
        for (int c = 0; c < 5; c++) {
            int x1 = (c * w) / 5;
            int x2 = ((c + 1) * w) / 5 - 1;
            if (x2 < x1) x2 = x1;
            int cnt = 0;
            for (int y = y1; y <= y2 && y < h; y++) {
                for (int x = x1; x <= x2 && x < w; x++) {
                    if (pix[y * w + x]) cnt++;
                }
            }
            if (cnt >= dyn57) out_g57[r] |= (1 << (4 - c));
        }
    }

    free(pix);
}

/* Perceptron scoring */
static void score_perceptron(const uint8_t grid8[8], int32_t psc[62], int32_t* psmax) {
    uint8_t active[64];
    int nact = 0;
    for (int r = 0; r < 8; r++) {
        for (int c = 0; c < 8; c++) {
            if (grid8[r] & (1 << (7 - c))) {
                active[nact++] = (uint8_t)(r * 8 + c);
            }
        }
    }

    int32_t max_val = -32768;
    for (int cls = 0; cls < 62; cls++) {
        int32_t score = g_biases[cls];
        const int8_t* w_row = &g_weights[cls * 64];
        for (int i = 0; i < nact; i++) {
            score += w_row[active[i]];
        }
        psc[cls] = score;
        if (score > max_val) max_val = score;
    }
    *psmax = max_val;
}

/* Online Perceptron Training */
static void train_perceptron_sample(const uint8_t grid8[8], char target_char, int max_epochs) {
    int target_idx = char_to_cls_idx(target_char);
    if (target_idx < 0) return;

    uint8_t active[64];
    int nact = 0;
    for (int r = 0; r < 8; r++) {
        for (int c = 0; c < 8; c++) {
            if (grid8[r] & (1 << (7 - c))) {
                active[nact++] = (uint8_t)(r * 8 + c);
            }
        }
    }

    uint8_t target_group = HWR_GRP[(uint8_t)target_char];

    for (int ep = 0; ep < max_epochs; ep++) {
        int32_t psc[62], psmax;
        score_perceptron(grid8, psc, &psmax);

        int best_idx = 0;
        int32_t best_score = psc[0];
        for (int i = 1; i < 62; i++) {
            if (psc[i] > best_score) {
                best_score = psc[i];
                best_idx = i;
            }
        }

        if (best_idx == target_idx) break;

        char wrong_char = cls_idx_to_char(best_idx);
        uint8_t wrong_group = HWR_GRP[(uint8_t)wrong_char];
        if (target_group != 0xFF && target_group == wrong_group) break;

        /* UpdW update: target +4, wrong -4, bias +-8 */
        for (int i = 0; i < nact; i++) {
            int p = active[i];
            int w_t = (int)g_weights[target_idx * 64 + p] + 4;
            if (w_t > 127) w_t = 127;
            g_weights[target_idx * 64 + p] = (int8_t)w_t;

            int w_w = (int)g_weights[best_idx * 64 + p] - 4;
            if (w_w < -127) w_w = -127;
            g_weights[best_idx * 64 + p] = (int8_t)w_w;
        }
        g_biases[target_idx] += 8;
        g_biases[best_idx] -= 8;
    }
}

static int g_last_num_glyphs = 0;
static int g_last_glyph_stroke_map[HWR_MAX_GLYPHS][HWR_MAX_STROKES];
static int g_last_glyph_stroke_cnt[HWR_MAX_GLYPHS];
static int g_last_gx1[HWR_MAX_GLYPHS], g_last_gy1[HWR_MAX_GLYPHS];
static int g_last_gx2[HWR_MAX_GLYPHS], g_last_gy2[HWR_MAX_GLYPHS];

/* Main Prediction Pipeline */
HWR_API int32_t hwr_predict(HWRResult* out_result) {
    if (!g_initialized) hwr_init();
    if (g_num_strokes == 0 || out_result == NULL) return 0;

    memset(out_result, 0, sizeof(HWRResult));

    /* 1. Stroke Merging: Group overlapping strokes into glyphs */
    int parent[HWR_MAX_STROKES];
    for (int i = 0; i < g_num_strokes; i++) parent[i] = i;

    for (int i = 0; i < g_num_strokes; i++) {
        for (int j = i + 1; j < g_num_strokes; j++) {
            if (g_strokes[i].max_x + MARGIN_X >= g_strokes[j].min_x &&
                g_strokes[j].max_x + MARGIN_X >= g_strokes[i].min_x &&
                g_strokes[i].max_y + MARGIN_Y >= g_strokes[j].min_y &&
                g_strokes[j].max_y + MARGIN_Y >= g_strokes[i].min_y) {
                int r_i = i; while (parent[r_i] != r_i) r_i = parent[r_i];
                int r_j = j; while (parent[r_j] != r_j) r_j = parent[r_j];
                parent[r_j] = r_i;
            }
        }
    }

    int glyph_stroke_map[HWR_MAX_GLYPHS][HWR_MAX_STROKES];
    int glyph_stroke_cnt[HWR_MAX_GLYPHS] = {0};
    int num_glyphs = 0;

    for (int i = 0; i < g_num_strokes; i++) {
        int r = i; while (parent[r] != r) r = parent[r];
        int found = -1;
        for (int g = 0; g < num_glyphs; g++) {
            if (parent[glyph_stroke_map[g][0]] == r) {
                found = g;
                break;
            }
        }
        if (found < 0 && num_glyphs < HWR_MAX_GLYPHS) {
            found = num_glyphs++;
        }
        if (found >= 0) {
            glyph_stroke_map[found][glyph_stroke_cnt[found]++] = i;
        }
    }

    /* Compute glyph bounding boxes */
    int gx1[HWR_MAX_GLYPHS], gy1[HWR_MAX_GLYPHS], gx2[HWR_MAX_GLYPHS], gy2[HWR_MAX_GLYPHS];
    for (int g = 0; g < num_glyphs; g++) {
        int min_x = 999999, max_x = -999999, min_y = 999999, max_y = -999999;
        for (int s = 0; s < glyph_stroke_cnt[g]; s++) {
            const InternalStroke* st = &g_strokes[glyph_stroke_map[g][s]];
            if (st->min_x < min_x) min_x = st->min_x;
            if (st->max_x > max_x) max_x = st->max_x;
            if (st->min_y < min_y) min_y = st->min_y;
            if (st->max_y > max_y) max_y = st->max_y;
        }
        gx1[g] = min_x; gx2[g] = max_x + 1;
        gy1[g] = min_y; gy2[g] = max_y + 1;
    }

    /* Sort reading order: sort by X1 */
    for (int i = 0; i < num_glyphs - 1; i++) {
        for (int j = i + 1; j < num_glyphs; j++) {
            if (gx1[j] < gx1[i]) {
                int tx1 = gx1[i]; gx1[i] = gx1[j]; gx1[j] = tx1;
                int ty1 = gy1[i]; gy1[i] = gy1[j]; gy1[j] = ty1;
                int tx2 = gx2[i]; gx2[i] = gx2[j]; gx2[j] = tx2;
                int ty2 = gy2[i]; gy2[i] = gy2[j]; gy2[j] = ty2;

                int sc = glyph_stroke_cnt[i]; glyph_stroke_cnt[i] = glyph_stroke_cnt[j]; glyph_stroke_cnt[j] = sc;
                for (int k = 0; k < HWR_MAX_STROKES; k++) {
                    int stmp = glyph_stroke_map[i][k];
                    glyph_stroke_map[i][k] = glyph_stroke_map[j][k];
                    glyph_stroke_map[j][k] = stmp;
                }
            }
        }
    }

    /* Fix 1: Robust reference height LR = max(1.6*median, 1.25*P75) */
    int heights[HWR_MAX_GLYPHS];
    int n_real = 0;
    for (int g = 0; g < num_glyphs; g++) {
        int h = gy2[g] - gy1[g];
        if (h > 12) heights[n_real++] = h;
    }
    // Bubble sort heights
    for (int i = 0; i < n_real - 1; i++) {
        for (int j = i + 1; j < n_real; j++) {
            if (heights[j] < heights[i]) {
                int th = heights[i]; heights[i] = heights[j]; heights[j] = th;
            }
        }
    }
    int lr = 40;
    if (n_real >= 3) {
        int med = heights[n_real / 2];
        int p75 = heights[(n_real * 3) / 4];
        int cap = (int)(med * 1.6);
        int cap75 = (int)(p75 * 1.25);
        if (cap75 > cap) cap = cap75;
        lr = med;
        for (int i = 0; i < n_real; i++) {
            if (heights[i] <= cap && heights[i] > lr) lr = heights[i];
        }
    } else if (n_real > 0) {
        lr = heights[n_real - 1];
    }
    int lgap = (int)(lr * 0.45);
    if (lgap < 16) lgap = 16;
    if (lgap > 60) lgap = 60;

    out_result->num_glyphs = num_glyphs;
    int out_text_pos = 0;

    /* Classify each glyph */
    for (int g = 0; g < num_glyphs; g++) {
        HWRGlyphResult* gr = &out_result->glyphs[g];
        gr->x1 = gx1[g]; gr->x2 = gx2[g];
        gr->y1 = gy1[g]; gr->y2 = gy2[g];

        int w = gx2[g] - gx1[g];
        int h = gy2[g] - gy1[g];

        uint8_t grid8[8], g57[7];
        rasterize_glyph(glyph_stroke_map[g], glyph_stroke_cnt[g], gx1[g], gy1[g], gx2[g], gy2[g], grid8, g57);

        /* Tiny detection */
        if ((w <= 12 && h <= 12) || (h * 100 < 32 * lr && w * 100 < 45 * lr)) {
            gr->final_class = '.';
            gr->confidence = 85.0f;
            gr->is_sure = 1;
            gr->candidates[0].character = '.'; gr->candidates[0].confidence = 85.0f;
            gr->candidates[1].character = ','; gr->candidates[1].confidence = 60.0f;
            gr->candidates[2].character = '\''; gr->candidates[2].confidence = 30.0f;
        } else {
            /* 1. Seeds distance DK[33..126] */
            int dk[128];
            for (int c = 0; c < 128; c++) dk[c] = 99;

            for (int s = 0; s < HWR_NUM_SEEDS; s++) {
                const uint8_t* seed = &HWR_SEEDS[s * 9];
                uint8_t sc = seed[8];
                int d = 0;
                for (int r = 0; r < 8; r++) {
                    d += popcnt8((uint8_t)(seed[r] ^ grid8[r]));
                }
                if (sc < 128 && d < dk[sc]) dk[sc] = d;
            }

            /* 2. Learned Bank Matching (Fix 2 & 3) */
            int bkd = 255;
            char bkc = 0;
            for (int b = 0; b < g_num_bank; b++) {
                if (g_bank[b].is_tiny) continue;
                int d8 = tol_dist8(grid8, g_bank[b].grid8);
                int d57 = 0;
                for (int r = 0; r < 7; r++) d57 += popcnt8((uint8_t)(g57[r] ^ g_bank[b].grid57[r]));
                int raw_d = d8 + d57;
                if (raw_d < bkd) {
                    bkd = raw_d;
                    bkc = g_bank[b].label;
                }
                /* Normalise (x5/8) - 3 */
                int eff = ((raw_d * 5) / 8) - 3;
                if (eff < 0) eff = 0;
                uint8_t bl = (uint8_t)g_bank[b].label;
                if (bl < 128 && eff < dk[bl]) dk[bl] = eff;
            }

            /* 3. Base Prototypes DPR[33..126] */
            int dpr[128];
            for (int c = 0; c < 128; c++) dpr[c] = 255;
            for (int p = 0; p < HWR_NUM_BASE_PROTOS; p++) {
                const uint8_t* proto = &HWR_BASE_PROTOS[p * 8];
                uint8_t pc = proto[7];
                int d = 0;
                for (int r = 0; r < 7; r++) d += popcnt8((uint8_t)(proto[r] ^ g57[r]));
                if (pc < 128 && d < dpr[pc]) dpr[pc] = d;
            }
            for (int p = 0; p < g_num_learned_protos; p++) {
                uint8_t pc = (uint8_t)g_learned_protos[p].label;
                int d = 0;
                for (int r = 0; r < 7; r++) d += popcnt8((uint8_t)(g_learned_protos[p].grid57[r] ^ g57[r]));
                if (pc < 128 && d < dpr[pc]) dpr[pc] = d;
            }

            /* 4. Perceptron Scoring */
            int32_t psc[62], psmax;
            score_perceptron(grid8, psc, &psmax);

            /* 5. Fusion: F = -16*DK - 4*DPR + Delta_perc */
            int fsc[128];
            int best_score = -32768;
            char best_c = '?';

            for (int c = 33; c < 127; c++) {
                if (dk[c] >= 99 || !mode_ok(g_mode, (char)c)) {
                    fsc[c] = -32768;
                    continue;
                }
                int score = -16 * dk[c];
                int proto_d = (dpr[c] != 255) ? dpr[c] : 8;
                score -= 4 * proto_d;

                int cls_idx = char_to_cls_idx((char)c);
                if (cls_idx >= 0) {
                    score += (psc[cls_idx] - psmax) >> 3;
                } else {
                    score -= 12;
                }
                fsc[c] = score;
                if (score > best_score) {
                    best_score = score;
                    best_c = (char)c;
                }
            }

            /* Outright bank override at <= 14 */
            if (bkd <= 14 && bkc != 0 && mode_ok(g_mode, bkc)) {
                best_c = bkc;
            }

            gr->final_class = best_c;
            gr->confidence = (bkd <= 14) ? 98.0f : 85.0f;
            gr->is_sure = (bkd <= 14 || best_score > -200);

            /* Top 3 selection */
            gr->candidates[0].character = best_c;
            gr->candidates[0].confidence = gr->confidence;

            int c2_score = -32768; char c2_char = '?';
            int c3_score = -32768; char c3_char = '?';

            for (int c = 33; c < 127; c++) {
                if ((char)c == best_c || fsc[c] <= -30000) continue;
                if (fsc[c] > c2_score) {
                    c3_score = c2_score; c3_char = c2_char;
                    c2_score = fsc[c]; c2_char = (char)c;
                } else if (fsc[c] > c3_score) {
                    c3_score = fsc[c]; c3_char = (char)c;
                }
            }

            gr->candidates[1].character = c2_char;
            gr->candidates[1].confidence = (gr->confidence > 20.0f) ? gr->confidence - 15.0f : 30.0f;
            gr->candidates[2].character = c3_char;
            gr->candidates[2].confidence = (gr->candidates[1].confidence > 20.0f) ? gr->candidates[1].confidence - 15.0f : 15.0f;
        }

        /* Spacing in output text */
        if (g > 0 && (gx1[g] - gx2[g - 1]) >= lgap && out_text_pos < HWR_MAX_TEXT_LEN - 2) {
            out_result->text[out_text_pos++] = ' ';
        }
        if (out_text_pos < HWR_MAX_TEXT_LEN - 1) {
            out_result->text[out_text_pos++] = gr->final_class;
        }
    }
    out_result->text[out_text_pos] = '\0';
    g_last_num_glyphs = num_glyphs;
    for (int g = 0; g < num_glyphs; g++) {
        g_last_gx1[g] = gx1[g]; g_last_gx2[g] = gx2[g];
        g_last_gy1[g] = gy1[g]; g_last_gy2[g] = gy2[g];
        g_last_glyph_stroke_cnt[g] = glyph_stroke_cnt[g];
        for (int s = 0; s < glyph_stroke_cnt[g]; s++) {
            g_last_glyph_stroke_map[g][s] = glyph_stroke_map[g][s];
        }
    }
    return num_glyphs;
}

static uint8_t g_last_grid8[8];
static uint8_t g_last_grid57[7];
static int32_t g_last_aspect = 0;
static int32_t g_last_flags = 0;

HWR_API const uint8_t* hwr_get_last_grid8(void) { return g_last_grid8; }
HWR_API const uint8_t* hwr_get_last_grid57(void) { return g_last_grid57; }
HWR_API int32_t hwr_get_last_aspect(void) { return g_last_aspect; }
HWR_API int32_t hwr_get_last_flags(void) { return g_last_flags; }

/* Online Teaching in C */
HWR_API int32_t hwr_teach_glyph(int32_t glyph_idx, char correct_char) {
    if (glyph_idx < 0 || glyph_idx >= g_last_num_glyphs || g_num_bank >= HWR_MAX_BANK_SAMPLES) return 0;

    int gx1 = g_last_gx1[glyph_idx];
    int gx2 = g_last_gx2[glyph_idx];
    int gy1 = g_last_gy1[glyph_idx];
    int gy2 = g_last_gy2[glyph_idx];

    uint8_t grid8[8], g57[7];
    rasterize_glyph(g_last_glyph_stroke_map[glyph_idx], g_last_glyph_stroke_cnt[glyph_idx], gx1, gy1, gx2, gy2, grid8, g57);

    BankEntry* b = &g_bank[g_num_bank++];
    memcpy(b->grid8, grid8, 8);
    memcpy(b->grid57, g57, 7);
    b->label = correct_char;
    b->flags = 1;
    b->aspect = (uint8_t)(((gx2 - gx1) * 16) / ((gy2 - gy1 > 0) ? (gy2 - gy1) : 1));
    b->is_tiny = 0;

    memcpy(g_last_grid8, grid8, 8);
    memcpy(g_last_grid57, g57, 7);
    g_last_aspect = b->aspect;
    g_last_flags = b->flags;

    if (g_num_learned_protos < 64) {
        memcpy(g_learned_protos[g_num_learned_protos].grid57, g57, 7);
        g_learned_protos[g_num_learned_protos++].label = correct_char;
    }

    train_perceptron_sample(grid8, correct_char, 12);
    return g_num_bank;
}

HWR_API int32_t hwr_load_bank_sample(const uint8_t grid8[8], const uint8_t grid57[7], char label, uint8_t aspect, uint8_t flags) {
    if (g_num_bank >= HWR_MAX_BANK_SAMPLES) return 0;
    BankEntry* b = &g_bank[g_num_bank++];
    memcpy(b->grid8, grid8, 8);
    memcpy(b->grid57, grid57, 7);
    b->label = label;
    b->aspect = aspect;
    b->flags = flags;
    b->is_tiny = (flags & 4) ? 1 : 0;
    b->tiny_key = 0;
    if (g_num_learned_protos < 64) {
        memcpy(g_learned_protos[g_num_learned_protos].grid57, grid57, 7);
        g_learned_protos[g_num_learned_protos++].label = label;
    }
    train_perceptron_sample(grid8, label, 3);
    return g_num_bank;
}
