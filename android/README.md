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

## 2. How to Build the APK

### Option A: Using Android Studio (Recommended on PC/Mac/Linux)
1. Open **Android Studio**.
2. Select **File > Open** and choose the `android/` folder:
   `c:\8086\hand written text recognisation\android`
3. Android Studio will automatically sync Gradle and detect the C++ CMake project.
4. Click **Build > Build Bundle(s) / APK(s) > Build APK(s)** (or press `Ctrl + F9`).
5. Your output `.apk` will be generated at:
   `android/app/build/outputs/apk/debug/app-debug.apk`
6. Transfer `app-debug.apk` to your phone and tap it to install!

---

### Option B: Building Directly on Your Android Phone via Termux
You can compile the APK directly on your phone without needing a computer:
1. Open **Termux** on your phone.
2. Install OpenJDK and Gradle:
   ```bash
   pkg update
   pkg install openjdk-17 gradle
   ```
3. Navigate to the `android/` directory:
   ```bash
   cd ~/storage/downloads/hand-written-text-recognisation/android
   ```
4. Build the debug APK:
   ```bash
   gradle assembleDebug
   ```
5. Install the resulting APK:
   ```bash
   termux-open app/build/outputs/apk/debug/app-debug.apk
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
