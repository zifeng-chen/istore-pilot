package com.chaof.istoreos.util;

import android.content.Context;
import android.content.SharedPreferences;

import androidx.appcompat.app.AppCompatDelegate;

/**
 * 外观：跟随系统 / 浅色 / 深色。
 *
 * <p>存 SharedPreferences 而不是静态变量，进程被杀后设置还在。
 * 相对系统级 AppCompatDelegate 用 setDefaultNightMode 全局生效，
 * 切换后 AppCompat 会自动重建 Activity，savedInstanceState 里带着当前页签，
 * 所以切主题不会把用户弹回首页。
 */
public final class Theme {

    public static final int SYSTEM = -1;
    public static final int LIGHT = 0;
    public static final int DARK = 1;

    private static final String FILE = "istore";
    private static final String KEY = "appearance";

    /** 外观选项的显示名，顺序与 {@link #NAMES} 对应 */
    public static final int[] MODES = {SYSTEM, LIGHT, DARK};
    public static final String[] NAMES = {"跟随系统", "浅色", "深色"};

    private Theme() {
    }

    private static SharedPreferences prefs(Context c) {
        return c.getApplicationContext().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    public static int get(Context c) {
        return prefs(c).getInt(KEY, SYSTEM);
    }

    public static void set(Context c, int mode) {
        prefs(c).edit().putInt(KEY, mode).apply();
    }

    public static String name(Context c) {
        return name(get(c));
    }

    public static String name(int mode) {
        for (int i = 0; i < MODES.length; i++) {
            if (MODES[i] == mode) {
                return NAMES[i];
            }
        }
        return NAMES[0];
    }

    public static int index(int mode) {
        for (int i = 0; i < MODES.length; i++) {
            if (MODES[i] == mode) {
                return i;
            }
        }
        return 0;
    }

    /** 在 setContentView 之前调用，避免先按旧主题画一帧再闪一下 */
    public static void apply(Context c) {
        int mode = get(c);
        int night = mode == LIGHT
                ? AppCompatDelegate.MODE_NIGHT_NO
                : mode == DARK
                ? AppCompatDelegate.MODE_NIGHT_YES
                : AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM;
        if (AppCompatDelegate.getDefaultNightMode() != night) {
            AppCompatDelegate.setDefaultNightMode(night);
        }
    }

    /** 设置并立即生效（AppCompat 会重建当前 Activity） */
    public static void applyMode(Context c, int mode) {
        set(c, mode);
        AppCompatDelegate.setDefaultNightMode(
                mode == LIGHT ? AppCompatDelegate.MODE_NIGHT_NO
                        : mode == DARK ? AppCompatDelegate.MODE_NIGHT_YES
                        : AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM);
    }
}
