package com.chaof.istoreos.util;

import android.app.Activity;
import android.view.Display;
import android.view.Window;
import android.view.WindowManager;

/**
 * 高刷屏适配。
 *
 * 现在的手机基本是 90/120/144Hz，但应用默认按 60Hz 合成 ——
 * 弹簧入场、骨架脉冲、趋势线重绘这些每帧都在跑的东西，
 * 在 120Hz 屏上仍然是 60 帧，肉眼能看出「滑得不如系统界面顺」。
 *
 * 做法是改窗口的 Display.Mode 偏好：
 *   - {@code preferredDisplayModeId} 指向具体那个高刷模式（最准）；
 *   - {@code preferredRefreshRate} 作兜底，有些 ROM 不暴露 mode id。
 *
 * 只取「支持模式里的最高值」，不写死 120：144Hz 屏上应该跑到 144。
 * 注意这不是「强制 120」—— 系统省电策略仍可以在熄屏/低电量时降回去，
 * 我们只是不再让窗口默认停在 60Hz。
 */
public final class Hz {

    private Hz() {
    }

    /** @return 实际请求到的刷新率；0 表示读不到（不做任何改动） */
    public static float apply(Activity a) {
        if (a == null) {
            return 0f;
        }
        float best = 0f;
        int bestMode = 0;
        try {
            Display d = a.getWindowManager().getDefaultDisplay();
            Display.Mode[] modes = d.getSupportedModes();
            if (modes != null) {
                for (Display.Mode m : modes) {
                    if (m.getRefreshRate() > best) {
                        best = m.getRefreshRate();
                        bestMode = m.getModeId();
                    }
                }
            }
            if (best <= 0f) {
                best = d.getRefreshRate();
            }
        } catch (Throwable ignored) {
            return 0f;
        }
        // 60 及以下没什么可优化的，别去动窗口参数
        if (best <= 60.5f) {
            return best;
        }

        Window w = a.getWindow();
        try {
            WindowManager.LayoutParams lp = w.getAttributes();
            // preferredDisplayModeId 指向具体那个高刷模式，
            // preferredRefreshRate 是兜底（有些设备不暴露 mode id）
            lp.preferredRefreshRate = best;
            lp.preferredDisplayModeId = bestMode;
            w.setAttributes(lp);
        } catch (Throwable ignored) {
        }
        return best;
    }

    /** 用于设置页显示「本机 120Hz」这类说明 */
    public static String label(Activity a) {
        float hz = apply(a);
        if (hz <= 0f) {
            return "—";
        }
        return (hz == Math.round(hz) ? String.valueOf((int) hz) : String.format("%.1f", hz)) + "Hz";
    }
}
