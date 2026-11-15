# HWR-LEARN — Full Touch Screen Android App (.apk)

This directory contains the complete native Android application project for **HWR-LEARN**, featuring a full-screen touch canvas, native C99 recognition core via JNI, Top-3 candidate popovers, and interactive handwriting teaching.

---

## 1. Project Architecture

- **`app/src/main/cpp/`**:
  - `hwr_driver.c`, `hwr_driver.h`, `hwr_data.h`: Native C99 driver core with embedded seeds, prototypes, and perceptron matrices.
  - `hwr_jni.c`: High-speed JNI bridge translating touch stroke coordinate arrays to the C engine.
  - `CMakeLists.txt`: Android NDK build script targeting `arm64-v8a`, `armeabi-v7a`, and `x86_64`.
- **`app/src/main/java/com/hwrlearn/app/`**:
  - `DrawingView.java`: Smooth multi-touch canvas with Bezier curve interpolation and lined paper background.
  - `HwrNative.java`: JNI bindings for `init`, `predict`, `teachGlyph`, and `clearStrokes`.
  - `MainActivity.java`: UI coordinator with READ button, Clear, Undo, Mode selection, interactive character pills, and Top-3 inspection/teaching dialog.
- **`app/src/main/res/`**: Layouts, material colors, and strings.

---

## 2. Download and Install the APK

### Direct Download to Your Phone (Easiest)
1. Open this link directly on your Android phone's browser:
   **[HWR-LEARN v1.0.0 Release](https://github.com/satwiksarkar/hwr-learn/releases/tag/v1.0.0)**
2. Tap **`HWR-LEARN-v1.0.0.apk`** to download it.
3. Tap the downloaded file in your notification bar and select **Install**.

---

### Option B: Download via Termux on Your Phone
If you are inside Termux on your phone:
```bash
# 1. Download the APK directly
curl -LO https://github.com/satwiksarkar/hwr-learn/releases/download/v1.0.0/HWR-LEARN-v1.0.0.apk

# 2. Trigger the Android package installer
termux-open HWR-LEARN-v1.0.0.apk
```

---

### Option C: Sideload from PC via ADB
If your phone is connected to your PC with USB debugging enabled:
```powershell
adb install dist/HWR-LEARN-v1.0.0.apk
```

---

## 3. How to Use on Your Phone

1. **Draw with Finger / Stylus**:
   Draw natural handwriting strokes on the lined paper canvas.
2. **Tap READ**:
   The native C engine transcribes your handwriting in under 2 milliseconds.
3. **Inspect & Teach**:
   - Tap any recognized letter pill at the bottom.
   - A dialog displays the **Top-3 suggestions** with confidence percentages.
   - Tap any suggestion or type a letter into the teach box to reinforce the model on the fly.
4. **Offline Guarantee**:
   The app runs 100% offline with zero internet access, zero telemetry, and zero lag.
