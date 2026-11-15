/*
 * HWR-LEARN Native Cross-Platform Driver
 * Windows (DLL), Linux (SO), and Android (NDK)
 */

#ifndef HWR_DRIVER_H
#define HWR_DRIVER_H

#include <stdint.h>

#ifdef _WIN32
    #if defined(HWR_STATIC)
        #define HWR_API
    #elif defined(HWR_BUILD_DLL)
        #define HWR_API __declspec(dllexport)
    #else
        #define HWR_API __declspec(dllimport)
    #endif
#else
    #define HWR_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define HWR_MAX_STROKES 200
#define HWR_MAX_POINTS_PER_STROKE 1000
#define HWR_MAX_GLYPHS 120
#define HWR_MAX_TEXT_LEN 2048
#define HWR_MAX_BANK_SAMPLES 1000

typedef struct {
    float x;
    float y;
} HWRPoint;

typedef struct {
    char character;
    float confidence;
} HWRCandidate;

typedef struct {
    int32_t x1;
    int32_t y1;
    int32_t x2;
    int32_t y2;
    char final_class;
    int32_t is_sure;
    float confidence;
    HWRCandidate candidates[3];
} HWRGlyphResult;

typedef struct {
    char text[HWR_MAX_TEXT_LEN];
    int32_t num_glyphs;
    HWRGlyphResult glyphs[HWR_MAX_GLYPHS];
} HWRResult;

/* Initialization and Lifecycle */
HWR_API void hwr_init(void);
HWR_API void hwr_reset(void);
HWR_API void hwr_set_mode(int32_t mode); // 0=AUTO, 1=ABC, 2=abc, 3=123

/* Stroke Input Capture */
HWR_API void hwr_clear_strokes(void);
HWR_API int32_t hwr_add_stroke(const HWRPoint* pts, int32_t count);
HWR_API int32_t hwr_get_stroke_count(void);

/* Recognition & Teaching */
HWR_API int32_t hwr_predict(HWRResult* out_result);
HWR_API int32_t hwr_teach_glyph(int32_t glyph_idx, char correct_char);
HWR_API int32_t hwr_load_bank_sample(const uint8_t grid8[8], const uint8_t grid57[7], char label, uint8_t aspect, uint8_t flags);
HWR_API const uint8_t* hwr_get_last_grid8(void);
HWR_API const uint8_t* hwr_get_last_grid57(void);
HWR_API int32_t hwr_get_last_aspect(void);
HWR_API int32_t hwr_get_last_flags(void);
HWR_API int32_t hwr_get_sample_count(void);

#ifdef __cplusplus
}
#endif

#endif /* HWR_DRIVER_H */
