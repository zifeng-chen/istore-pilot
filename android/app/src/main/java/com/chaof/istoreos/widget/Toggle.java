package com.chaof.istoreos.widget;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.View;
import android.view.animation.DecelerateInterpolator;

import com.chaof.istoreos.R;
import com.chaof.istoreos.util.Ui;

/**
 * 自绘开关。
 *
 * 不用 android.widget.Switch：那个控件在深色主题下轨道是系统灰、
 * 拇指是系统白，和这套带绿调的配色放一起像贴上去的。
 * 自己画能保证「关=track 色，开=主色 + 白拇指」，和界面其它元素同一套语言。
 *
 * 动画用 ValueAnimator 只驱动一个 0..1 的进度值，轨道颜色和拇指位置都从它算，
 * 所以不存在「颜色跳变但位置没动」的错位。
 */
public class Toggle extends View {

    public interface OnChange {
        /** 返回 false 表示拒绝这次变更（例如请求失败要回弹），界面会自己弹回去 */
        boolean onChange(boolean on);
    }

    private final Paint track = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint thumb = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF box = new RectF();

    private boolean on = false;
    /** 0 = 关，1 = 开，动画中间值 */
    private float progress = 0f;
    private boolean enabled = true;
    private OnChange listener;

    public Toggle(Context c) {
        super(c);
        thumb.setColor(Color.WHITE);
        setClickable(true);
        setFocusable(true);
    }

    public void setOnChange(OnChange l) {
        this.listener = l;
    }

    public boolean isOn() {
        return on;
    }

    /** 程序设值时不触发回调，用于把服务端状态同步到界面 */
    public void setOn(boolean value, boolean animate) {
        if (on == value) {
            // 值没变也要把进度对齐，否则首次绑定会出现「关着但滑块在右边」
            if (!animate) {
                progress = value ? 1f : 0f;
                invalidate();
            }
            return;
        }
        on = value;
        if (!animate || !isAttachedToWindow()) {
            progress = value ? 1f : 0f;
            invalidate();
            return;
        }
        ValueAnimator a = ValueAnimator.ofFloat(progress, value ? 1f : 0f);
        a.setDuration(150);
        a.setInterpolator(new DecelerateInterpolator());
        a.addUpdateListener(v -> {
            progress = (float) v.getAnimatedValue();
            invalidate();
        });
        a.start();
    }

    public void setEnabledState(boolean en) {
        enabled = en;
        setAlpha(en ? 1f : 0.45f);
        setClickable(en);
    }

    @Override
    public boolean performClick() {
        if (!enabled) {
            return false;
        }
        boolean want = !on;
        if (listener != null && !listener.onChange(want)) {
            // 回调拒绝（请求失败）时保持原状，不要留下「看起来开了其实没开」
            return true;
        }
        setOn(want, true);
        return true;
    }

    @Override
    protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        setMeasuredDimension(Ui.dp(getContext(), 44), Ui.dp(getContext(), 26));
    }

    @Override
    protected void onDraw(Canvas canvas) {
        Context c = getContext();
        float w = getWidth();
        float h = getHeight();
        float r = h / 2f;

        int offColor = Ui.color(c, R.color.track);
        int onColor = Ui.color(c, R.color.primary);
        track.setColor(blend(offColor, onColor, progress));

        box.set(0, 0, w, h);
        canvas.drawRoundRect(box, r, r, track);

        float pad = h * 0.12f;
        float d = h - pad * 2;
        float x = pad + progress * (w - d - pad * 2);
        // 阴影只给拇指，让滑块有厚度；半径小、alpha 低，深色下不会糊成一团
        thumb.setShadowLayer(Ui.dp(c, 1.6f), 0, Ui.dp(c, 0.8f), 0x33000000);
        setLayerType(LAYER_TYPE_SOFTWARE, null);
        canvas.drawCircle(x + d / 2f, h / 2f, d / 2f, thumb);
    }

    /** 两个颜色的线性插值，逐通道算，不做整型近似 */
    private static int blend(int from, int to, float t) {
        t = Math.max(0f, Math.min(1f, t));
        int a = (int) (Color.alpha(from) + (Color.alpha(to) - Color.alpha(from)) * t);
        int r = (int) (Color.red(from) + (Color.red(to) - Color.red(from)) * t);
        int g = (int) (Color.green(from) + (Color.green(to) - Color.green(from)) * t);
        int b = (int) (Color.blue(from) + (Color.blue(to) - Color.blue(from)) * t);
        return Color.argb(a, r, g, b);
    }
}
