package com.izifeng.www.istorepilot.core;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

/**
 * 演示模式：把录制好的接口返回打进包里，不连路由器、不需要网络。
 *
 * 存在的理由只有一个 —— 应用商店审核。审核员没有你的路由器，打开 App 就
 * 停在登录页；有了这份数据，点「先看看演示」就能把五个页签完整看一遍。
 *
 * 两条硬规矩：
 *   1. 只读。写操作在 Api 层被拦掉并明确告知，不假装成功 ——
 *      假装成功会让审核员以为「禁网」真的生效了，反而更糟。
 *   2. 数据已脱敏。MAC / 内网地址 / 机场名 / 订阅链接 / 访问日志全部换过，
 *      生成脚本是 scripts/record_demo.py，随时可以重录。
 *
 * 数据的形状和真实接口完全一致（就是录下来的真机返回），页面上没有
 * 「演示专用分支」—— 少一套分支就少一处线上线下不一致的 bug。
 */
public final class Demo {

    private static final String PREF = "istore_session";
    private static final String K_DEMO = "demo_mode";
    private static final String ASSET = "demo.json";

    /** 演示模式下所有写操作统一回这句 */
    public static final String READ_ONLY = "演示模式只能浏览，这项操作需要连接真实路由器";

    /** 规范化 key → 接口返回。null 表示还没加载（不是「没数据」） */
    private static Map<String, JSONObject> routes;
    private static final List<String> keys = new ArrayList<>();

    private Demo() {
    }

    public static boolean isOn(Context c) {
        SharedPreferences sp = c.getApplicationContext()
                .getSharedPreferences(PREF, Context.MODE_PRIVATE);
        return sp.getBoolean(K_DEMO, false);
    }

    public static void setOn(Context c, boolean on) {
        c.getApplicationContext().getSharedPreferences(PREF, Context.MODE_PRIVATE)
                .edit().putBoolean(K_DEMO, on).apply();
    }

    /**
     * 取接口数据。没录到返回空对象 —— 界面用 J 的默认值兜底，
     * 不编假数据（字段对不上比空着更容易露馅）。
     */
    public static JSONObject data(Context c, String path) {
        ensure(c);
        if (routes == null) {
            return new JSONObject();
        }
        String key = key(path);
        JSONObject hit = routes.get(key);
        if (hit != null) {
            return hit;
        }
        // 前缀回退：带查询串的接口（devices/detail?mac=xx）只录了几台设备，
        // 其余设备拿同一条详情顶替
        String base = key(pathOf(path));
        for (String k : keys) {
            if (k.equals(base) || k.startsWith(base + "_")) {
                JSONObject v = routes.get(k);
                if (v != null) {
                    return v;
                }
            }
        }
        return new JSONObject();
    }

    /** 路径 + 查询串 → key。规则和 scripts/record_demo.py 的 _key 一致 */
    static String key(String path) {
        String src = path;
        while (src.startsWith("/")) {
            src = src.substring(1);
        }
        while (src.endsWith("/")) {
            src = src.substring(0, src.length() - 1);
        }
        StringBuilder sb = new StringBuilder(src.length());
        for (int i = 0; i < src.length(); i++) {
            char ch = src.charAt(i);
            boolean alnum = (ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z')
                    || (ch >= 'a' && ch <= 'z');
            sb.append(alnum ? ch : '_');
        }
        return sb.toString();
    }

    private static String pathOf(String path) {
        int q = path.indexOf('?');
        return q >= 0 ? path.substring(0, q) : path;
    }

    private static synchronized void ensure(Context c) {
        if (routes != null) {
            return;
        }
        routes = new HashMap<>();
        try (InputStream is = c.getApplicationContext().getAssets().open(ASSET)) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = is.read(buf)) > 0) {
                bos.write(buf, 0, n);
            }
            JSONObject doc = new JSONObject(new String(bos.toByteArray(), StandardCharsets.UTF_8));
            JSONObject rs = doc.optJSONObject("routes");
            if (rs == null) {
                return;
            }
            Iterator<String> it = rs.keys();
            while (it.hasNext()) {
                String k = it.next();
                JSONObject item = rs.optJSONObject(k);
                if (item != null) {
                    routes.put(k, item.optJSONObject("data"));
                    keys.add(k);
                }
            }
        } catch (Exception e) {
            // 读不到就当没有：登录页的入口会提示不可用，正常连接不受影响
            routes = null;
        }
    }
}
