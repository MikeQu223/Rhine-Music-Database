# Qt 的 Android Java 桥由 C++ 通过 JNI 按名字查找：QtNative / QtWindow / QtInputDelegate /
# QtLoader / QtEmbeddedDelegate / QtView.addQtWindow 等都没有可供 R8 追踪的静态引用。
# Qt6Android.jar 自身不带 consumer rules，release 的 R8 一旦重命名或裁剪这些成员，
# GetMethodID / GetStaticMethodID 就会落空，嵌入场景无法创建。
-keep class org.qtproject.qt.android.** { *; }
