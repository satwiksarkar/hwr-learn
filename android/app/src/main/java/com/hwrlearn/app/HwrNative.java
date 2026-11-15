package com.hwrlearn.app;

public class HwrNative {
    static {
        System.loadLibrary("hwr_driver");
    }

    public static native void init();
    public static native void reset();
    public static native void setMode(int mode);
    public static native void clearStrokes();
    public static native int addStroke(float[] xs, float[] ys, int count);
    public static native String predict();
    public static native int teachGlyph(int glyphIdx, char correctChar);
    public static native int loadBankSample(byte[] grid8, byte[] grid57, char label, int aspect, int flags);
}
