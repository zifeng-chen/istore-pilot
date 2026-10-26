package com.chaof.istoreos;

import android.os.Bundle;

import androidx.annotation.Nullable;

import com.chaof.istoreos.core.BaseActivity;
import com.chaof.istoreos.ui.AdblockFragment;
import com.chaof.istoreos.util.Theme;
import com.google.android.material.appbar.MaterialToolbar;

/**
 * 拦截配置（二级页）。一级页只留「拦了多少」和「接管开关」，
 * 链路图、体检、规则表、上游这些配置项都收到这里。
 */
public class SecurityAdblockActivity extends BaseActivity {

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_sub);

        MaterialToolbar bar = findViewById(R.id.toolbar);
        bar.setNavigationOnClickListener(v -> finish());

        if (savedInstanceState == null) {
            getSupportFragmentManager().beginTransaction()
                    .replace(R.id.container, new AdblockFragment(), "adblock")
                    .commit();
        }
    }
}
