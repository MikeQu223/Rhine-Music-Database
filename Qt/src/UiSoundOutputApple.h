#pragma once

#include <QByteArray>
#include <cstddef>
#include <memory>

class UiSoundOutputApple {
  public:
    explicit UiSoundOutputApple(size_t clipCount);
    ~UiSoundOutputApple();
    void load(size_t index, const QByteArray &wave);
    void play(size_t index);
    void stop();

  private:
    struct State;
    std::unique_ptr<State> m_state;
};
