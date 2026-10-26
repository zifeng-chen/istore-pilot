package com.chaof.istoreos.widget;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.util.AttributeSet;
import android.view.View;

import com.chaof.istoreos.R;

/** 实时速率的小折线图：60 个点，每个点 2 秒，窗口约 2 分钟。 */
public class GraphView extends View {

    private static final int N = 60;

    private final float[] down = new float[N];
    private final float[] up = new float[N];

    private final Paint gridPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint downPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint upPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint fillPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();

    public GraphView(Context c) {
        this(c, null);
    }

    public GraphView(Context c, AttributeSet attrs) {
        super(c, attrs);
        gridPaint.setStyle(Paint.Style.STROKE);
        gridPaint.setStrokeWidth(d(0.7f));
        gridPaint.setColor(c.getColor(R.color.divider));

        downPaint.setStyle(Paint.Style.STROKE);
        downPaint.setStrokeWidth(d(1.8f));
        downPaint.setStrokeJoin(Paint.Join.ROUND);
        downPaint.setStrokeCap(Paint.Cap.ROUND);
        downPaint.setColor(c.getColor(R.color.primary));

        upPaint.setStyle(Paint.Style.STROKE);
        upPaint.setStrokeWidth(d(1.6f));
        upPaint.setStrokeJoin(Paint.Join.ROUND);
        upPaint.setStrokeCap(Paint.Cap.ROUND);
        upPaint.setColor(c.getColor(R.color.warn));

        fillPaint.setStyle(Paint.Style.FILL);
        fillPaint.setColor(0x1A2DD4A7);
    }

    private float d(float dp) {
        return dp * getResources().getDisplayMetrics().density;
    }

    /** 传入字节/秒 */
    public void push(double downBps, double upBps) {
        System.arraycopy(down, 1, down, 0, N - 1);
        System.arraycopy(up, 1, up, 0, N - 1);
        down[N - 1] = (float) Math.max(0, downBps);
        up[N - 1] = (float) Math.max(0, upBps);
        invalidate();
    }

    public float peak() {
        float m = 0f;
        for (int i = 0; i < N; i++) {
            m = Math.max(m, Math.max(down[i], up[i]));
        }
        return m;
    }

    @Override
    protected void onDraw(Canvas canvas) {
        int w = getWidth();
        int h = getHeight();
        if (w <= 0 || h <= 0) {
            return;
        }

        // 三条横向参考线
        for (int i = 1; i <= 2; i++) {
            float y = h - (h * i / 3f);
            canvas.drawLine(0, y, w, y, gridPaint);
        }

        float max = peak();
        if (max < 1024f * 8f) {
            max = 1024f * 8f; // 静默时也给一点量程，避免线贴着顶
        }

        drawSeries(canvas, down, max, downPaint, true);
        drawSeries(canvas, up, max, upPaint, false);
    }

    private void drawSeries(Canvas canvas, float[] data, float max, Paint paint, boolean fill) {
        int w = getWidth();
        int h = getHeight();
        float step = w / (float) (N - 1);
        float top = h * 0.08f;

        path.reset();
        for (int i = 0; i < N; i++) {
            float x = i * step;
            float y = h - (data[i] / max) * (h - top);
            if (i == 0) {
                path.moveTo(x, y);
            } else {
                path.lineTo(x, y);
            }
        }
        canvas.drawPath(path, paint);

        if (fill) {
            path.lineTo(w, h);
            path.lineTo(0, h);
            path.close();
            canvas.drawPath(path, fillPaint);
        }
    }
}
