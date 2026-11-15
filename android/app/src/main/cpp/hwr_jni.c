/*
 * JNI Bridge for HWR-LEARN Android Native Driver
 * Connects Android Java/Kotlin UI to the high-performance C99 HWR core.
 */

#include <jni.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include "hwr_driver.h"

JNIEXPORT void JNICALL
Java_com_hwrlearn_app_HwrNative_init(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
    hwr_init();
}

JNIEXPORT void JNICALL
Java_com_hwrlearn_app_HwrNative_reset(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
    hwr_reset();
}

JNIEXPORT void JNICALL
Java_com_hwrlearn_app_HwrNative_setMode(JNIEnv *env, jclass clazz, jint mode) {
    (void)env; (void)clazz;
    hwr_set_mode(mode);
}

JNIEXPORT void JNICALL
Java_com_hwrlearn_app_HwrNative_clearStrokes(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
    hwr_clear_strokes();
}

JNIEXPORT jint JNICALL
Java_com_hwrlearn_app_HwrNative_addStroke(JNIEnv *env, jclass clazz, jfloatArray xs, jfloatArray ys, jint count) {
    (void)clazz;
    if (count <= 0 || count > HWR_MAX_POINTS_PER_STROKE) return 0;

    jfloat *x_ptr = (*env)->GetFloatArrayElements(env, xs, NULL);
    jfloat *y_ptr = (*env)->GetFloatArrayElements(env, ys, NULL);

    HWRPoint pts[HWR_MAX_POINTS_PER_STROKE];
    for (int i = 0; i < count; i++) {
        pts[i].x = x_ptr[i];
        pts[i].y = y_ptr[i];
    }

    (*env)->ReleaseFloatArrayElements(env, xs, x_ptr, JNI_ABORT);
    (*env)->ReleaseFloatArrayElements(env, ys, y_ptr, JNI_ABORT);

    return hwr_add_stroke(pts, count);
}

JNIEXPORT jstring JNICALL
Java_com_hwrlearn_app_HwrNative_predict(JNIEnv *env, jclass clazz) {
    (void)clazz;
    HWRResult res;
    int num = hwr_predict(&res);

    char json_buf[65536];
    int pos = 0;

    pos += snprintf(json_buf + pos, sizeof(json_buf) - pos, "{\"num_glyphs\":%d,\"text\":\"", num);

    // Escape text string
    for (const char *cp = res.text; *cp && pos < (int)sizeof(json_buf) - 64; cp++) {
        if (*cp == '"') {
            json_buf[pos++] = '\\'; json_buf[pos++] = '"';
        } else if (*cp == '\\') {
            json_buf[pos++] = '\\'; json_buf[pos++] = '\\';
        } else if (*cp == '\n') {
            json_buf[pos++] = '\\'; json_buf[pos++] = 'n';
        } else {
            json_buf[pos++] = *cp;
        }
    }

    pos += snprintf(json_buf + pos, sizeof(json_buf) - pos, "\",\"glyphs\":[");

    for (int i = 0; i < num && pos < (int)sizeof(json_buf) - 256; i++) {
        HWRGlyphResult *g = &res.glyphs[i];
        if (i > 0) json_buf[pos++] = ',';

        char c0 = g->candidates[0].character == '"' ? '\'' : g->candidates[0].character;
        char c1 = g->candidates[1].character == '"' ? '\'' : g->candidates[1].character;
        char c2 = g->candidates[2].character == '"' ? '\'' : g->candidates[2].character;
        char fc = g->final_class == '"' ? '\'' : g->final_class;

        pos += snprintf(json_buf + pos, sizeof(json_buf) - pos,
                        "{\"final_class\":\"%c\",\"is_sure\":%d,\"confidence\":%.1f,"
                        "\"bbox\":[%d,%d,%d,%d],"
                        "\"candidates\":[[\"%c\",%.1f],[\"%c\",%.1f],[\"%c\",%.1f]]}",
                        fc, g->is_sure, g->confidence,
                        g->x1, g->y1, g->x2, g->y2,
                        c0, g->candidates[0].confidence,
                        c1, g->candidates[1].confidence,
                        c2, g->candidates[2].confidence);
    }

    pos += snprintf(json_buf + pos, sizeof(json_buf) - pos, "]}");

    return (*env)->NewStringUTF(env, json_buf);
}

JNIEXPORT jint JNICALL
Java_com_hwrlearn_app_HwrNative_teachGlyph(JNIEnv *env, jclass clazz, jint glyphIdx, jchar correctChar) {
    (void)env; (void)clazz;
    return hwr_teach_glyph(glyphIdx, (char)correctChar);
}

JNIEXPORT jint JNICALL
Java_com_hwrlearn_app_HwrNative_loadBankSample(JNIEnv *env, jclass clazz, jbyteArray grid8, jbyteArray grid57, jchar label, jint aspect, jint flags) {
    (void)clazz;
    jbyte *g8 = (*env)->GetByteArrayElements(env, grid8, NULL);
    jbyte *g57 = (*env)->GetByteArrayElements(env, grid57, NULL);

    int res = hwr_load_bank_sample((const uint8_t*)g8, (const uint8_t*)g57, (char)label, (uint8_t)aspect, (uint8_t)flags);

    (*env)->ReleaseByteArrayElements(env, grid8, g8, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, grid57, g57, JNI_ABORT);

    return res;
}
