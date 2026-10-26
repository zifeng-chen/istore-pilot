package com.chaof.istoreos.core;

import android.os.Bundle;
import android.view.MotionEvent;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.chaof.istoreos.util.Hz;
import com.chaof.istoreos.util.Ui;

/**
 * 所有页面的基类。
 *
 * 两件事：
 *   1. **点空白处收起键盘** —— 放在 dispatchTouchEvent 里而不是给每个可点控件挂监听，
 *      一个页面几十个可点元素，逐个挂既容易漏，也会把已有的点击回调搞乱。
 *   2. **请求高刷** —— 手机基本是 90/120/144Hz，窗口不主动申请就按 60Hz 合成，
 *      所有弹簧动画在 120Hz 屏上仍然是 60 帧。
 */
public class BaseActivity extends AppCompatActivity {

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Hz.apply(this);
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent ev) {
        Ui.tapOutsideDismissKeyboard(this, ev);
        return super.dispatchTouchEvent(ev);
    }
}
