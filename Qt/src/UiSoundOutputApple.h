#pragma once

#include <QByteArray>
#include <memory>

class UiSoundOutputApple {
  public:
    UiSoundOutputApple();
    ~UiSoundOutputApple();
    void load(const QByteArray &wave);
    void play();
    void stop();

  private:
    struct State;
    std::unique_ptr<State> m_state;
};
