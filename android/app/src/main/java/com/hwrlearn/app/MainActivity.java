package com.hwrlearn.app;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Environment;
import android.view.View;
import android.widget.*;
import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

public class MainActivity extends AppCompatActivity {
    private DrawingView drawingView;
    private TextView tvStatus;
    private TextView tvBankBadge;
    private LinearLayout llGlyphsContainer;
    private Button btnRead;
    private Button btnClear;
    private Button btnUndo;
    private Button btnAppend;
    private Button btnShare;
    private Button btnReset;
    private Spinner spMode;

    private HwrDatabase hwrDatabase;
    private String lastRecognizedText = "";
    private List<JSONObject> lastGlyphs = new ArrayList<>();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        // 1. Initialize Native C Driver
        HwrNative.init();

        // 2. Initialize SQLite Database & load persistent taught samples into driver
        hwrDatabase = new HwrDatabase(this);
        List<HwrDatabase.Sample> savedSamples = hwrDatabase.getAllSamples();
        for (HwrDatabase.Sample s : savedSamples) {
            HwrNative.loadBankSample(s.grid8, s.grid57, s.label, s.aspect, s.flags);
        }

        drawingView = findViewById(R.id.drawingView);
        tvStatus = findViewById(R.id.tvStatus);
        tvBankBadge = findViewById(R.id.tvBankBadge);
        llGlyphsContainer = findViewById(R.id.llGlyphsContainer);
        btnRead = findViewById(R.id.btnRead);
        btnClear = findViewById(R.id.btnClear);
        btnUndo = findViewById(R.id.btnUndo);
        btnAppend = findViewById(R.id.btnAppend);
        btnShare = findViewById(R.id.btnShare);
        btnReset = findViewById(R.id.btnReset);
        spMode = findViewById(R.id.spMode);

        updateBankBadge();

        // Mode selector
        ArrayAdapter<String> modeAdapter = new ArrayAdapter<>(this,
                android.R.layout.simple_spinner_dropdown_item,
                new String[]{"Mode: AUTO", "Mode: ABC (Caps)", "Mode: abc (Lower)", "Mode: 123 (Digits)"});
        spMode.setAdapter(modeAdapter);
        spMode.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
            @Override
            public void onItemSelected(AdapterView<?> parent, View view, int position, long id) {
                HwrNative.setMode(position);
            }
            @Override
            public void onNothingSelected(AdapterView<?> parent) {}
        });

        btnRead.setOnClickListener(v -> performRecognition());
        btnClear.setOnClickListener(v -> {
            drawingView.clearCanvas();
            llGlyphsContainer.removeAllViews();
            lastRecognizedText = "";
            tvStatus.setText("Canvas cleared. Write natural strokes above.");
        });
        btnUndo.setOnClickListener(v -> drawingView.undoLastStroke());
        btnAppend.setOnClickListener(v -> showAppendDialog());
        btnShare.setOnClickListener(v -> showShareDialog());
        btnReset.setOnClickListener(v -> showResetDialog());

        drawingView.setOnStrokeListener(count -> {
            tvStatus.setText("Strokes on canvas: " + count + " — Tap READ when done.");
        });

        if (!savedSamples.isEmpty()) {
            tvStatus.setText("Ready: " + savedSamples.size() + " taught samples loaded from SQLite. Draw strokes above.");
        }
    }

    private void updateBankBadge() {
        int count = hwrDatabase.getSampleCount();
        tvBankBadge.setText("Taught: " + count + " in SQLite");
    }

    private void performRecognition() {
        try {
            // Call native driver predict in C
            String jsonResult = HwrNative.predict();
            JSONObject root = new JSONObject(jsonResult);
            String fullText = root.optString("text", "");
            lastRecognizedText = fullText;
            JSONArray glyphsArray = root.optJSONArray("glyphs");

            llGlyphsContainer.removeAllViews();
            lastGlyphs.clear();

            if (glyphsArray != null && glyphsArray.length() > 0) {
                for (int i = 0; i < glyphsArray.length(); i++) {
                    JSONObject gObj = glyphsArray.getJSONObject(i);
                    lastGlyphs.add(gObj);

                    final int glyphIdx = i;
                    String ch = gObj.optString("final_class", "?");
                    boolean isSure = gObj.optInt("is_sure", 1) == 1;

                    Button pill = new Button(this);
                    pill.setText(ch);
                    pill.setTextSize(20);
                    pill.setPadding(24, 12, 24, 12);
                    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                            LinearLayout.LayoutParams.WRAP_CONTENT,
                            LinearLayout.LayoutParams.WRAP_CONTENT
                    );
                    lp.setMargins(8, 4, 8, 4);
                    pill.setLayoutParams(lp);

                    // Green if sure, Amber if ambiguous
                    if (isSure) {
                        pill.setBackgroundColor(0xFFDCFCE7); // Soft Green
                        pill.setTextColor(0xFF166534);
                    } else {
                        pill.setBackgroundColor(0xFFFEF3C7); // Soft Amber
                        pill.setTextColor(0xFF92400E);
                    }

                    pill.setOnClickListener(btn -> showTop3Dialog(glyphIdx));
                    llGlyphsContainer.addView(pill);
                }
                tvStatus.setText("Recognized: \"" + fullText + "\" (Tap letter to teach; or Append/Share)");
            } else {
                tvStatus.setText("No characters detected. Write on the canvas above.");
            }
        } catch (Exception e) {
            tvStatus.setText("Recognition error: " + e.getMessage());
        }
    }

    private void showTop3Dialog(int glyphIdx) {
        if (glyphIdx < 0 || glyphIdx >= lastGlyphs.size()) return;
        JSONObject g = lastGlyphs.get(glyphIdx);

        JSONArray cands = g.optJSONArray("candidates");
        if (cands == null) return;

        AlertDialog.Builder builder = new AlertDialog.Builder(this);
        builder.setTitle("Inspect & Teach Character");

        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(40, 20, 40, 20);

        TextView tvPrompt = new TextView(this);
        tvPrompt.setText("Top suggestions from Native Driver:");
        tvPrompt.setPadding(0, 0, 0, 16);
        layout.addView(tvPrompt);

        // Candidate buttons
        for (int i = 0; i < cands.length() && i < 3; i++) {
            JSONArray c = cands.optJSONArray(i);
            if (c == null) continue;
            String ch = c.optString(0);
            double conf = c.optDouble(1, 0.0);

            Button btnCand = new Button(this);
            btnCand.setText(String.format("Option %d:  '%s'  (Confidence: %.0f%%)", i + 1, ch, conf));
            btnCand.setOnClickListener(v -> teachCharacter(glyphIdx, ch.charAt(0)));
            layout.addView(btnCand);
        }

        // Custom teach input
        TextView tvTeachPrompt = new TextView(this);
        tvTeachPrompt.setText("\nOr teach any other character:");
        layout.addView(tvTeachPrompt);

        EditText etCustom = new EditText(this);
        etCustom.setHint("Type single letter or symbol");
        layout.addView(etCustom);

        Button btnTeach = new Button(this);
        btnTeach.setText("Reinforce Learning in SQLite");
        btnTeach.setOnClickListener(v -> {
            String txt = etCustom.getText().toString().trim();
            if (!txt.isEmpty()) {
                teachCharacter(glyphIdx, txt.charAt(0));
            }
        });
        layout.addView(btnTeach);

        builder.setView(layout);
        builder.setNegativeButton("Cancel", (dialog, which) -> dialog.dismiss());

        AlertDialog dialog = builder.create();
        dialog.show();
    }

    private void teachCharacter(int glyphIdx, char targetChar) {
        // 1. Teach native C driver in RAM
        HwrNative.teachGlyph(glyphIdx, targetChar);

        // 2. Fetch extracted binary grids from native driver
        byte[] g8 = HwrNative.getLastGrid8();
        byte[] g57 = HwrNative.getLastGrid57();
        int aspect = HwrNative.getLastAspect();
        int flags = HwrNative.getLastFlags();

        // 3. Persist to SQLite database
        hwrDatabase.insertSample(targetChar, g8, g57, aspect, flags);
        updateBankBadge();

        Toast.makeText(this, "Learned '" + targetChar + "' (Saved in SQLite, total: " + hwrDatabase.getSampleCount() + ")", Toast.LENGTH_SHORT).show();

        // 4. Re-run recognition on current strokes to show updated result immediately
        performRecognition();
    }

    private void showResetDialog() {
        int count = hwrDatabase.getSampleCount();
        new AlertDialog.Builder(this)
                .setTitle("Reset All Learning?")
                .setMessage("This will wipe all " + count + " personal taught samples from SQLite and revert the C recognition model to factory defaults.")
                .setPositiveButton("Reset Everything", (dialog, which) -> {
                    // Reset native driver in RAM
                    HwrNative.reset();
                    // Delete from SQLite
                    hwrDatabase.deleteAllSamples();
                    updateBankBadge();
                    drawingView.clearCanvas();
                    llGlyphsContainer.removeAllViews();
                    lastRecognizedText = "";
                    tvStatus.setText("Model reset. Factory recognition restored (0 taught samples).");
                    Toast.makeText(this, "All taught data reset successfully.", Toast.LENGTH_SHORT).show();
                })
                .setNegativeButton("Cancel", (dialog, which) -> dialog.dismiss())
                .show();
    }

    private void showAppendDialog() {
        if (lastRecognizedText.trim().isEmpty()) {
            Toast.makeText(this, "No recognized text to append. Tap READ first.", Toast.LENGTH_SHORT).show();
            return;
        }

        AlertDialog.Builder builder = new AlertDialog.Builder(this);
        builder.setTitle("Append to .txt File");

        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(40, 20, 40, 20);

        TextView tvInfo = new TextView(this);
        tvInfo.setText("Text to append:\n\"" + lastRecognizedText + "\"\n");
        tvInfo.setTextSize(14);
        tvInfo.setTextColor(0xFF1E293B);
        layout.addView(tvInfo);

        TextView tvFileLabel = new TextView(this);
        tvFileLabel.setText("File name (.txt):");
        layout.addView(tvFileLabel);

        EditText etFileName = new EditText(this);
        etFileName.setText("hwr_notes.txt");
        layout.addView(etFileName);

        CheckBox cbBackup = new CheckBox(this);
        cbBackup.setText("Create safety backup (.bak) before writing");
        cbBackup.setChecked(true);
        layout.addView(cbBackup);

        builder.setView(layout);
        builder.setPositiveButton("Append to File", (dialog, which) -> {
            String fileName = etFileName.getText().toString().trim();
            if (fileName.isEmpty()) fileName = "hwr_notes.txt";
            if (!fileName.endsWith(".txt")) fileName += ".txt";

            boolean makeBackup = cbBackup.isChecked();
            appendToFile(fileName, lastRecognizedText, makeBackup);
        });
        builder.setNegativeButton("Cancel", (dialog, which) -> dialog.dismiss());
        builder.show();
    }

    private void appendToFile(String fileName, String text, boolean makeBackup) {
        try {
            File dir = getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS);
            if (dir == null) dir = getFilesDir();
            if (!dir.exists()) dir.mkdirs();

            File targetFile = new File(dir, fileName);

            // Create .bak backup if target file already exists and backup is requested
            if (makeBackup && targetFile.exists() && targetFile.length() > 0) {
                File backupFile = new File(dir, fileName + ".bak");
                FileInputStream in = new FileInputStream(targetFile);
                FileOutputStream out = new FileOutputStream(backupFile);
                byte[] buf = new byte[4096];
                int len;
                while ((len = in.read(buf)) > 0) {
                    out.write(buf, 0, len);
                }
                in.close();
                out.close();
            }

            // Append text with newline using UTF-8
            FileOutputStream fos = new FileOutputStream(targetFile, true);
            OutputStreamWriter writer = new OutputStreamWriter(fos, StandardCharsets.UTF_8);
            writer.write(text + "\n");
            writer.flush();
            writer.close();

            // Record in SQLite documents table
            hwrDatabase.insertDocument(fileName, text);

            String msg = "Appended to " + fileName + (makeBackup ? " (backup created: " + fileName + ".bak)" : "");
            tvStatus.setText(msg);
            Toast.makeText(this, msg, Toast.LENGTH_LONG).show();
        } catch (Exception e) {
            Toast.makeText(this, "File error: " + e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void showShareDialog() {
        if (lastRecognizedText.trim().isEmpty()) {
            Toast.makeText(this, "No recognized text to share. Tap READ first.", Toast.LENGTH_SHORT).show();
            return;
        }

        // Copy to clipboard
        ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        ClipData clip = ClipData.newPlainText("HWR-LEARN", lastRecognizedText);
        if (clipboard != null) {
            clipboard.setPrimaryClip(clip);
        }

        // Launch Android Share Sheet
        Intent sendIntent = new Intent();
        sendIntent.setAction(Intent.ACTION_SEND);
        sendIntent.putExtra(Intent.EXTRA_TEXT, lastRecognizedText);
        sendIntent.setType("text/plain");

        Intent shareIntent = Intent.createChooser(sendIntent, "Share Recognized Text (Copied to Clipboard)");
        startActivity(shareIntent);
    }
}
