package com.chaof.istoreos.core;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * 连接会话：服务器地址 + 令牌。
 *
 * 令牌是 Agent 用 HMAC 自签的，有效期默认 7 天，
 * 所以本地只需要存 token 和过期时间，不必存密码。
 */
public final class Session {

    private static final String PREF = "istore_session";
    private static final String K_BASE = "base";
    private static final String K_TOKEN = "token";
    private static final String K_EXP = "expires";
    private static final String K_USER = "last_user";

    /** 出厂默认地址：路由器上的 Agent 端口 */
    public static final String DEFAULT_BASE = "http://192.168.100.1:8443";

    private Session() {
    }

    private static SharedPreferences sp(Context c) {
        return c.getApplicationContext().getSharedPreferences(PREF, Context.MODE_PRIVATE);
    }

    public static String base(Context c) {
        String v = sp(c).getString(K_BASE, "");
        return v == null || v.isEmpty() ? DEFAULT_BASE : v;
    }

    public static void setBase(Context c, String raw) {
        sp(c).edit().putString(K_BASE, normalize(raw)).apply();
    }

    public static String token(Context c) {
        String v = sp(c).getString(K_TOKEN, "");
        return v == null ? "" : v;
    }

    public static long expiresAt(Context c) {
        return sp(c).getLong(K_EXP, 0L);
    }

    public static String lastUser(Context c) {
        String v = sp(c).getString(K_USER, "");
        return v == null ? "" : v;
    }

    public static void saveToken(Context c, String token, long expiresAt, String user) {
        sp(c).edit()
                .putString(K_TOKEN, token)
                .putLong(K_EXP, expiresAt)
                .putString(K_USER, user == null ? "" : user)
                .apply();
    }

    /** 令牌还有效（留 2 分钟余量，避免刚好卡在边界上） */
    public static boolean tokenValid(Context c) {
        return !token(c).isEmpty() && expiresAt(c) > System.currentTimeMillis() / 1000L + 120;
    }

    /** 地址和令牌都齐了，可以直接进主界面 */
    public static boolean ready(Context c) {
        return tokenValid(c) && !base(c).isEmpty();
    }

    public static void logout(Context c) {
        sp(c).edit().remove(K_TOKEN).remove(K_EXP).apply();
    }

    /**
     * 把用户随手输入的地址整理成可用的 base url。
     * 支持：192.168.100.1 / 192.168.100.1:8443 / http://xxx / 带路径的域名
     */
    public static String normalize(String raw) {
        String v = raw == null ? "" : raw.trim();
        if (v.isEmpty()) {
            return DEFAULT_BASE;
        }
        if (!v.startsWith("http://") && !v.startsWith("https://")) {
            v = "http://" + v;
        }
        while (v.endsWith("/")) {
            v = v.substring(0, v.length() - 1);
        }
        // 裸 IP / 裸域名没写端口时补默认端口
        String afterScheme = v.substring(v.indexOf("://") + 3);
        if (!afterScheme.contains(":") && !afterScheme.contains("/")) {
            v = v + ":8443";
        }
        return v;
    }
}
