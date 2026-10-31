#pragma once

#include "MotionPass.h"
#include "../fsr/Fsr3Backend.h"
#include "../fsr/Fsr1Constants.h"

namespace RhineRender {

/** 唯一场景的跨平台 AA/FSR；只管理后处理，不持有另一套场景或材质。 */
class ScenePostProcess : public SceneResources {
  public:
    explicit ScenePostProcess(QRhi *device) : SceneResources(device) {
    }
    QSize renderSize(QSize display) const;
    int samples() const;
    bool temporal() const;
    bool needsMotion() const;
    /**
     * 目标分配口径：只看"配置"里会不会产生运动矢量消费者（AA 模式 + FG 开关），
     * 不看 FSR 运行期是否可用。
     *
     * 为什么不复用 needsMotion()：消费侧要回答的是"这一帧算不算"，所以要看运行期能力；
     * 分配侧要回答的是"将来会不会有人读"，只能看配置。若分配也看能力，FSR 前几帧才
     * 探测出可用时会多一次整帧目标重建（附件出现/消失），白白抖一帧。
     */
    bool motionConfigured() const;
    bool active() const;
    void prepare(QSize render, QSize display, const QJsonObject &frame);
    QRhiRenderTarget *inputTarget() const {
        return m_input.target;
    }
    void resolve(QRhiCommandBuffer *commands, QRhiRenderTarget *destination,
                 const RhineFg::FrameInputs &motion);
    quint64 bindingCreations = 0;
    quint64 drawCalls = 0;

  private:
    struct Target {
        QRhiTexture *texture = nullptr;
        QRhiTextureRenderTarget *target = nullptr;
    };
    Target target(QSize size, QRhiTexture::Format format, QRhiTexture::Flags flags = {});
    void quad(QRhiCommandBuffer *commands, const QString &kind, QRhiRenderTarget *destination,
              const QList<QRhiTexture *> &textures);
    void fsrQuad(QRhiCommandBuffer *commands, const QString &kind, QRhiRenderTarget *destination,
                 QRhiTexture *source, const Fsr1Con &constants);
    /** RHINE_POST_PROBE 下按“路径切换”打一次日志；未开启时只有一次静态布尔判断。 */
    void probe(const char *path, const char *detail);
    QString m_mode;
    QSize m_renderSize;
    QSize m_displaySize;
    Target m_input;
    Target m_output;
    Target m_history[2];
    int m_historyIndex = 0;
    bool m_historyValid = false;
    // 上一次写入 RHINE_FSR_ENGINE 的值：值只由“FSR3 是否可用”决定，不必每帧 qputenv。
    QByteArray m_fsrEngine;
    // RHINE_POST_PROBE 下上一次打印的路径标签，避免同一路径每帧刷屏。
    QString m_probePath;
    QRhiBuffer *m_globals = nullptr;
    QRhiBuffer *m_constants = nullptr;
    QRhiBuffer *m_rcasConstants = nullptr;
    QRhiSampler *m_sampler = nullptr;
    QHash<QString, QRhiShaderResourceBindings *> m_bindings;
    QHash<QString, QRhiGraphicsPipeline *> m_pipelines;
    std::unique_ptr<Fsr3Backend> m_fsr;
    QElapsedTimer m_clock;
};
} // namespace RhineRender
