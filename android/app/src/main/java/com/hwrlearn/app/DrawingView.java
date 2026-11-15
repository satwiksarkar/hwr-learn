package com.hwrlearn.app;

import android.content.Context;
import android.graphics.*;
import android.util.AttributeSet;
import android.view.MotionEvent;
import android.view.View;

import java.util.ArrayList;
import java.util.List;

public class DrawingView extends View {
    private Paint paint;
    private Paint guidePaint;
    private Path currentPath;
    private List<Path> paths = new ArrayList<>();
    private List<List<PointF>> allStrokes = new ArrayList<>();
    private List<PointF> currentStroke = new ArrayList<>();

    private float lastX, lastY;
    private OnStrokeListener listener;

    public interface OnStrokeListener {
        void onStrokeCompleted(int strokeCount);
    }

    public DrawingView(Context context, AttributeSet attrs) {
        super(context, attrs);
        init();
    }

    private void init() {
        paint = new Paint();
        paint.setAntiAlias(true);
        paint.setColor(Color.parseColor("#1E293B")); // Slate dark ink
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeJoin(Paint.Join.ROUND);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeWidth(7.0f);

        guidePaint = new Paint();
        guidePaint.setAntiAlias(true);
        guidePaint.setColor(Color.parseColor("#E2E8F0")); // Very light grey guideline
        guidePaint.setStrokeWidth(2.0f);
        guidePaint.setStyle(Paint.Style.STROKE);

        currentPath = new Path();
    }

    public void setOnStrokeListener(OnStrokeListener l) {
        this.listener = l;
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        // Clean digital notebook paper background
        canvas.drawColor(Color.parseColor("#FAF8F5"));

        // Draw writing reference guidelines
        float h = getHeight();
        float w = getWidth();
        for (float y = 140; y < h; y += 120) {
            canvas.drawLine(40, y, w - 40, y, guidePaint);
        }

        // Draw completed paths
        for (Path p : paths) {
            canvas.drawPath(p, paint);
        }
        // Draw active path
        canvas.drawPath(currentPath, paint);
    }

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        float x = event.getX();
        float y = event.getY();

        switch (event.getAction()) {
            case MotionEvent.ACTION_DOWN:
                currentPath = new Path();
                currentPath.moveTo(x, y);
                lastX = x;
                lastY = y;
                currentStroke = new ArrayList<>();
                currentStroke.add(new PointF(x, y));
                invalidate();
                return true;

            case MotionEvent.ACTION_MOVE:
                float dx = Math.abs(x - lastX);
                float dy = Math.abs(y - lastY);
                if (dx >= 3 || dy >= 3) {
                    currentPath.quadTo(lastX, lastY, (x + lastX) / 2, (y + lastY) / 2);
                    lastX = x;
                    lastY = y;
                    currentStroke.add(new PointF(x, y));
                }
                invalidate();
                return true;

            case MotionEvent.ACTION_UP:
                currentPath.lineTo(lastX, lastY);
                paths.add(currentPath);
                allStrokes.add(currentStroke);

                // Pass points directly to native driver
                int count = currentStroke.size();
                if (count > 0) {
                    float[] xs = new float[count];
                    float[] ys = new float[count];
                    for (int i = 0; i < count; i++) {
                        xs[i] = currentStroke.get(i).x;
                        ys[i] = currentStroke.get(i).y;
                    }
                    HwrNative.addStroke(xs, ys, count);
                }

                if (listener != null) {
                    listener.onStrokeCompleted(paths.size());
                }

                currentPath = new Path();
                invalidate();
                return true;
        }
        return super.onTouchEvent(event);
    }

    public void clearCanvas() {
        paths.clear();
        allStrokes.clear();
        currentPath.reset();
        HwrNative.clearStrokes();
        invalidate();
    }

    public void undoLastStroke() {
        if (!paths.isEmpty()) {
            paths.remove(paths.size() - 1);
            allStrokes.remove(allStrokes.size() - 1);

            // Re-feed remaining strokes to native driver
            HwrNative.clearStrokes();
            for (List<PointF> stroke : allStrokes) {
                int count = stroke.size();
                float[] xs = new float[count];
                float[] ys = new float[count];
                for (int i = 0; i < count; i++) {
                    xs[i] = stroke.get(i).x;
                    ys[i] = stroke.get(i).y;
                }
                HwrNative.addStroke(xs, ys, count);
            }
            invalidate();
            if (listener != null) {
                listener.onStrokeCompleted(paths.size());
            }
        }
    }
}
