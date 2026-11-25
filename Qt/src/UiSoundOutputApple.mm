#include "UiSoundOutputApple.h"
#import <AVFAudio/AVAudioPlayer.h>
#include <vector>

struct UiSoundOutputApple::State {
    std::vector<AVAudioPlayer *> clips;
    AVAudioPlayer *active = nil;
};

UiSoundOutputApple::UiSoundOutputApple(size_t clipCount) : m_state(std::make_unique<State>()) {
    m_state->clips.resize(clipCount);
}

UiSoundOutputApple::~UiSoundOutputApple() {
    stop();
}

void UiSoundOutputApple::load(size_t index, const QByteArray &wave) {
    @autoreleasepool {
        auto *data = [NSData dataWithBytes:wave.constData() length:NSUInteger(wave.size())];
        m_state->clips[index] = [[AVAudioPlayer alloc] initWithData:data error:nullptr];
    }
}

void UiSoundOutputApple::play(size_t index) {
    @autoreleasepool {
        auto *player = m_state->clips[index];
        if (!player) {
            return;
        }
        if (m_state->active.isPlaying) {
            [m_state->active stop];
        }
        player.currentTime = 0;
        if ([player play]) {
            m_state->active = player;
        }
    }
}

void UiSoundOutputApple::stop() {
    @autoreleasepool {
        [m_state->active stop];
        m_state->active = nil;
    }
}
