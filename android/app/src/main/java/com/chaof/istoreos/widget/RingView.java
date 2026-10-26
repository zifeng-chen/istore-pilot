package com.chaof.istoreos.widget;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.util.AttributeSet;
import android.view.View;

import com.chaof.istoreos.R;

/** 环形占用率，270° 开口朝下。中间两行字：大号数值 + 小号标题。 */
public class RingView extends View {

    private static final float START_ANGLE = 135f;
    private static final float SWEEP = 270f;

    private final Paint trackPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint arcPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint valuePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint labelPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF oval = new RectF();

    private float progress = 0f;
    private String valueText = "—";
    private String labelText = "";

    public RingView(Context c) {
        this(c, null);
    }

    public RingView(Context c, AttributeSet attrs) {
        super(c, attrs);
        trackPaint.setStyle(Paint.Style.STROKE);
        trackPaint.setStrokeCap(Paint.Cap.ROUND);
        arcPaint.setStyle(Paint.Style.STROKE);
        arcPaint.setStrokeCap(Paint.Cap.ROUND);
        valuePaint.setTextAlign(Paint.Align.CENTER);
        valuePaint.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        labelPaint.setTextAlign(Paint.Align.CENTER);
        applyColors();
    }

    /** 主题切换（深浅色重建视图）后要重新取一遍颜色 */
    public void applyColors() {
        Context c = getContext();
        trackPaint.setColor(c.getColor(R.color.track));
        arcPaint.setColor(c.getColor(R.color.primary));
        valuePaint.setColor(c.getColor(R.color.text_primary));
        labelPaint.setColor(c.getColor(R.color.text_secondary));
        invalidate();
    }

    public void set(float percent, String value) {
        this.progress = Math.max(0f, Math.min(100f, percent));
        this.valueText = value;
        invalidate();
    }

    public void setLabel(String label) {
        this.labelText = label;
        invalidate();
    }

    @Override
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        int def = (int) (getResources().getDisplayMetrics().density * 92);
        // 宽度由父容器（weight 均分）决定，高度跟着宽度走，保证是正方形
        int w = resolveSize(def, widthMeasureSpec);
        if (w <= 0) {
            w = def;
        }
        setMeasuredDimension(w, w);
    }

    @Override
    protected void onDraw(Canvas canvas) {
        int w = getWidth();
        int h = getHeight();
        float stroke = Math.min(w, h) * 0.085f;
        trackPaint.setStrokeWidth(stroke);
        arcPaint.setStrokeWidth(stroke);

        float inset = stroke / 2f + Math.min(w, h) * 0.02f;
        oval.set(inset, inset, w - inset, h - inset);

        canvas.drawArc(oval, START_ANGLE, SWEEP, false, trackPaint);
        if (progress > 0f) {
            canvas.drawArc(oval, START_ANGLE, SWEEP * progress / 100f, false, arcPaint);
        }

        valuePaint.setTextSize(Math.min(w, h) * 0.255f);
        labelPaint.setTextSize(Math.min(w, h) * 0.135f);

        float cx = w / 2f;
        float cy = h / 2f;
        canvas.drawText(valueText, cx, cy + Math.min(w, h) * 0.02f, valuePaint);
        if (!labelText.isEmpty()) {
            canvas.drawText(labelText, cx, cy + Math.min(w, h) * 0.20f, labelPaint);
        }
    }
}
