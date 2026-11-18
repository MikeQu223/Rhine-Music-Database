#pragma once

#include <QString>
#include <QSize>
#include <memory>
#include <source_location>

class QCoreApplication;
class QQuickWindow;
class QRhi;
class QRhiResource;

/** 管理 Crashpad、挂起采样和独立报告进程；调试模式关闭时不注册任何全局钩子。 */
class CrashDiagnostics {
  public:
    CrashDiagnostics();
    ~CrashDiagnostics();
    bool start(QCoreApplication &application);
    void stop();
    static bool supported();
    static void clearHistory();
    static void attach(QQuickWindow *window);
    static void setGraphicsBackend(const QString &backend);
    static void setRenderContext(QRhi *rhi, QSize render, QSize display, const QString &mode);
    static void recordResource(QRhiResource *resource);

  private:
    void stopInternal(bool clearData);
    struct State;
    std::shared_ptr<State> m_state;
};

/** 只标记正在执行的原生渲染调用；退出作用域后恢复上层阶段，休眠不算挂起。 */
class CrashRenderScope {
  public:
    explicit CrashRenderScope(const char *stage,
                              std::source_location source = std::source_location::current());
    ~CrashRenderScope();
    CrashRenderScope(const CrashRenderScope &) = delete;
    CrashRenderScope &operator=(const CrashRenderScope &) = delete;

  private:
    void *m_slot = nullptr;
    const char *m_previousStage = nullptr;
    long long m_previousStartedMs = 0;
    std::source_location m_previousSource;
};
