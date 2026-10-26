package com.chaof.istoreos.core;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONException;
import org.json.JSONObject;

/**
 * 接口响应的本地快照。
 *
 * 这是「秒开」和「离线可看」的关键：界面先拿上一次的快照渲染，
 * 同时后台再请求真实数据，回来后原地替换。
 * 用户看到的是「立刻有东西」，而不是一个转圈的空白页。
 */
public final class Snap {

    private static final String PREF = "istore_snap";

    private Snap() {
    }

    private static SharedPreferences sp(Context c) {
        return c.getApplicationContext().getSharedPreferences(PREF, Context.MODE_PRIVATE);
    }

    public static void put(Context c, String key, JSONObject body) {
        if (body == null) {
            return;
        }
        sp(c).edit()
                .putString(key, body.toString())
                .putLong(key + "#ts", System.currentTimeMillis())
                .apply();
    }

    public static JSONObject get(Context c, String key) {
        String raw = sp(c).getString(key, null);
        if (raw == null || raw.isEmpty()) {
            return null;
        }
        try {
            return new JSONObject(raw);
        } catch (JSONException e) {
            return null;
        }
    }

    /** 快照距今多少秒，没有快照返回 -1 */
    public static long ageSeconds(Context c, String key) {
        long ts = sp(c).getLong(key + "#ts", 0L);
        if (ts <= 0L) {
            return -1L;
        }
        return (System.currentTimeMillis() - ts) / 1000L;
    }

    public static void clear(Context c) {
        sp(c).edit().clear().apply();
    }
}
