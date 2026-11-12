#pragma once

#include <QtTypes>
#include <atomic>
#include <memory>

class QUrl;
struct AppleTransitionPlan;
#ifdef __OBJC__
@class AVAsset;
#endif

/** 一条原速播放的音轨，开头已保音高对拍，后续接回源音轨。 */
class AppleTransitionAudio {
  public:
    static std::shared_ptr<const AppleTransitionAudio>
    render(const QUrl &source, const AppleTransitionPlan &plan, const std::atomic_bool &cancelled);
    ~AppleTransitionAudio();

    double sourceMs(double playbackMs) const;
    double playbackMs(double sourceMs) const;
    double tempo(double playbackMs) const;
    double rampProgress(double playbackMs) const;
    double restoredAtMs() const;

#ifdef __OBJC__
    AVAsset *asset() const;
    AVAsset *sourceAsset() const;
#endif

  private:
    AppleTransitionAudio();
    struct Data;
    std::unique_ptr<Data> data;
};
