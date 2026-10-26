package com.chaof.istoreos.ui;

/** 由 MainActivity 定时驱动刷新的页面实现它。 */
public interface Refreshable {

    /**
     * @param quiet true 表示后台静默刷新（不清空界面、不显示加载条）
     */
    void refresh(boolean quiet);

    /** 页面被切到前台 */
    void onShown();
}
