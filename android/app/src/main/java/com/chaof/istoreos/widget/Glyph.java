package com.chaof.istoreos.widget;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.view.View;

import com.chaof.istoreos.util.Ui;

/**
 * 单色线性图标，全部用 Canvas 现画。
 *
 * 为什么不引 vector drawable / 图标库：
 *  - 这里只需要十来个图形，放一堆 xml 反而更难维护；
 *  - 颜色要跟着主题和状态变（危险操作是红的），代码画可以直接传色；
 *  - 全局只有一个 Paint，滚动时没有额外对象分配。
 *
 * 统一按 24×24 的逻辑坐标设计，绘制时缩放到控件尺寸，
 * 所以同一套图形在 18dp 的列表图标和 22dp 的卡片图标里观感一致。
 */
public final class Glyph extends View {

    /** 24×24 设计稿里的一格 */
    private static final float GRID = 24f;

    public static final int LINK = 1;
    public static final int GLOBE = 2;
    public static final int PALETTE = 3;
    public static final int BOX = 4;
    public static final int SHIELD = 5;
    public static final int INFO = 6;
    public static final int KEY = 7;
    public static final int REFRESH = 8;
    public static final int UPLOAD = 9;
    public static final int CLOCK = 10;
    public static final int CHIP = 11;
    public static final int POWER = 12;
    public static final int LIST = 13;
    public static final int BOLT = 14;

    private final Paint pen = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();
    private final RectF box = new RectF();

    private int kind = LINK;
    private float stroke = 2f;

    public Glyph(Context c) {
        super(c);
        pen.setStyle(Paint.Style.STROKE);
        pen.setStrokeCap(Paint.Cap.ROUND);
        pen.setStrokeJoin(Paint.Join.ROUND);
        fill.setStyle(Paint.Style.FILL);
        setColor(Ui.color(c, com.chaof.istoreos.R.color.text_secondary));
    }

    public static Glyph of(Context c, int kind, int colorRes) {
        Glyph g = new Glyph(c);
        g.setKind(kind);
        g.setColor(Ui.color(c, colorRes));
        return g;
    }

    public void setKind(int kind) {
        this.kind = kind;
        invalidate();
    }

    public void setColor(int color) {
        pen.setColor(color);
        fill.setColor(color);
        invalidate();
    }

    /** 线宽按控件尺寸等比缩放，24dp 的图标看起来才不会「太细」 */
    public void setStrokeDp(float dp) {
        this.stroke = dp;
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        float w = getWidth();
        float h = getHeight();
        if (w <= 0 || h <= 0) {
            return;
        }
        // 按短边铺满，留 12% 边距，避免描边贴到控件边界被切掉
        float size = Math.min(w, h) * 0.88f;
        float s = size / GRID;
        float ox = (w - size) / 2f;
        float oy = (h - size) / 2f;

        canvas.save();
        canvas.translate(ox, oy);
        canvas.scale(s, s);
        pen.setStrokeWidth(stroke);
        shape(canvas);
        canvas.restore();
    }

    private void shape(Canvas c) {
        switch (kind) {
            case GLOBE:
                circle(c, 12, 12, 8.4f);
                // 赤道 + 一条经线，缩到 18dp 时仍能读出「地球」
                line(c, 3.6f, 12, 20.4f, 12);
                box.set(6.2f, 3.6f, 17.8f, 20.4f);
                c.drawOval(box, pen);
                break;

            case LINK:
                // 两个节点 + 中间连线：比画链条更清楚
                circle(c, 5.5f, 12, 2.6f);
                circle(c, 18.5f, 12, 2.6f);
                line(c, 8.1f, 12, 15.9f, 12);
                break;

            case PALETTE:
                circle(c, 12, 12, 8.4f);
                dot(c, 8.6f, 9.4f, 1.5f);
                dot(c, 14.6f, 8.6f, 1.5f);
                dot(c, 16.2f, 14.4f, 1.5f);
                dot(c, 10.2f, 15.8f, 1.5f);
                break;

            case BOX:
                // 立方体：顶面菱形 + 左右两条竖边
                path.reset();
                path.moveTo(12, 3.4f);
                path.lineTo(20, 7.6f);
                path.lineTo(20, 16.4f);
                path.lineTo(12, 20.6f);
                path.lineTo(4, 16.4f);
                path.lineTo(4, 7.6f);
                path.close();
                c.drawPath(path, pen);
                line(c, 4, 7.6f, 12, 11.8f);
                line(c, 20, 7.6f, 12, 11.8f);
                line(c, 12, 11.8f, 12, 20.6f);
                break;

            case SHIELD:
                path.reset();
                path.moveTo(12, 3.2f);
                path.lineTo(19.6f, 6.4f);
                path.lineTo(19.6f, 12.2f);
                path.cubicTo(19.6f, 16.4f, 16.4f, 19.4f, 12, 20.8f);
                path.cubicTo(7.6f, 19.4f, 4.4f, 16.4f, 4.4f, 12.2f);
                path.lineTo(4.4f, 6.4f);
                path.close();
                c.drawPath(path, pen);
                break;

            case INFO:
                circle(c, 12, 12, 8.4f);
                dot(c, 12, 8.2f, 1.3f);
                line(c, 12, 11.2f, 12, 16.2f);
                break;

            case KEY:
                circle(c, 8.4f, 12, 4.2f);
                line(c, 12.6f, 12, 20.2f, 12);
                line(c, 17.4f, 12, 17.4f, 15.4f);
                line(c, 20.2f, 12, 20.2f, 14.6f);
                break;

            case REFRESH:
                box.set(4.2f, 4.2f, 19.8f, 19.8f);
                c.drawArc(box, -50f, 280f, false, pen);
                // 箭头
                path.reset();
                path.moveTo(16.6f, 3.4f);
                path.lineTo(20.4f, 5.6f);
                path.lineTo(16.2f, 7.6f);
                c.drawPath(path, pen);
                break;

            case UPLOAD:
                line(c, 12, 17.4f, 12, 4.6f);
                path.reset();
                path.moveTo(7.6f, 9f);
                path.lineTo(12, 4.4f);
                path.lineTo(16.4f, 9f);
                c.drawPath(path, pen);
                line(c, 4.6f, 19.6f, 19.4f, 19.6f);
                break;

            case CLOCK:
                circle(c, 12, 12, 8.4f);
                line(c, 12, 7.4f, 12, 12.4f);
                line(c, 12, 12.4f, 15.4f, 14.2f);
                break;

            case CHIP:
                box.set(6.2f, 6.2f, 17.8f, 17.8f);
                c.drawRoundRect(box, 2f, 2f, pen);
                box.set(10f, 10f, 14f, 14f);
                c.drawRoundRect(box, 1f, 1f, pen);
                for (int i = 0; i < 3; i++) {
                    float p = 8.2f + i * 3.8f;
                    line(c, p, 2.8f, p, 6.2f);
                    line(c, p, 17.8f, p, 21.2f);
                    line(c, 2.8f, p, 6.2f, p);
                    line(c, 17.8f, p, 21.2f, p);
                }
                break;

            case POWER:
                box.set(4.8f, 5.4f, 19.2f, 19.8f);
                c.drawArc(box, -60f, 300f, false, pen);
                line(c, 12, 2.8f, 12, 11.4f);
                break;

            case LIST:
                line(c, 4, 7, 20, 7);
                line(c, 4, 12, 20, 12);
                line(c, 4, 17, 20, 17);
                break;

            case BOLT:
                path.reset();
                path.moveTo(13.4f, 2.6f);
                path.lineTo(5.4f, 13.6f);
                path.lineTo(11.2f, 13.6f);
                path.lineTo(9.8f, 21.4f);
                path.lineTo(18.4f, 10f);
                path.lineTo(12.4f, 10f);
                path.close();
                c.drawPath(path, pen);
                break;

            default:
                circle(c, 12, 12, 8f);
                break;
        }
    }

    private void circle(Canvas c, float cx, float cy, float r) {
        c.drawCircle(cx, cy, r, pen);
    }

    private void dot(Canvas c, float cx, float cy, float r) {
        c.drawCircle(cx, cy, r, fill);
    }

    private void line(Canvas c, float x1, float y1, float x2, float y2) {
        c.drawLine(x1, y1, x2, y2, pen);
    }
}
