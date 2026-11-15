/*
 * HWR-LEARN Native Driver CLI & IPC Harness
 * Provides both command-line test verification and line-buffered JSON IPC.
 */

#include "hwr_driver.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void run_self_test(void) {
    printf("[HWR-DRIVER] Running native driver self-test...\n");
    hwr_init();
    
    // Draw a simple vertical stroke (e.g. for '1' or 'l')
    HWRPoint pts[10];
    for (int i = 0; i < 10; i++) {
        pts[i].x = 100.0f;
        pts[i].y = 100.0f + (float)i * 10.0f;
    }
    hwr_add_stroke(pts, 10);
    
    HWRResult res;
    int num = hwr_predict(&res);
    printf("[HWR-DRIVER] Detected %d glyphs, recognized text: '%s'\n", num, res.text);
    if (num > 0) {
        printf("[HWR-DRIVER] Glyph 0: '%c' (conf=%.1f, is_sure=%d)\n", 
               res.glyphs[0].final_class, res.glyphs[0].confidence, res.glyphs[0].is_sure);
        printf("[HWR-DRIVER] Top-3: ['%c', '%.1f'], ['%c', '%.1f'], ['%c', '%.1f']\n",
               res.glyphs[0].candidates[0].character, res.glyphs[0].candidates[0].confidence,
               res.glyphs[0].candidates[1].character, res.glyphs[0].candidates[1].confidence,
               res.glyphs[0].candidates[2].character, res.glyphs[0].candidates[2].confidence);
    }
    printf("[HWR-DRIVER] Self-test complete: SUCCESS\n");
}

/* Parse a float from string, skipping whitespace */
static const char* skip_ws(const char* p) {
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    return p;
}

static void run_ipc_loop(void) {
    char buffer[65536];
    hwr_init();
    
    // Line-buffered protocol:
    // CLEAR
    // MODE <m>
    // STROKE <count> \n x1 y1 x2 y2 ...
    // PREDICT
    // TEACH <glyph_idx> <char>
    // RESET
    // PING
    // QUIT
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stdin, NULL, _IONBF, 0);
    
    printf("{\"status\":\"ready\"}\n");
    fflush(stdout);

    while (fgets(buffer, sizeof(buffer), stdin)) {
        char* cmd = buffer;
        while (*cmd == ' ' || *cmd == '\t' || *cmd == '\r' || *cmd == '\n') cmd++;
        if (*cmd == '\0') continue;
        
        if (strncmp(cmd, "PING", 4) == 0) {
            printf("{\"status\":\"pong\"}\n");
        } else if (strncmp(cmd, "RESET", 5) == 0) {
            hwr_reset();
            printf("{\"status\":\"reset_ok\"}\n");
        } else if (strncmp(cmd, "CLEAR", 5) == 0) {
            hwr_clear_strokes();
            printf("{\"status\":\"clear_ok\"}\n");
        } else if (strncmp(cmd, "MODE", 4) == 0) {
            int mode = atoi(cmd + 4);
            hwr_set_mode(mode);
            printf("{\"status\":\"mode_ok\",\"mode\":%d}\n", mode);
        } else if (strncmp(cmd, "STROKE", 6) == 0) {
            int count = 0;
            const char* p = cmd + 6;
            count = (int)strtol(p, (char**)&p, 10);
            if (count > 0 && count <= HWR_MAX_POINTS_PER_STROKE) {
                HWRPoint pts[HWR_MAX_POINTS_PER_STROKE];
                int read_count = 0;
                for (int i = 0; i < count; i++) {
                    p = skip_ws(p);
                    if (!*p) break;
                    pts[i].x = (float)strtod(p, (char**)&p);
                    p = skip_ws(p);
                    if (!*p) break;
                    pts[i].y = (float)strtod(p, (char**)&p);
                    read_count++;
                }
                hwr_add_stroke(pts, read_count);
                printf("{\"status\":\"stroke_added\",\"count\":%d,\"total_strokes\":%d}\n", 
                       read_count, hwr_get_stroke_count());
            } else {
                printf("{\"status\":\"error\",\"msg\":\"invalid_count\"}\n");
            }
        } else if (strncmp(cmd, "PREDICT", 7) == 0) {
            HWRResult res;
            int num = hwr_predict(&res);
            
            // Format JSON output
            printf("{\"status\":\"ok\",\"text\":\"");
            for (const char* cp = res.text; *cp; cp++) {
                if (*cp == '"') printf("\\\"");
                else if (*cp == '\\') printf("\\\\");
                else if (*cp == '\n') printf("\\n");
                else putchar(*cp);
            }
            printf("\",\"num_glyphs\":%d,\"glyphs\":[", num);
            for (int i = 0; i < num; i++) {
                HWRGlyphResult* g = &res.glyphs[i];
                if (i > 0) printf(",");
                char c0 = g->candidates[0].character;
                char c1 = g->candidates[1].character;
                char c2 = g->candidates[2].character;
                // escape char if backslash or quote
                printf("{\"final_class\":\"%c\",\"is_sure\":%d,\"confidence\":%.2f,",
                       g->final_class == '"' ? '\'' : g->final_class,
                       g->is_sure, g->confidence);
                printf("\"bbox\":[%d,%d,%d,%d],", g->x1, g->y1, g->x2, g->y2);
                printf("\"candidates\":[[\"%c\",%.2f],[\"%c\",%.2f],[\"%c\",%.2f]]}",
                       c0 == '"' ? '\'' : c0, g->candidates[0].confidence,
                       c1 == '"' ? '\'' : c1, g->candidates[1].confidence,
                       c2 == '"' ? '\'' : c2, g->candidates[2].confidence);
            }
            printf("]}\n");
        } else if (strncmp(cmd, "TEACH", 5) == 0) {
            int g_idx = 0;
            char target_c = '?';
            const char* p = cmd + 5;
            g_idx = (int)strtol(p, (char**)&p, 10);
            p = skip_ws(p);
            if (*p) target_c = *p;
            int total = hwr_teach_glyph(g_idx, target_c);
            const uint8_t* g8 = hwr_get_last_grid8();
            const uint8_t* g57 = hwr_get_last_grid57();
            printf("{\"status\":\"teach_ok\",\"bank_count\":%d,\"label\":\"%c\",", total, target_c == '"' ? '\'' : target_c);
            printf("\"grid8_hex\":\"");
            for (int b = 0; b < 8; b++) printf("%02x", g8[b]);
            printf("\",\"grid57_hex\":\"");
            for (int b = 0; b < 7; b++) printf("%02x", g57[b]);
            printf("\",\"aspect\":%d,\"flags\":%d}\n", hwr_get_last_aspect(), hwr_get_last_flags());
        } else if (strncmp(cmd, "LOAD_BANK", 9) == 0) {
            char label = '?';
            char hex8[32] = {0}, hex57[32] = {0};
            int aspect = 0, flags = 0;
            const char* p = cmd + 9;
            p = skip_ws(p);
            if (*p) label = *p++;
            p = skip_ws(p);
            int idx = 0;
            while (*p && *p != ' ' && idx < 31) hex8[idx++] = *p++;
            hex8[idx] = '\0';
            p = skip_ws(p);
            idx = 0;
            while (*p && *p != ' ' && idx < 31) hex57[idx++] = *p++;
            hex57[idx] = '\0';
            aspect = (int)strtol(p, (char**)&p, 10);
            flags = (int)strtol(p, (char**)&p, 10);

            uint8_t g8[8] = {0}, g57[7] = {0};
            for (int b = 0; b < 8 && hex8[b*2] && hex8[b*2+1]; b++) {
                char byte_str[3] = { hex8[b*2], hex8[b*2+1], '\0' };
                g8[b] = (uint8_t)strtol(byte_str, NULL, 16);
            }
            for (int b = 0; b < 7 && hex57[b*2] && hex57[b*2+1]; b++) {
                char byte_str[3] = { hex57[b*2], hex57[b*2+1], '\0' };
                g57[b] = (uint8_t)strtol(byte_str, NULL, 16);
            }
            int total = hwr_load_bank_sample(g8, g57, label, (uint8_t)aspect, (uint8_t)flags);
            printf("{\"status\":\"load_bank_ok\",\"bank_count\":%d}\n", total);
        } else if (strncmp(cmd, "QUIT", 4) == 0) {
            printf("{\"status\":\"bye\"}\n");
            break;
        } else {
            printf("{\"status\":\"unknown_command\"}\n");
        }
        fflush(stdout);
    }
}

int main(int argc, char** argv) {
    if (argc > 1 && strcmp(argv[1], "--test") == 0) {
        run_self_test();
        return 0;
    }
    if (argc > 1 && strcmp(argv[1], "--ipc") == 0) {
        run_ipc_loop();
        return 0;
    }
    printf("HWR-LEARN Native Driver Harness\n");
    printf("Usage:\n");
    printf("  %s --test   Run self-test\n", argv[0]);
    printf("  %s --ipc    Run standard IPC protocol over stdin/stdout\n", argv[0]);
    return 0;
}
