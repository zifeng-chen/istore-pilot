package com.izifeng.www.istorepilot.ui;

import android.content.Intent;
import android.os.Bundle;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;

import androidx.annotation.Nullable;

import com.izifeng.www.istorepilot.MainActivity;
import com.izifeng.www.istorepilot.R;
import com.izifeng.www.istorepilot.api.Api;
import com.izifeng.www.istorepilot.api.Cb;
import com.izifeng.www.istorepilot.core.Demo;
import com.izifeng.www.istorepilot.core.Session;
import com.google.android.material.button.MaterialButton;
import com.google.android.material.textfield.TextInputEditText;
import com.google.android.material.textfield.TextInputLayout;

import org.json.JSONObject;

import com.izifeng.www.istorepilot.util.Theme;
import com.izifeng.www.istorepilot.core.BaseActivity;

/** 登录：地址 + 密码换一个 7 天有效的令牌。 */
public class LoginActivity extends BaseActivity {

    private TextInputLayout tilHost;
    private TextInputLayout tilPwd;
    private TextInputEditText host;
    private TextInputEditText pwd;
    private MaterialButton btn;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_login);

        tilHost = findViewById(R.id.til_host);
        tilPwd = findViewById(R.id.til_pwd);
        host = findViewById(R.id.host);
        pwd = findViewById(R.id.pwd);
        btn = findViewById(R.id.btn_login);

        String saved = Session.base(this);
        host.setText(saved.replaceFirst("^https?://", ""));
        host.setSelection(host.getText() == null ? 0 : host.getText().length());

        btn.setOnClickListener(v -> submit());
        findViewById(R.id.help).setOnClickListener(v ->
                startActivity(new Intent(LoginActivity.this, HelpActivity.class)));
        findViewById(R.id.demo).setOnClickListener(v -> openDemo());
        pwd.setOnEditorActionListener((v, actionId, event) -> {
            if (actionId == EditorInfo.IME_ACTION_DONE
                    || (event != null && event.getKeyCode() == KeyEvent.KEYCODE_ENTER)) {
                submit();
                return true;
            }
            return false;
        });
    }

    /**
     * 进演示模式：不需要地址和密码，数据全部来自包内的示例。
     *
     * 演示态照样写一个「假令牌」：MainActivity 用 tokenValid 判断进不进主界面，
     * 真正的请求一个都不会发出去（Api 层先拦了）。
     */
    private void openDemo() {
        Demo.setOn(this, true);
        Session.setBase(this, "http://demo.local:8443");
        Session.saveToken(this, "demo-mode",
                System.currentTimeMillis() / 1000L + 365L * 86400L, "演示模式");
        startActivity(new Intent(LoginActivity.this, MainActivity.class));
        finish();
    }

    private void submit() {
        String h = host.getText() == null ? "" : host.getText().toString().trim();
        String p = pwd.getText() == null ? "" : pwd.getText().toString();

        if (h.isEmpty()) {
            tilHost.setError("填写路由器地址");
            return;
        }
        if (p.isEmpty()) {
            tilPwd.setError("填写密码");
            return;
        }
        tilHost.setError(null);
        tilPwd.setError(null);
        busy(true);

        Api.login(h, p, new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!body.optBoolean("ok", false)) {
                    fail(body.optString("error", "登录失败"));
                    return;
                }
                String token = body.optString("token", "");
                if (token.isEmpty()) {
                    fail("路由器没有返回令牌");
                    return;
                }
                Session.setBase(LoginActivity.this, h);
                Session.saveToken(LoginActivity.this, token,
                        body.optLong("expires_at", 0L), "admin");
                busy(false);
                startActivity(new Intent(LoginActivity.this, MainActivity.class));
                finish();
            }

            @Override
            public void onError(String message) {
                fail(message);
            }
        });
    }

    private void fail(String msg) {
        busy(false);
        tilPwd.setError(msg);
    }

    private void busy(boolean on) {
        btn.setEnabled(!on);
        btn.setText(on ? "连接中…" : "连接");
    }
}
