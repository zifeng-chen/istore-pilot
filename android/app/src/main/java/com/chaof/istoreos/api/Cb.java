package com.chaof.istoreos.api;

import org.json.JSONObject;

/**
 * 接口回调。回调全部在主线程执行，界面里可以直接改 View。
 */
public abstract class Cb {

    /**
     * @param body      接口返回的 JSON
     * @param fromCache true 表示这是本地快照（可能已过期），false 表示刚从路由器回来
     */
    public abstract void onData(JSONObject body, boolean fromCache);

    /** 失败。已经用缓存渲染过时，调用方可以选择忽略这个错误。 */
    public void onError(String message) {
    }
}
