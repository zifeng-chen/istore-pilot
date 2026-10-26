package com.chaof.istoreos;

import android.app.Application;

import com.chaof.istoreos.util.Theme;

/**
 * 进程启动第一站：把用户选的外观定下来。
 *
 * <p>放在 Application 而不是 Activity，是因为从通知、最近任务、深链直接
 * 拉起某个页面时可能不经过 MainActivity，那里设就会闪一帧浅色再变深色。
 */
public class App extends Application {

    @Override
    public void onCreate() {
        super.onCreate();
        Theme.apply(this);
    }
}
