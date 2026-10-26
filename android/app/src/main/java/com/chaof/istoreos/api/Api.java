package com.chaof.istoreos.api;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import com.chaof.istoreos.core.Session;
import com.chaof.istoreos.core.Snap;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.ConnectException;
import java.net.HttpURLConnection;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.net.UnknownHostException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import javax.net.ssl.SSLException;

/**
 * 路由器 Agent 的极简 HTTP 客户端。
 *
 * 用 HttpURLConnection + org.json，不引 OkHttp / Gson：
 * 包体小、没有传递依赖、构建不会因为镜像缺包而挂掉。
 */
public final class Api {

    private static final ExecutorService POOL = Executors.newFixedThreadPool(4);
    private static final Handler UI = new Handler(Looper.getMainLooper());

    private static volatile Runnable authFailHandler;

    private Api() {
    }

    /** 令牌失效时统一跳登录页 */
    public static void setAuthFailHandler(Runnable r) {
        authFailHandler = r;
    }

    public static void get(Context c, String path, Cb cb) {
        call(c, "GET", path, null, true, cb);
    }

    /** 不走缓存，用于「先登录再请求」这类必须实时的场景 */
    public static void getFresh(Context c, String path, Cb cb) {
        call(c, "GET", path, null, false, cb);
    }

    public static void post(Context c, String path, JSONObject body, Cb cb) {
        call(c, "POST", path, body, false, cb, 15000);
    }

    /**
     * 慢接口专用：opkg update / 订阅刷新这类动辄几十秒的操作，
     * 用默认 15 秒读超时会在服务端还在干活的时候先被客户端掐断。
     */
    public static void postSlow(Context c, String path, JSONObject body, Cb cb) {
        call(c, "POST", path, body, false, cb, 180000);
    }

    private static void call(Context c, String method, String path, JSONObject body,
                             boolean useCache, Cb cb) {
        call(c, method, path, body, useCache, cb, 15000);
    }

    private static void call(Context c, String method, String path, JSONObject body,
                             boolean useCache, Cb cb, int readTimeoutMs) {
        final Context app = c.getApplicationContext();
        final String base = Session.base(app);
        final String token = Session.token(app);

        // 第一步：立刻把本地快照吐出来，界面马上有内容
        if (useCache) {
            final JSONObject cached = Snap.get(app, path);
            if (cached != null) {
                UI.post(() -> cb.onData(cached, true));
            }
        }

        // 第二步：后台拿真实数据
        POOL.execute(() -> {
            try {
                JSONObject result = exec(base, token, method, path, body, readTimeoutMs);
                if (useCache) {
                    Snap.put(app, path, result);
                }
                UI.post(() -> cb.onData(result, false));
            } catch (ApiError e) {
                if (e.code == 401) {
                    Session.logout(app);
                    UI.post(() -> {
                        Runnable r = authFailHandler;
                        if (r != null) {
                            r.run();
                        }
                    });
                }
                UI.post(() -> cb.onError(e.getMessage()));
            } catch (Exception e) {
                UI.post(() -> cb.onError(friendly(e)));
            }
        });
    }

    /**
     * 登录。成功返回的 JSON 里有 token / expires_at，由调用方写入 Session。
     */
    public static void login(String base, String password, Cb cb) {
        POOL.execute(() -> {
            try {
                JSONObject body = new JSONObject();
                body.put("password", password);
                JSONObject result = exec(Session.normalize(base), "", "POST", "/api/v1/login", body);
                UI.post(() -> cb.onData(result, false));
            } catch (ApiError e) {
                UI.post(() -> cb.onError(e.getMessage()));
            } catch (Exception e) {
                UI.post(() -> cb.onError(friendly(e)));
            }
        });
    }

    /** 探活：不需要令牌，用来判断「地址是否通」 */
    public static void ping(String base, Cb cb) {
        POOL.execute(() -> {
            try {
                JSONObject result = exec(Session.normalize(base), "", "GET", "/api/v1/ping", null);
                UI.post(() -> cb.onData(result, false));
            } catch (ApiError e) {
                UI.post(() -> cb.onError(e.getMessage()));
            } catch (Exception e) {
                UI.post(() -> cb.onError(friendly(e)));
            }
        });
    }

    /**
     * 上传安装包。走「原始字节流 + X-Filename 头」，不用 multipart：
     * 路由器那边是边收边写盘，手机这边也不用把文件整个读进内存。
     *
     * 文件名放在头里而不是 URL 里，是因为 .ipk / .run 的名字可能带空格和中文。
     */
    public static void upload(Context c, android.net.Uri uri, Cb cb) {
        final Context app = c.getApplicationContext();
        final String base = Session.base(app);
        final String token = Session.token(app);

        POOL.execute(() -> {
            HttpURLConnection conn = null;
            try {
                String name = displayName(app, uri);
                long size = sizeOf(app, uri);
                if (size <= 0) {
                    throw new ApiError(0, "读不到文件大小，换一个文件管理器选试试");
                }
                URL url = new URL(base + "/api/v1/system/upload");
                conn = (HttpURLConnection) url.openConnection();
                conn.setRequestMethod("POST");
                conn.setConnectTimeout(8000);
                conn.setReadTimeout(300000);
                conn.setDoOutput(true);
                conn.setRequestProperty("Authorization", "Bearer " + token);
                conn.setRequestProperty("Content-Type", "application/octet-stream");
                conn.setRequestProperty("X-Filename",
                        java.net.URLEncoder.encode(name, "UTF-8"));
                conn.setFixedLengthStreamingMode(size);

                try (InputStream in = app.getContentResolver().openInputStream(uri);
                     OutputStream os = conn.getOutputStream()) {
                    if (in == null) {
                        throw new ApiError(0, "读不到这个文件");
                    }
                    byte[] buf = new byte[65536];
                    int n;
                    while ((n = in.read(buf)) != -1) {
                        os.write(buf, 0, n);
                    }
                    os.flush();
                }

                int code = conn.getResponseCode();
                InputStream in = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
                String text = in == null ? "" : readAll(in);
                if (code >= 400) {
                    throw new ApiError(code, extractError(text, code));
                }
                JSONObject result = text.isEmpty() ? new JSONObject() : new JSONObject(text);
                UI.post(() -> cb.onData(result, false));
            } catch (ApiError e) {
                UI.post(() -> cb.onError(e.getMessage()));
            } catch (Exception e) {
                UI.post(() -> cb.onError(friendly(e)));
            } finally {
                if (conn != null) {
                    conn.disconnect();
                }
            }
        });
    }

    private static String displayName(Context c, android.net.Uri uri) {
        try (android.database.Cursor cur = c.getContentResolver().query(
                uri, null, null, null, null)) {
            if (cur != null && cur.moveToFirst()) {
                int idx = cur.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME);
                if (idx >= 0) {
                    String name = cur.getString(idx);
                    if (name != null && !name.isEmpty()) {
                        return name;
                    }
                }
            }
        } catch (Exception ignored) {
            // 有些第三方文件管理器不给查，退回用路径最后一段
        }
        String last = uri.getLastPathSegment();
        return last == null || last.isEmpty() ? "upload.bin" : last;
    }

    private static long sizeOf(Context c, android.net.Uri uri) {
        try (android.database.Cursor cur = c.getContentResolver().query(
                uri, null, null, null, null)) {
            if (cur != null && cur.moveToFirst()) {
                int idx = cur.getColumnIndex(android.provider.OpenableColumns.SIZE);
                if (idx >= 0) {
                    return cur.getLong(idx);
                }
            }
        } catch (Exception ignored) {
            // 见上
        }
        return -1;
    }

    private static JSONObject exec(String base, String token, String method,
                                   String path, JSONObject body) throws ApiError {
        return exec(base, token, method, path, body, 15000);
    }

    private static JSONObject exec(String base, String token, String method,
                                   String path, JSONObject body, int readTimeoutMs) throws ApiError {
        HttpURLConnection conn = null;
        try {
            URL url = new URL(base + path);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod(method);
            conn.setConnectTimeout(6000);
            conn.setReadTimeout(readTimeoutMs);
            conn.setRequestProperty("Accept", "application/json");
            if (token != null && !token.isEmpty()) {
                conn.setRequestProperty("Authorization", "Bearer " + token);
            }
            if (body != null) {
                byte[] payload = body.toString().getBytes(StandardCharsets.UTF_8);
                conn.setDoOutput(true);
                conn.setFixedLengthStreamingMode(payload.length);
                conn.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                try (OutputStream os = conn.getOutputStream()) {
                    os.write(payload);
                    os.flush();
                }
            }

            int code = conn.getResponseCode();
            InputStream in = code >= 400 ? conn.getErrorStream() : conn.getInputStream();
            String text = in == null ? "" : readAll(in);
            if (code >= 400) {
                throw new ApiError(code, extractError(text, code));
            }
            if (text.isEmpty()) {
                return new JSONObject();
            }
            try {
                return new JSONObject(text);
            } catch (JSONException e) {
                throw new ApiError(0, "返回的不是有效数据，地址可能指错了地方");
            }
        } catch (ApiError e) {
            throw e;
        } catch (UnknownHostException e) {
            throw new ApiError(0, "找不到这个地址，检查 IP 或域名是否写对");
        } catch (SocketTimeoutException | ConnectException e) {
            throw new ApiError(0, "连不上路由器，确认手机和路由器在同一个网络");
        } catch (SSLException e) {
            throw new ApiError(0, "HTTPS 证书校验失败，改用 http 试试");
        } catch (IOException e) {
            throw new ApiError(0, friendly(e));
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }

    private static String readAll(InputStream in) throws IOException {
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) != -1) {
            bos.write(buf, 0, n);
        }
        return new String(bos.toByteArray(), StandardCharsets.UTF_8);
    }

    private static String extractError(String text, int code) {
        if (text != null && !text.isEmpty()) {
            try {
                String err = new JSONObject(text).optString("error", "");
                if (!err.isEmpty()) {
                    return err;
                }
            } catch (JSONException ignored) {
                // 不是 JSON 就走下面的兜底文案
            }
        }
        if (code == 401) {
            return "登录已过期，请重新登录";
        }
        if (code == 403) {
            return "密码错误或尝试过于频繁";
        }
        return "路由器返回了错误（HTTP " + code + "）";
    }

    private static String friendly(Exception e) {
        String msg = e.getMessage();
        return msg == null || msg.isEmpty() ? "网络请求失败" : msg;
    }

    /** 网络层错误，带 HTTP 状态码 */
    public static final class ApiError extends Exception {
        public final int code;

        ApiError(int code, String message) {
            super(message);
            this.code = code;
        }
    }
}
