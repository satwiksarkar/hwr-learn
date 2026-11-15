package com.hwrlearn.app;

import android.app.AlertDialog;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.widget.*;
import androidx.appcompat.app.AppCompatActivity;
import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

public class MainActivity extends AppCompatActivity {
    private DrawingView drawingView;
    private TextView tvStatus;
    private LinearLayout llGlyphsContainer;
    private Button btnRead;
    private Button btnClear;
    private Button btnUndo;
    private Spinner spMode;

    private List<JSONObject> lastGlyphs = new ArrayList<>();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        // 1. Initialize Native C Driver
        HwrNative.init();

        drawingView = findViewById(R.id.drawingView);
        tvStatus = findViewById(R.id.tvStatus);
        llGlyphsContainer = findViewById(R.id.llGlyphsContainer);
        btnRead = findViewById(R.id.btnRead);
        btnClear = findViewById(R.id.btnClear);
        btnUndo = findViewById(R.id.btnUndo);
        spMode = findViewById(R.id.spMode);

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
            tvStatus.setText("Canvas cleared. Write natural strokes above.");
        });
        btnUndo.setOnClickListener(v -> drawingView.undoLastStroke());

        drawingView.setOnStrokeListener(count -> {
            tvStatus.setText("Strokes on canvas: " + count + " — Tap READ when done.");
        });
    }

    private void performRecognition() {
        try {
            // Call native driver predict in C
            String jsonResult = HwrNative.predict();
            JSONObject root = new JSONObject(jsonResult);
            String fullText = root.optString("text", "");
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
                tvStatus.setText("Recognized: \"" + fullText + "\" (Tap any letter to inspect/teach)");
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
            btnCand.setOnClickListener(v -> {
                teachCharacter(glyphIdx, ch.charAt(0));
            });
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
        btnTeach.setText("Reinforce Learning Immediately");
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
        // Teach native C model
        int bankTotal = HwrNative.teachGlyph(glyphIdx, targetChar);
        Toast.makeText(this, "Learned '" + targetChar + "' (Bank count: " + bankTotal + ")", Toast.LENGTH_SHORT).show();
        performRecognition();
    }
}
