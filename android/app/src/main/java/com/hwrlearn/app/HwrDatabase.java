package com.hwrlearn.app;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;

import java.util.ArrayList;
import java.util.List;

public class HwrDatabase extends SQLiteOpenHelper {
    private static final String DATABASE_NAME = "hwrlearn.db";
    private static final int DATABASE_VERSION = 1;

    public static class Sample {
        public int id;
        public char label;
        public byte[] grid8;
        public byte[] grid57;
        public int aspect;
        public int flags;

        public Sample(int id, char label, byte[] grid8, byte[] grid57, int aspect, int flags) {
            this.id = id;
            this.label = label;
            this.grid8 = grid8;
            this.grid57 = grid57;
            this.aspect = aspect;
            this.flags = flags;
        }
    }

    public HwrDatabase(Context context) {
        super(context, DATABASE_NAME, null, DATABASE_VERSION);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE IF NOT EXISTS samples (" +
                "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
                "label TEXT NOT NULL, " +
                "grid8 BLOB NOT NULL, " +
                "grid57 BLOB NOT NULL, " +
                "aspect INTEGER NOT NULL, " +
                "flags INTEGER NOT NULL, " +
                "created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);");

        db.execSQL("CREATE TABLE IF NOT EXISTS documents (" +
                "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
                "title TEXT NOT NULL, " +
                "text TEXT NOT NULL, " +
                "created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);");
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        db.execSQL("DROP TABLE IF EXISTS samples");
        db.execSQL("DROP TABLE IF EXISTS documents");
        onCreate(db);
    }

    public synchronized long insertSample(char label, byte[] grid8, byte[] grid57, int aspect, int flags) {
        SQLiteDatabase db = getWritableDatabase();
        ContentValues cv = new ContentValues();
        cv.put("label", String.valueOf(label));
        cv.put("grid8", grid8);
        cv.put("grid57", grid57);
        cv.put("aspect", aspect);
        cv.put("flags", flags);
        return db.insert("samples", null, cv);
    }

    public synchronized List<Sample> getAllSamples() {
        List<Sample> list = new ArrayList<>();
        SQLiteDatabase db = getReadableDatabase();
        Cursor cursor = db.rawQuery("SELECT id, label, grid8, grid57, aspect, flags FROM samples ORDER BY id ASC", null);
        if (cursor != null) {
            while (cursor.moveToNext()) {
                int id = cursor.getInt(0);
                String lblStr = cursor.getString(1);
                char label = lblStr.isEmpty() ? '?' : lblStr.charAt(0);
                byte[] g8 = cursor.getBlob(2);
                byte[] g57 = cursor.getBlob(3);
                int aspect = cursor.getInt(4);
                int flags = cursor.getInt(5);
                list.add(new Sample(id, label, g8, g57, aspect, flags));
            }
            cursor.close();
        }
        return list;
    }

    public synchronized int getSampleCount() {
        SQLiteDatabase db = getReadableDatabase();
        Cursor c = db.rawQuery("SELECT COUNT(*) FROM samples", null);
        int count = 0;
        if (c != null) {
            if (c.moveToFirst()) {
                count = c.getInt(0);
            }
            c.close();
        }
        return count;
    }

    public synchronized void deleteAllSamples() {
        SQLiteDatabase db = getWritableDatabase();
        db.delete("samples", null, null);
    }

    public synchronized long insertDocument(String title, String text) {
        SQLiteDatabase db = getWritableDatabase();
        ContentValues cv = new ContentValues();
        cv.put("title", title);
        cv.put("text", text);
        return db.insert("documents", null, cv);
    }
}
