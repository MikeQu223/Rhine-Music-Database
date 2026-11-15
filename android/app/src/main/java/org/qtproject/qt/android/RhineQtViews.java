package org.qtproject.qt.android;

import android.content.Context;
import android.view.View;

/**
 * Kotlin 侧的取用入口（PARITY QT-OVERLAY-128）。
 *
 * Kotlin 拒绝把"父类是包内可见类"的 Java 类型放进自己的签名——它会尝试解析
 * org.qtproject.qt.android.QtView 并报无法访问。所以创建动作收成一个返回 {@link View}
 * 的静态方法：Kotlin 只看见 View，构造细节留在 Java 的同一个包里。
 */
public final class RhineQtViews {
    private RhineQtViews() {}

    /** 创建 Qt 场景视图；首次调用会加载 Qt 运行时并进入本库 main()。 */
    public static View create(Context context) {
        return new RhineQtView(context);
    }
}
