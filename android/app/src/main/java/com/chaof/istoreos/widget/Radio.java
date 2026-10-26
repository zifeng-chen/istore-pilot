package com.chaof.istoreos.widget;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.view.View;

import com.chaof.istoreos.util.Ui;

/**
 * 单选圆点。
 *
 * 代理页原来用 "●" / "○" 两个字符当选中态 —— 它们在等宽字体下大小不一，
 * 且字符本身带有字体自带的基线偏移，跟在 14sp 节点名旁边会一高一低。
 * 自己画就没有这些问题：外环固定 1.4dp，选中时内点半径 4dp，尺寸不随字号变。
 *
 * 颜色由调用方给：正常节点用主色，REJECT / DIRECT 这类策略项用 danger / 灰，
 * 这样「选中了但选中的是不代理」也能一眼看出来。
 */
public class Radio extends View {

    private final Paint ring = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private boolean on = false;

    public Radio(Context c, int colorRes) {
        super(c);
        int color = Ui.color(c, colorRes);
        ring.setStyle(Paint.Style.STROKE);
        ring.setStrokeWidth(Math.max(2, Ui.dp(c, 1.4f)));
        ring.setColor(color);
        fill.setStyle(Paint.Style.FILL);
        fill.setColor(color);
        int s = Ui.dp(c, 15);
        setLayoutParams(new android.widget.LinearLayout.LayoutParams(s, s));
    }

    public void setOn(boolean on) {
        if (this.on == on) {
            return;
        }
        this.on = on;
        invalidate();
    }

    public void setColor(int colorRes) {
        int color = Ui.color(getContext(), colorRes);
        ring.setColor(color);
        fill.setColor(color);
        invalidate();
    }

    @Override
    protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float cx = getWidth() / 2f;
        float cy = getHeight() / 2f;
        // 环半径要减掉半个线宽，否则描边会被 View 边界裁掉一半，看着比其他图标细
        float r = Math.min(cx, cy) - ring.getStrokeWidth() / 2f;
        canvas.drawCircle(cx, cy, r, ring);
        if (on) {
            canvas.drawCircle(cx, cy, r * 0.52f, fill);
        }
    }
}
