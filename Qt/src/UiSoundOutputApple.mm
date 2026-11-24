#include "UiSoundOutputApple.h"
#import <AVFAudio/AVAudioPlayer.h>

struct UiSoundOutputApple::State {
    AVAudioPlayer *player = nil;
};

UiSoundOutputApple::UiSoundOutputApple() : m_state(std::make_unique<State>()) {
}

UiSoundOutputApple::~UiSoundOutputApple() {
    stop();
}

void UiSoundOutputApple::load(const QByteArray &wave) {
    @autoreleasepool {
        auto *data = [NSData dataWithBytes:wave.constData() length:NSUInteger(wave.size())];
        m_state->player = [[AVAudioPlayer alloc] initWithData:data error:nullptr];
    }
}

void UiSoundOutputApple::play() {
    @autoreleasepool {
        auto *player = m_state->player;
        if (!player) {
            return;
        }
        if (player.isPlaying) {
            [player stop];
        }
        player.currentTime = 0;
        [player play];
    }
}

void UiSoundOutputApple::stop() {
    @autoreleasepool {
        [m_state->player stop];
    }
}
