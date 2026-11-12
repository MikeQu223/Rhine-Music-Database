#pragma once

#include <QUrl>
#include <atomic>

enum class AppleTransitionPreparation {
    WaitingForPlayback,
    ResolvingSource,
    Accepted,
    SourceUnavailable,
    PlaybackUnavailable,
    Natural
};

struct AppleTransitionPlan {
    static constexpr qint64 searchWindowMs = 20000;

    enum class Kind { Original, Trim, Fade, BeatMatch };
    enum class Alignment { None, Beat, Bar };
    enum class Phase {
        Analyzing,
        Waiting,
        Loading,
        Seeking,
        Prerolling,
        Ready,
        Armed,
        Unavailable,
        Recovering
    };

    struct IncomingAnalysis {
        int tonic = -1;
        bool minor = false;
        double bpm = 0;
        qint64 firstBarMs = -1;
        int beatsPerBar = 0;
    };

    Kind kind = Kind::Original;
    qint64 outgoingMs = 0;
    qint64 incomingMs = 0;
    qint64 overlapMs = 0;
    double incomingRate = 1.0;
    IncomingAnalysis incomingAnalysis;
    Alignment alignment = Alignment::None;
    double outgoingBpm = 0;
    double spectralScore = 0;

    static AppleTransitionPlan analyze(const QUrl &outgoing, const QUrl &incoming,
                                       const std::atomic_bool &cancelled);
};
