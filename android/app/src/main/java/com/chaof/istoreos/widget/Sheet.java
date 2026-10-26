package com.chaof.istoreos.widget;

import android.app.Dialog;
import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.content.res.ColorStateList;
import android.text.InputType;
import android.text.method.PasswordTransformationMethod;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.appcompat.app.AppCompatDialog;
import androidx.core.content.ContextCompat;

import com.chaof.istoreos.R;
import com.chaof.istoreos.util.Ui;

/**
 * 统一样式的底部弹层（bottom sheet），替代系统 AlertDialog。
 *
 * 系统 AlertDialog 的问题是：标题左对齐、正文和按钮混在一起、圆角受厂商魔改，
 * 在 ColorOS / HyperOS 上还会变成完全不同的样子。这里全部自绘：
 *
 *   拖拽条 → 标题（居中）→ 说明 → 自定义内容 → 按钮组 → 独立取消
 *
 * 所有弹窗走这一个入口，改一处样式全局生效。四种形态覆盖现有全部场景：
 *   message()  单向告知（体检结果、操作回执）
 *   confirm()  二次确认，危险操作用红色实心按钮
 *   actions()  多个可选操作
 *   choose()   单选（主题、节点、口径切换），选中项右侧打勾
 *   input()    一到多个文本字段（改密码、填 PPPoE 账号）
 */
public final class Sheet {

    public interface OnPick {
        void onPick(int index);
    }

    public interface OnSubmit {
        /** values 与传入的字段一一对应；返回 true 表示关闭弹层 */
        boolean onSubmit(String[] values);
    }

    private Sheet() {
    }

    // ---------------------------------------------------------------- 对外形态

    /** 单向告知：只有一行「知道了」 */
    public static Dialog message(Context c, String title, CharSequence body) {
        return message(c, title, body, "知道了");
    }

    public static Dialog message(Context c, String title, CharSequence body, String okText) {
        Builder b = new Builder(c);
        b.title(title);
        if (body != null && body.length() > 0) {
            b.body(body.toString());
        }
        b.primary(okText, false, null);
        return b.show();
    }

    /** 二次确认：取消 + 主按钮，danger=true 时主按钮是红色实心 */
    public static Dialog confirm(Context c, String title, CharSequence body,
                                 String okText, boolean danger, Runnable onOk) {
        Builder b = new Builder(c);
        b.title(title);
        if (body != null && body.length() > 0) {
            b.body(body.toString());
        }
        b.cancel("取消");
        b.primary(okText, danger, (dd, w) -> {
            // 一定先关弹层再执行动作：primary() 只要传了监听就不会自动 dismiss，
            // 之前确认框点完「删除」还杵在原地，看起来像没生效
            b.dismiss();
            if (onOk != null) {
                onOk.run();
            }
        });
        return b.show();
    }

    /** 多个操作：每行一个，点击后关闭 */
    public static Dialog actions(Context c, String title, CharSequence body,
                                 String[] items, OnPick onPick) {
        Builder b = new Builder(c);
        b.title(title);
        if (body != null && body.length() > 0) {
            b.body(body.toString());
        }
        for (int i = 0; i < items.length; i++) {
            final int idx = i;
            b.row(items[i], false, false, v -> {
                b.dismiss();
                if (onPick != null) {
                    onPick.onPick(idx);
                }
            });
        }
        b.cancel("取消");
        return b.show();
    }

    /** 单选：右侧打勾，选中后立刻回调并关闭 */
    public static Dialog choose(Context c, String title, String[] items, int selected,
                                OnPick onPick) {
        Builder b = new Builder(c);
        b.title(title);
        for (int i = 0; i < items.length; i++) {
            final int idx = i;
            b.row(items[i], false, i == selected, v -> {
                b.dismiss();
                if (onPick != null) {
                    onPick.onPick(idx);
                }
            });
        }
        b.cancel("取消");
        return b.show();
    }

    /**
     * 文本输入。fields 为「标签:提示语:初值」三元组，用 | 分隔：
     * <pre>input(c, "接入方式", "PPPoE", new String[]{"账号:手机号/宽带账号:", "密码:••••••:xxx"}, ...)</pre>
     * 标签里带 password 关键字时按密码框渲染（掩码 + 可切换显示）。
     */
    public static Dialog input(Context c, String title, CharSequence body,
                               String[] fields, String okText, OnSubmit onSubmit) {
        Builder b = new Builder(c);
        b.title(title);
        if (body != null && body.length() > 0) {
            b.body(body.toString());
        }
        EditText[] boxes = new EditText[fields.length];
        for (int i = 0; i < fields.length; i++) {
            String[] parts = fields[i].split(":", 3);
            String label = parts.length > 0 ? parts[0] : "";
            String hint = parts.length > 1 ? parts[1] : "";
            String value = parts.length > 2 ? parts[2] : "";
            boxes[i] = b.field(label, hint, value, label.contains("密码"));
        }
        b.cancel("取消");
        b.primary(okText, false, (dd, w) -> {
            String[] values = new String[boxes.length];
            for (int i = 0; i < boxes.length; i++) {
                values[i] = boxes[i].getText().toString().trim();
            }
            if (onSubmit == null || onSubmit.onSubmit(values)) {
                b.dismiss();
            }
        });
        return b.show();
    }

    /** 完全自定义内容：调用方自己往返回的 Builder 里塞 View */
    public static Builder custom(Context c, String title) {
        Builder b = new Builder(c);
        b.title(title);
        return b;
    }

    // ---------------------------------------------------------------- 构建器

    public static final class Builder {

        private final Context c;
        private final LinearLayout root;
        private final LinearLayout stack;
        private final LinearLayout rows;
        private final LinearLayout buttonBox;
        private AppCompatDialog dialog;
        private int buttonCount = 0;

        public Builder(Context c) {
            this.c = c;

            root = new LinearLayout(c);
            root.setOrientation(LinearLayout.VERTICAL);
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(ContextCompat.getColor(c, R.color.surface));
            bg.setCornerRadius(Ui.dp(c, 28));
            bg.setStroke(Math.max(1, Ui.dp(c, 0.7f)),
                    ContextCompat.getColor(c, R.color.glass_stroke));
            root.setBackground(bg);
            int pad = Ui.dp(c, 4);
            root.setPadding(pad, Ui.dp(c, 6), pad, pad);

            // 拖拽条：告诉用户「这是可以往下甩掉的」
            FrameLayout grab = new FrameLayout(c);
            View bar = new View(c);
            GradientDrawable gb = new GradientDrawable();
            gb.setCornerRadius(Ui.dp(c, 3));
            gb.setColor(ContextCompat.getColor(c, R.color.track));
            bar.setBackground(gb);
            FrameLayout.LayoutParams blp = new FrameLayout.LayoutParams(
                    Ui.dp(c, 40), Ui.dp(c, 4));
            blp.gravity = Gravity.CENTER;
            blp.topMargin = Ui.dp(c, 6);
            grab.addView(bar, blp);
            root.addView(grab, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(c, 18)));

            ScrollView scroller = new ScrollView(c);
            scroller.setOverScrollMode(View.OVER_SCROLL_NEVER);
            // 内容超过屏幕 70% 才滚动，正常弹窗不出现滚动条
            scroller.setFillViewport(false);

            stack = new LinearLayout(c);
            stack.setOrientation(LinearLayout.VERTICAL);
            stack.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), Ui.dp(c, 8));
            scroller.addView(stack, new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            root.addView(scroller, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

            rows = new LinearLayout(c);
            rows.setOrientation(LinearLayout.VERTICAL);
            rows.setPadding(Ui.dp(c, 8), 0, Ui.dp(c, 8), 0);
            // 这里**不能**直接 stack.addView(rows)。
            // 构造器先跑、title()/body() 后跑，如果提前挂上去，
            // 标题和说明会被追加到列表行后面 —— 弹层里出现「选项在上面、
            // 标题在下面」的错位。改成第一次加 row 时再挂，顺序自然正确。

            buttonBox = new LinearLayout(c);
            buttonBox.setOrientation(LinearLayout.VERTICAL);
            buttonBox.setPadding(Ui.dp(c, 12), Ui.dp(c, 4), Ui.dp(c, 12), 0);
            root.addView(buttonBox);
        }

        public Builder title(String text) {
            if (text == null || text.isEmpty()) {
                return this;
            }
            TextView t = new TextView(c);
            t.setText(text);
            t.setTextSize(17f);
            t.setTextColor(ContextCompat.getColor(c, R.color.text_primary));
            t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            t.setGravity(Gravity.CENTER);
            t.setIncludeFontPadding(false);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.topMargin = Ui.dp(c, 10);
            lp.bottomMargin = Ui.dp(c, 6);
            stack.addView(t, lp);
            return this;
        }

        public Builder body(String text) {
            return body(text, false);
        }

        /**
         * left=true 时左对齐。
         * 列表、命令输出这类多行内容居中排会让人一眼找不到行首，
         * 而一两句说明文字居中是好看的 —— 所以默认居中，需要时显式指定。
         */
        public Builder body(String text, boolean left) {
            TextView t = new TextView(c);
            t.setText(text);
            t.setTextSize(left ? 12.5f : 13.5f);
            if (left) {
                t.setTypeface(Typeface.MONOSPACE);
            }
            t.setTextColor(ContextCompat.getColor(c, R.color.text_secondary));
            t.setLineSpacing(Ui.dp(c, 3), 1f);
            t.setGravity(left ? Gravity.START : Gravity.CENTER);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.bottomMargin = Ui.dp(c, 14);
            stack.addView(t, lp);
            return this;
        }

        /** 左对齐正文的简写，用于日志、软件包列表这类文本 */
        public Builder bodyLeft(String text) {
            return body(text, true);
        }

        /** 任意自定义 View，放在说明下面 */
        public Builder content(View v) {
            stack.addView(v);
            return this;
        }

        /**
         * 列表行。checked 为 true 时右侧显示勾号（单选）；
         * 放进 rows 容器而不是 stack，是为了左右留白更小、行更宽。
         */
        public Builder row(String text, boolean danger, boolean checked, View.OnClickListener l) {
            LinearLayout line = new LinearLayout(c);
            line.setOrientation(LinearLayout.HORIZONTAL);
            line.setGravity(Gravity.CENTER_VERTICAL);
            line.setMinimumHeight(Ui.dp(c, 52));
            int px = Ui.dp(c, 10);
            line.setPadding(px, Ui.dp(c, 14), px, Ui.dp(c, 14));
            line.setClickable(true);
            line.setFocusable(true);

            GradientDrawable shape = new GradientDrawable();
            shape.setCornerRadius(Ui.dp(c, 16));
            shape.setColor(Color.TRANSPARENT);
            line.setBackground(new RippleDrawable(
                    ColorStateList.valueOf(ContextCompat.getColor(c, R.color.ripple)),
                    shape, null));

            TextView t = new TextView(c);
            t.setText(text);
            t.setTextSize(15.5f);
            t.setTextColor(ContextCompat.getColor(c,
                    danger ? R.color.danger : R.color.text_primary));
            t.setGravity(danger ? Gravity.CENTER : Gravity.CENTER_VERTICAL);
            line.addView(t, new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

            if (checked) {
                TextView tick = new TextView(c);
                tick.setText("\u2713");
                tick.setTextSize(16f);
                tick.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
                tick.setTextColor(ContextCompat.getColor(c, R.color.primary));
                line.addView(tick);
            }
            if (l != null) {
                line.setOnClickListener(l);
            }
            // 第一次用到时才把列表容器挂进 stack：此时标题、说明都已经加过了，
            // 顺序才是「标题 → 说明 → 选项」
            if (rows.getParent() == null) {
                stack.addView(rows);
            }
            rows.addView(line, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            return this;
        }

        /** 输入框：上面小标签，下面圆角输入区 */
        public EditText field(String label, String hint, String value, boolean secret) {
            if (label != null && !label.isEmpty()) {
                TextView t = new TextView(c);
                t.setText(label);
                t.setTextSize(12f);
                t.setTextColor(ContextCompat.getColor(c, R.color.text_secondary));
                t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                lp.topMargin = Ui.dp(c, 10);
                lp.bottomMargin = Ui.dp(c, 6);
                lp.leftMargin = Ui.dp(c, 4);
                stack.addView(t, lp);
            }

            EditText e = new EditText(c);
            e.setTextSize(15.5f);
            e.setTextColor(ContextCompat.getColor(c, R.color.text_primary));
            e.setHintTextColor(ContextCompat.getColor(c, R.color.text_tertiary));
            e.setHint(hint == null ? "" : hint);
            if (value != null && !value.isEmpty()) {
                e.setText(value);
                e.setSelection(value.length());
            }
            e.setSingleLine(true);
            e.setIncludeFontPadding(false);
            e.setPadding(Ui.dp(c, 14), Ui.dp(c, 13), Ui.dp(c, 14), Ui.dp(c, 13));
            if (secret) {
                e.setInputType(InputType.TYPE_CLASS_TEXT
                        | InputType.TYPE_TEXT_VARIATION_PASSWORD);
                e.setTransformationMethod(PasswordTransformationMethod.getInstance());
            } else {
                e.setInputType(InputType.TYPE_CLASS_TEXT);
            }
            GradientDrawable bg = new GradientDrawable();
            bg.setCornerRadius(Ui.dp(c, 14));
            bg.setColor(ContextCompat.getColor(c, R.color.surface_hi));
            bg.setStroke(Math.max(1, Ui.dp(c, 0.7f)),
                    ContextCompat.getColor(c, R.color.glass_stroke));
            e.setBackground(bg);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.bottomMargin = Ui.dp(c, 4);
            stack.addView(e, lp);
            return e;
        }

        /** 主按钮（实心胶囊）。危险操作传 danger=true 用红色 */
        public Builder primary(String text, boolean danger,
                               android.content.DialogInterface.OnClickListener l) {
            TextView b = button(text,
                    danger ? R.color.danger : R.color.primary,
                    danger ? R.color.on_primary : R.color.on_primary, true);
            b.setOnClickListener(v -> {
                if (l != null) {
                    l.onClick(dialog, 0);
                } else {
                    dismiss();
                }
            });
            return this;
        }

        /** 取消按钮（灰底胶囊） */
        public Builder cancel(String text) {
            TextView b = button(text, R.color.surface_hi, R.color.text_primary, false);
            b.setOnClickListener(v -> dismiss());
            return this;
        }

        private TextView button(String text, int bgRes, int fgRes, boolean filled) {
            TextView t = new TextView(c);
            t.setText(text);
            t.setTextSize(16f);
            t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            t.setGravity(Gravity.CENTER);
            t.setTextColor(ContextCompat.getColor(c, fgRes));
            t.setPadding(0, Ui.dp(c, 15), 0, Ui.dp(c, 15));

            GradientDrawable shape = new GradientDrawable();
            shape.setCornerRadius(Ui.dp(c, 16));
            if (filled) {
                shape.setColor(ContextCompat.getColor(c, bgRes));
            } else {
                shape.setColor(ContextCompat.getColor(c, R.color.surface_hi));
            }
            t.setBackground(new RippleDrawable(
                    ColorStateList.valueOf(filled ? 0x33FFFFFF
                            : ContextCompat.getColor(c, R.color.ripple)), shape, shape));

            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.topMargin = Ui.dp(c, buttonCount == 0 ? 4 : 8);
            buttonBox.addView(t, lp);
            buttonCount++;
            return t;
        }

        public void dismiss() {
            if (dialog != null && dialog.isShowing()) {
                dialog.dismiss();
            }
        }

        public Dialog show() {
            // 匿名子类只为一件事：弹层里的输入框，点空白也要能收键盘。
            // Dialog 有自己的 window，Activity 的 dispatchTouchEvent 管不到，
            // 必须在这一层再拦一次。
            dialog = new AppCompatDialog(c, R.style.SheetDialog) {
                @Override
                public boolean dispatchTouchEvent(MotionEvent ev) {
                    Ui.tapOutsideDismissKeyboard(getWindow() == null ? null : getWindow().getDecorView(),
                            getCurrentFocus(), ev);
                    return super.dispatchTouchEvent(ev);
                }
            };
            dialog.setCanceledOnTouchOutside(true);

            // 外层留边距：让圆角浮起来，而不是四条边贴着屏幕
            FrameLayout shell = new FrameLayout(c);
            shell.setPadding(Ui.dp(c, 10), 0, Ui.dp(c, 10), Ui.dp(c, 24));
            shell.setClipToOutline(false);
            shell.addView(root, new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT));
            dialog.setContentView(shell);

            Window w = dialog.getWindow();
            if (w != null) {
                w.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
                w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT);
                w.setGravity(Gravity.BOTTOM);
                w.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
                WindowManager.LayoutParams lp = w.getAttributes();
                lp.dimAmount = 0.45f;
                w.setAttributes(lp);
                w.setWindowAnimations(R.style.SheetAnim);
            }

            dialog.show();
            return dialog;
        }
    }
}
