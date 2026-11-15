package com.hwrlearn.app;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.view.View;
import android.widget.*;
import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.content.FileProvider;
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
    private Button btnSave;
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
        btnSave = findViewById(R.id.btnSave);
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
        btnSave.setOnClickListener(v -> showFileOperationDialog(false));
        btnAppend.setOnClickListener(v -> showFileOperationDialog(true));
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
                    pill.setAllCaps(false); // CRITICAL: preserve exact lowercase/uppercase case!
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
                tvStatus.setText("Recognized: \"" + fullText + "\" (Tap letter to teach; or Save/Append)");
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
            btnCand.setAllCaps(false); // Preserve exact letter case
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
        btnTeach.setAllCaps(false);
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

    private File getPublicHwrDir() {
        // 1. Primary location: phone's public Downloads/HWR-LEARN/ (directly visible in Files / Downloads app!)
        File downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
        if (downloads != null) {
            File hwrDir = new File(downloads, "HWR-LEARN");
            if (!hwrDir.exists()) hwrDir.mkdirs();
            if (hwrDir.exists() && hwrDir.canWrite()) return hwrDir;
        }

        // 2. Secondary location: phone's public Documents/HWR-LEARN/
        File documents = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS);
        if (documents != null) {
            File hwrDir = new File(documents, "HWR-LEARN");
            if (!hwrDir.exists()) hwrDir.mkdirs();
            if (hwrDir.exists() && hwrDir.canWrite()) return hwrDir;
        }

        // 3. Fallback: app external documents directory
        File extDocs = getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS);
        if (extDocs != null && !extDocs.exists()) extDocs.mkdirs();
        if (extDocs != null && extDocs.exists()) return extDocs;

        return getFilesDir();
    }

    private void showFileOperationDialog(boolean defaultAppend) {
        if (lastRecognizedText.trim().isEmpty()) {
            Toast.makeText(this, "No recognized text to save. Tap READ first.", Toast.LENGTH_SHORT).show();
            return;
        }

        File targetDir = getPublicHwrDir();
        AlertDialog.Builder builder = new AlertDialog.Builder(this);
        builder.setTitle(defaultAppend ? "Append to .txt File" : "Save as New .txt File");

        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setPadding(40, 20, 40, 20);

        TextView tvInfo = new TextView(this);
        tvInfo.setText("Recognized text:\n\"" + lastRecognizedText + "\"\n");
        tvInfo.setTextSize(14);
        tvInfo.setTextColor(0xFF1E293B);
        layout.addView(tvInfo);

        TextView tvPathInfo = new TextView(this);
        tvPathInfo.setText("Saved in phone folder:\n" + targetDir.getAbsolutePath() + "\n");
        tvPathInfo.setTextSize(12);
        tvPathInfo.setTextColor(0xFF0284C7);
        layout.addView(tvPathInfo);

        TextView tvFileLabel = new TextView(this);
        tvFileLabel.setText("File name (.txt):");
        layout.addView(tvFileLabel);

        EditText etFileName = new EditText(this);
        etFileName.setText("hwr_notes.txt");
        layout.addView(etFileName);

        RadioGroup rgMode = new RadioGroup(this);
        RadioButton rbSave = new RadioButton(this);
        rbSave.setText("Save (Overwrite / Create new)");
        RadioButton rbAppend = new RadioButton(this);
        rbAppend.setText("Append to bottom of existing file");
        rgMode.addView(rbSave);
        rgMode.addView(rbAppend);
        if (defaultAppend) {
            rbAppend.setChecked(true);
        } else {
            rbSave.setChecked(true);
        }
        layout.addView(rgMode);

        CheckBox cbBackup = new CheckBox(this);
        cbBackup.setText("Create safety backup (.bak) before writing");
        cbBackup.setChecked(true);
        layout.addView(cbBackup);

        builder.setView(layout);
        builder.setPositiveButton(defaultAppend ? "Append" : "Save", (dialog, which) -> {
            String fileName = etFileName.getText().toString().trim();
            if (fileName.isEmpty()) fileName = "hwr_notes.txt";
            if (!fileName.endsWith(".txt")) fileName += ".txt";

            boolean isAppendMode = rbAppend.isChecked();
            boolean makeBackup = cbBackup.isChecked();
            executeFileWrite(targetDir, fileName, lastRecognizedText, isAppendMode, makeBackup);
        });
        builder.setNegativeButton("Cancel", (dialog, which) -> dialog.dismiss());
        builder.show();
    }

    private void executeFileWrite(File dir, String fileName, String text, boolean isAppend, boolean makeBackup) {
        try {
            if (!dir.exists()) dir.mkdirs();
            File targetFile = new File(dir, fileName);

            // 1. Create .bak backup if target file already exists and backup is requested
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

            // 2. Write or Append text with newline using UTF-8
            FileOutputStream fos = new FileOutputStream(targetFile, isAppend);
            OutputStreamWriter writer = new OutputStreamWriter(fos, StandardCharsets.UTF_8);
            writer.write(text + "\n");
            writer.flush();
            writer.close();

            // 3. Notify Android MediaScanner so phone's Files / Downloads app sees it immediately
            MediaScannerConnection.scanFile(this,
                    new String[]{targetFile.getAbsolutePath()},
                    new String[]{"text/plain"}, null);

            // 4. Record in SQLite documents table
            hwrDatabase.insertDocument(fileName, text);

            // 5. Show Success Dialog with direct "Open File" and "Share File" buttons!
            showFileSuccessDialog(targetFile, isAppend, makeBackup);
        } catch (Exception e) {
            Toast.makeText(this, "Write error: " + e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void showFileSuccessDialog(File file, boolean wasAppended, boolean madeBackup) {
        AlertDialog.Builder builder = new AlertDialog.Builder(this);
        builder.setTitle(wasAppended ? "Appended Successfully" : "Saved Successfully");

        String msg = "File saved to your phone at:\n" + file.getAbsolutePath() + "\n\n" +
                (madeBackup ? "Safety backup created:\n" + file.getName() + ".bak\n\n" : "") +
                "You can find this file in your phone's 'Files' or 'Downloads' app under 'HWR-LEARN'.";
        builder.setMessage(msg);

        builder.setPositiveButton("Open File", (dialog, which) -> {
            try {
                Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".fileprovider", file);
                Intent viewIntent = new Intent(Intent.ACTION_VIEW);
                viewIntent.setDataAndType(uri, "text/plain");
                viewIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                startActivity(Intent.createChooser(viewIntent, "Open with..."));
            } catch (Exception e) {
                Toast.makeText(this, "Unable to open viewer: " + e.getMessage(), Toast.LENGTH_SHORT).show();
            }
        });

        builder.setNeutralButton("Share File", (dialog, which) -> {
            try {
                Uri uri = FileProvider.getUriForFile(this, getPackageName() + ".fileprovider", file);
                Intent shareIntent = new Intent(Intent.ACTION_SEND);
                shareIntent.setType("text/plain");
                shareIntent.putExtra(Intent.EXTRA_STREAM, uri);
                shareIntent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                startActivity(Intent.createChooser(shareIntent, "Share .txt file via"));
            } catch (Exception e) {
                Toast.makeText(this, "Share error: " + e.getMessage(), Toast.LENGTH_SHORT).show();
            }
        });

        builder.setNegativeButton("Close", (dialog, which) -> dialog.dismiss());
        builder.show();
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
