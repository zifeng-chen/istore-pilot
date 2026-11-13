# Android 图标备份（2026-11-13）

替换为 iStore Pilot SVG Icon Library v1.0.1 之前的原始文件。

- `Glyph.java`：手绘 19 个图标（Canvas + Path）
- `drawable/ic_nav_*.xml`、`ic_back.xml`：底部页签与返回键的实心 Material 风格 vector

回滚方式：把本目录的文件按原路径覆盖回去，并删除
`widget/IconData.java` 与 `res/drawable/ic_nav_*` 里新生成的图标。
