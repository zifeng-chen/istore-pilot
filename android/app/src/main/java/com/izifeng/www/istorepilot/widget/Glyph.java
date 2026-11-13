package com.izifeng.www.istorepilot.widget;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.view.View;

import androidx.core.graphics.PathParser;

import com.izifeng.www.istorepilot.util.Ui;

/**
 * 单色线性图标。
 *
 * 图形来自 design/icons（iStore Pilot SVG Icon Library，24×24 / 2px 描边 /
 * 圆头端点），由 scripts/gen_icons.py 转成 path data。这里只做三件事：
 * 解析一次、按控件尺寸缩放、用调用方给的颜色描边。
 *
 * 为什么不在 res/drawable 里放 76 个 vector：
 *  - 每个图标要跟着主题色 / 危险色 / hero 白色变，xml 得逐个 tint；
 *  - 列表滚动时每次 new VectorDrawable 都有开销，这里 Path 是静态缓存的；
 *  - 设计稿改图只改 SVG，重跑脚本，Java 侧不用动。
 */
public final class Glyph extends View {

    /** 24×24 设计稿里的一格 */
    private static final float GRID = 24f;

    // ---------------------------------------------------------------- 图标名
    // 常量名与 design/icons 的文件名一一对应（kebab-case → UPPER_SNAKE）
    public static final int CLEAR_CACHE = IconData.CLEAR_CACHE;
    public static final int LOGOUT = IconData.LOGOUT;
    public static final int SYSTEM_SETTINGS = IconData.SYSTEM_SETTINGS;
    public static final int THEME = IconData.THEME;
    public static final int ADD = IconData.ADD;
    public static final int BACK = IconData.BACK;
    public static final int CHEVRON_DOWN = IconData.CHEVRON_DOWN;
    public static final int CHEVRON_RIGHT = IconData.CHEVRON_RIGHT;
    public static final int COPY = IconData.COPY;
    public static final int DELETE = IconData.DELETE;
    public static final int DOWNLOAD_SPEED = IconData.DOWNLOAD_SPEED;
    public static final int DOWNLOAD = IconData.DOWNLOAD;
    public static final int EDIT = IconData.EDIT;
    public static final int EMPTY = IconData.EMPTY;
    public static final int EYE_OFF = IconData.EYE_OFF;
    public static final int EYE = IconData.EYE;
    public static final int LATENCY = IconData.LATENCY;
    public static final int LOCK = IconData.LOCK;
    public static final int MORE = IconData.MORE;
    public static final int PACKET_LOSS = IconData.PACKET_LOSS;
    public static final int PERMISSION = IconData.PERMISSION;
    public static final int REFRESH = IconData.REFRESH;
    public static final int SEARCH = IconData.SEARCH;
    public static final int SIGNAL = IconData.SIGNAL;
    public static final int SYNC = IconData.SYNC;
    public static final int TIMEOUT = IconData.TIMEOUT;
    public static final int UNLOCK = IconData.UNLOCK;
    public static final int UPLOAD_SPEED = IconData.UPLOAD_SPEED;
    public static final int UPLOAD = IconData.UPLOAD;
    public static final int WIFI_OFFLINE = IconData.WIFI_OFFLINE;
    public static final int CONFIG_FILE = IconData.CONFIG_FILE;
    public static final int LINK = IconData.LINK;
    public static final int LOGIN_USER = IconData.LOGIN_USER;
    public static final int PACKAGE = IconData.PACKAGE;
    public static final int SERVER_ADDRESS = IconData.SERVER_ADDRESS;
    public static final int TOGGLE = IconData.TOGGLE;
    public static final int ALL_HARDWARE = IconData.ALL_HARDWARE;
    public static final int DEVICE_INFO = IconData.DEVICE_INFO;
    public static final int MEMORY = IconData.MEMORY;
    public static final int PROCESSOR = IconData.PROCESSOR;
    public static final int SYSTEM_DISK = IconData.SYSTEM_DISK;
    public static final int BACKUP = IconData.BACKUP;
    public static final int PACKAGE_UPDATE = IconData.PACKAGE_UPDATE;
    public static final int POWER = IconData.POWER;
    public static final int RESTART_NETWORK = IconData.RESTART_NETWORK;
    public static final int RESTART_ROUTER = IconData.RESTART_ROUTER;
    public static final int SHUTDOWN = IconData.SHUTDOWN;
    public static final int SYSTEM_UPDATE = IconData.SYSTEM_UPDATE;
    public static final int UPGRADE_PROGRESS = IconData.UPGRADE_PROGRESS;
    public static final int APP_TRAFFIC = IconData.APP_TRAFFIC;
    public static final int BROADBAND = IconData.BROADBAND;
    public static final int DEVICES = IconData.DEVICES;
    public static final int ETHERNET_PORT = IconData.ETHERNET_PORT;
    public static final int INTERCEPT_LOGS = IconData.INTERCEPT_LOGS;
    public static final int INTERCEPT = IconData.INTERCEPT;
    public static final int NETWORK_SETTINGS = IconData.NETWORK_SETTINGS;
    public static final int PROXY = IconData.PROXY;
    public static final int RULES_REFRESH = IconData.RULES_REFRESH;
    public static final int SYSTEM_LOAD = IconData.SYSTEM_LOAD;
    public static final int INTERNET_STATUS = IconData.INTERNET_STATUS;
    public static final int IPV4 = IconData.IPV4;
    public static final int IPV6 = IconData.IPV6;
    public static final int LAN_GATEWAY = IconData.LAN_GATEWAY;
    public static final int NETWORK = IconData.NETWORK;
    public static final int WIFI_2_4G = IconData.WIFI_2_4G;
    public static final int WIFI_5G = IconData.WIFI_5G;
    public static final int WIRED_CONNECTION = IconData.WIRED_CONNECTION;
    public static final int APP_PASSWORD = IconData.APP_PASSWORD;
    public static final int ROUTER_PASSWORD = IconData.ROUTER_PASSWORD;
    public static final int SECURITY = IconData.SECURITY;
    public static final int STATUS_ERROR = IconData.STATUS_ERROR;
    public static final int STATUS_INFO = IconData.STATUS_INFO;
    public static final int STATUS_LOADING = IconData.STATUS_LOADING;
    public static final int STATUS_OFFLINE = IconData.STATUS_OFFLINE;
    public static final int STATUS_ONLINE = IconData.STATUS_ONLINE;
    public static final int STATUS_SUCCESS = IconData.STATUS_SUCCESS;
    public static final int STATUS_WARNING = IconData.STATUS_WARNING;
    public static final int CLOSE = IconData.CLOSE;

    // 旧名保留：万一有漏改的调用点，行为仍然是「能看的图标」，不会编译不过
    /** @deprecated 用 NETWORK */
    @Deprecated public static final int GLOBE = NETWORK;
    /** @deprecated 用 PACKAGE */
    @Deprecated public static final int BOX = PACKAGE;
    /** @deprecated 用 SECURITY */
    @Deprecated public static final int SHIELD = SECURITY;
    /** @deprecated 用 PROCESSOR */
    @Deprecated public static final int CHIP = PROCESSOR;
    /** @deprecated 用 INTERCEPT_LOGS */
    @Deprecated public static final int LIST = INTERCEPT_LOGS;
    /** @deprecated 用 RESTART_NETWORK */
    @Deprecated public static final int BOLT = RESTART_NETWORK;
    /** @deprecated 用 TIMEOUT */
    @Deprecated public static final int CLOCK = TIMEOUT;
    /** @deprecated 用 APP_PASSWORD */
    @Deprecated public static final int KEY = APP_PASSWORD;
    /** @deprecated 用 THEME */
    @Deprecated public static final int MOON = THEME;
    /** @deprecated 用 DELETE */
    @Deprecated public static final int TRASH = DELETE;
    /** @deprecated 用 STATUS_INFO */
    @Deprecated public static final int INFO = STATUS_INFO;
    /** @deprecated 用 THEME */
    @Deprecated public static final int PALETTE = THEME;

    /** 解析结果按图标缓存：一屏几十个图标只解析一次，滚动不再分配 */
    private static final Path[][] STROKE_CACHE = new Path[IconData.COUNT][];
    private static final Path[][] FILL_CACHE = new Path[IconData.COUNT][];

    private final Paint pen = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);

    private int kind = LINK;
    private float stroke = 2f;

    public Glyph(Context c) {
        super(c);
        pen.setStyle(Paint.Style.STROKE);
        pen.setStrokeCap(Paint.Cap.ROUND);
        pen.setStrokeJoin(Paint.Join.ROUND);
        fill.setStyle(Paint.Style.FILL);
        setColor(Ui.color(c, com.izifeng.www.istorepilot.R.color.text_secondary));
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

    @Override
    protected void onDraw(Canvas canvas) {
        float w = getWidth();
        float h = getHeight();
        if (w <= 0 || h <= 0 || kind < 0 || kind >= IconData.COUNT) {
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
        for (Path p : parse(IconData.STROKE[kind], STROKE_CACHE, kind)) {
            canvas.drawPath(p, pen);
        }
        for (Path p : parse(IconData.FILL[kind], FILL_CACHE, kind)) {
            canvas.drawPath(p, fill);
        }
        canvas.restore();
    }

    private static Path[] parse(String[] data, Path[][] cache, int index) {
        Path[] hit = cache[index];
        if (hit != null) {
            return hit;
        }
        Path[] out = new Path[data.length];
        for (int i = 0; i < data.length; i++) {
            Path p = PathParser.createPathFromPathData(data[i]);
            out[i] = p != null ? p : new Path();
        }
        cache[index] = out;
        return out;
    }
}
