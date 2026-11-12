#include "SettingsCard.h"
#include "HudScroll.h"
#include <QtGlobal>
#include <algorithm>
#include <cmath>

namespace SettingsCard {
namespace {
constexpr double HeaderHeight = 46.;
constexpr double SectionGap = 24.;
constexpr double RowHeight = 66.;
constexpr double RowStep = 76.;
constexpr double OptionHeight = 50.;
constexpr double BottomPad = 28.;
constexpr double ContentInset = 14.;
constexpr double ControlWidth = 300.;
constexpr double LinkGap = 16.;
constexpr double LinkRowHeight = 50.;
constexpr double LinkRowStep = 60.;

QJsonArray fade(const QJsonArray &color, double alpha) {
    auto value = color;
    value[3] = alpha;
    return value;
}

QString actionFor(const RowModel &row) {
    return row.descriptor->binding.actionPrefix.isEmpty() ? row.descriptor->binding.action
                                                          : row.descriptor->binding.actionPrefix;
}

QString rowIndex(int index) {
    return QString::number(index + 1).rightJustified(2, '0');
}

void drawSectionHeader(const SectionLayout &section, const Colors &colors, const Canvas &canvas) {
    const auto header = section.header;
    const auto left = header.left() + ContentInset;
    const auto width = header.width() - ContentInset * 2;
    canvas.text(QString::number(section.section->meta->number).rightJustified(2, '0'), left,
                header.top() + 12, 11, "regular", 0.05, colors.muted);
    canvas.text(section.section->meta->titleEn + " / " + section.section->meta->titleZh, left + 26,
                header.top() + 9, 14, "demibold", 0.06, colors.ink);
    canvas.fill(left, header.bottom() - 1, width, 1, colors.line);
}

void drawOptions(const RowLayout &layout, const RowModel &row, const Colors &colors, const Canvas &canvas) {
    const auto options = layout.options;
    canvas.fill(options.left(), options.top(), options.width(), options.height(), colors.soft);
    canvas.stroke(options, colors.line);
    for (int index = 0; index < row.choices.size(); ++index) {
        const auto &choice = row.choices.at(index);
        const auto rect = QRectF(options.left() + 2, options.top() + 2 + index * OptionHeight,
                                 options.width() - 4, OptionHeight - 4);
        const bool active = choice.value == row.value.canonical;
        if (active) {
            canvas.fill(rect.left(), rect.top(), 3, rect.height(), colors.gold);
        }
        canvas.text(canvas.fit(choice.label, 15, rect.width() - 32, "regular"), rect.left() + 14,
                    rect.top() + 15, 15, active ? "demibold" : "regular", 0, colors.ink);
        canvas.hit(rect.left(), rect.top(), rect.width(), rect.height(), actionFor(row) + choice.value,
                   choice.label);
    }
}

void drawChoice(const RowLayout &layout, const RowModel &row, const Colors &colors, const Canvas &canvas) {
    const auto control = layout.control;
    canvas.fill(control.left(), control.top(), control.width(), control.height(), colors.soft);
    canvas.stroke(control, colors.line);
    canvas.text(canvas.fit(row.label, 15, control.width() - 48, "regular"), control.left() + 14,
                control.top() + 15, 15, "regular", 0, row.enabled ? colors.ink : fade(colors.ink, 0.35));
    canvas.text(row.expanded ? "▴" : "▾", control.right() - 24, control.top() + 14, 14, "regular", 0,
                row.enabled ? colors.muted : fade(colors.muted, 0.3));
    if (row.enabled) {
        canvas.hit(control.left(), control.top(), control.width(), control.height(),
                   "expand:" + row.descriptor->id, row.descriptor->titleZh);
        // Android 不注册下面这个左侧标题热区。它绑定的是旧版 binding.action「一键循环到
        // 下一个值」，手指在设置页点选或滚动时擦到名称就会误改设置且没有撤销；右侧控件
        // 已经能完成全部设值：点 control 展开下拉，再点具体选项走 setting:<id>:<value>，
        // Stepper 的 ±/轨道、Action、TextInput、Link 与自定义区块按钮也都在右侧。
        // 桌面 / iOS 走下面的分支，代码逐字不变；想恢复旧行为去掉这对预处理指令即可。
#if !defined(Q_OS_ANDROID)
        // 保留旧版值循环动作的可达性：点标题区仍可切换，右侧控件负责下拉。
        if (!row.descriptor->binding.action.isEmpty()) {
            const auto labelLeft = layout.bounds.left() + 30;
            const auto labelWidth = control.left() - labelLeft - 8;
            if (labelWidth > 0) {
                canvas.hit(labelLeft, layout.bounds.top() + 4, labelWidth, RowHeight - 8,
                           row.descriptor->binding.action, row.descriptor->titleZh);
            }
        }
#endif
    }
}

void drawStepper(const RowLayout &layout, const RowModel &row, const Colors &colors, const Canvas &canvas) {
    const auto control = layout.control;
    canvas.fill(control.left(), control.top(), control.width(), control.height(), colors.soft);
    canvas.stroke(control, colors.line);

    // 数值在减号左侧；进度条垂直居中并位于加减按钮之间。
    canvas.text(canvas.fit(row.label, 15, 96, "demibold"), control.left() + 2, control.top() + 15, 15,
                "demibold", 0, row.enabled ? colors.ink : fade(colors.ink, 0.35));
    const auto minus = QRectF(control.left() + 100, control.top() + 8, 32, 32);
    const auto plus = QRectF(control.right() - 40, control.top() + 8, 32, 32);
    canvas.stroke(minus, colors.line);
    canvas.stroke(plus, colors.line);
    canvas.centered("−", minus.center().x(), minus.center().y(), 19, "regular", true);
    canvas.centered("＋", plus.center().x(), plus.center().y(), 16, "regular", true);

    if (row.numericValues.size() > 1) {
        const auto track =
            QRectF(minus.right() + 12, control.center().y() - 2, plus.left() - minus.right() - 24, 4);
        canvas.fill(track.left(), track.top(), track.width(), track.height(), colors.faint);
        int selected = 0;
        int count = 0;
        for (int value : row.numericValues) {
            if (value == row.value.integer) {
                selected = count;
            }
            ++count;
        }
        const auto fraction = count <= 1 ? 0. : double(selected) / double(count - 1);
        canvas.fill(track.left(), track.top(), track.width() * fraction, track.height(), colors.gold);
        const auto knobX = track.left() + track.width() * fraction - 4;
        canvas.fill(knobX, track.top() - 5, 8, 14, colors.ink);
        if (row.enabled) {
            const auto segment = track.width() / std::max(1, count);
            for (int index = 0; index < count; ++index) {
                canvas.hit(track.left() + index * segment, track.top() - 10, segment, 24,
                           actionFor(row) + QString::number(row.numericValues.at(index)),
                           row.descriptor->titleZh);
            }
        }
    }
    if (row.enabled) {
        if (!row.decrementValue.isEmpty()) {
            canvas.hit(minus.left(), minus.top(), minus.width(), minus.height(),
                       actionFor(row) + row.decrementValue, row.descriptor->titleZh);
        }
        if (!row.incrementValue.isEmpty()) {
            canvas.hit(plus.left(), plus.top(), plus.width(), plus.height(),
                       actionFor(row) + row.incrementValue, row.descriptor->titleZh);
        }
    }
}

void drawAction(const RowLayout &layout, const RowModel &row, const Colors &colors, const Canvas &canvas) {
    const auto control = layout.control;
    canvas.fill(control.left(), control.top(), control.width(), control.height(), colors.soft);
    canvas.stroke(control, colors.line);
    canvas.text(canvas.fit(row.descriptor->actionLabel, 15, control.width() - 48, "regular"),
                control.left() + 14, control.top() + 15, 15, "regular", 0,
                row.enabled ? colors.ink : fade(colors.ink, 0.35));
    canvas.text("→", control.right() - 24, control.top() + 14, 14, "regular", 0,
                row.enabled ? colors.muted : fade(colors.muted, 0.3));
    if (row.enabled) {
        canvas.hit(control.left(), control.top(), control.width(), control.height(),
                   row.descriptor->binding.action, row.descriptor->titleZh);
    }
}

void drawTextInput(const RowLayout &layout, const RowModel &row, const Colors &colors, const Canvas &canvas) {
    const auto control = layout.control;
    canvas.fill(control.left(), control.top(), control.width(), control.height(), colors.soft);
    canvas.stroke(control, colors.line);
    canvas.text(canvas.fit(row.label, 15, control.width() - 48, "regular"), control.left() + 14,
                control.top() + 15, 15, "regular", 0, row.enabled ? colors.ink : fade(colors.ink, 0.35));
    canvas.text("✎", control.right() - 24, control.top() + 14, 14, "regular", 0,
                row.enabled ? colors.muted : fade(colors.muted, 0.3));
    if (row.enabled) {
        canvas.hit(control.left(), control.top(), control.width(), control.height(),
                   "setting-edit:" + row.descriptor->id, row.descriptor->titleZh);
    }
}

void drawLink(const RowLayout &layout, const RowModel &row, const Colors &colors, const Canvas &canvas) {
    const auto rect = layout.bounds;
    canvas.fill(rect.left(), rect.top(), rect.width(), rect.height(), colors.soft);
    canvas.stroke(rect, colors.line);
    canvas.text(canvas.fit(row.descriptor->actionLabel, 14, rect.width() - 40, "regular"), rect.left() + 12,
                rect.top() + 15, 14, "regular", 0, colors.ink);
    canvas.text("↗", rect.right() - 22, rect.top() + 14, 13, "regular", 0, colors.muted);
    canvas.hit(rect.left(), rect.top(), rect.width(), rect.height(), row.descriptor->binding.action,
               row.descriptor->actionLabel);
}

void drawRow(const RowLayout &layout, const RowModel &row, int index, const Colors &colors,
             const Canvas &canvas, const QRectF &viewport) {
    if (row.descriptor->kind == SettingsSchema::SettingKind::Link) {
        drawLink(layout, row, colors, canvas);
        return;
    }
    const auto rect = layout.bounds;
    const auto ink = row.enabled ? colors.ink : fade(colors.ink, 0.35);
    const auto muted = row.enabled ? colors.muted : fade(colors.muted, 0.28);
    canvas.fill(rect.left(), rect.bottom() - 1, rect.width(), 1, colors.line);
    canvas.text(rowIndex(index), rect.left(), rect.top() + 25, 11, "regular", 0.04, muted);
    canvas.text(row.descriptor->titleEn, rect.left() + 30, rect.top() + 10, 11, "regular", 0.08, muted);
    canvas.text(row.descriptor->titleZh, rect.left() + 30, rect.top() + 25, 17, "demibold", -0.01, ink);
    const auto &hint =
        row.descriptor->showDescription ? row.descriptor->description : row.descriptor->restartHint;
    if (!hint.isEmpty()) {
        canvas.text(hint, rect.left() + 30, rect.top() + 50, 10, "regular", 0.03, muted);
    }

    switch (row.descriptor->kind) {
    case SettingsSchema::SettingKind::Switch:
        drawChoice(layout, row, colors, canvas);
        break;
    case SettingsSchema::SettingKind::Choice:
        drawChoice(layout, row, colors, canvas);
        break;
    case SettingsSchema::SettingKind::Stepper:
    case SettingsSchema::SettingKind::Slider:
        drawStepper(layout, row, colors, canvas);
        break;
    case SettingsSchema::SettingKind::Action:
        drawAction(layout, row, colors, canvas);
        break;
    case SettingsSchema::SettingKind::Link:
        drawLink(layout, row, colors, canvas);
        break;
    case SettingsSchema::SettingKind::TextInput:
        drawTextInput(layout, row, colors, canvas);
        break;
    case SettingsSchema::SettingKind::Custom:
        break;
    }

    if (row.expanded && row.enabled) {
        const auto options = layout.options;
        if (options.intersects(viewport)) {
            drawOptions(layout, row, colors, canvas);
        }
    }
}
}

Layout layout(const Model &model) {
    Layout result;
    result.viewport = model.viewport;
    const auto left = model.viewport.left() + ContentInset;
    const auto width = model.viewport.width() - ContentInset * 2;
    double cursor = model.viewport.top();
    for (const auto &section : model.sections) {
        SectionLayout sectionLayout;
        sectionLayout.section = &section;
        sectionLayout.header = QRectF(model.viewport.left(), cursor, model.viewport.width(), HeaderHeight);
        cursor += HeaderHeight;
        if (!section.meta->customRenderer.isEmpty()) {
            const auto bodyHeight = std::max(0., section.meta->customHeight);
            sectionLayout.body = QRectF(left, cursor, width, bodyHeight);
            sectionLayout.height = HeaderHeight + bodyHeight;
            cursor += bodyHeight + SectionGap;
        } else if (section.meta->id == SettingsSchema::SectionId::Project) {
            const auto linkWidth = (width - LinkGap) / 2;
            for (int index = 0; index < section.rows.size(); ++index) {
                RowLayout rowLayout;
                rowLayout.row = &section.rows.at(index);
                rowLayout.bounds = QRectF(left + (index % 2) * (linkWidth + LinkGap),
                                          cursor + (index / 2) * LinkRowStep, linkWidth, LinkRowHeight);
                sectionLayout.rows.append(rowLayout);
            }
            const auto bodyHeight = ((section.rows.size() + 1) / 2) * LinkRowStep;
            sectionLayout.body = QRectF(left, cursor, width, bodyHeight);
            sectionLayout.height = HeaderHeight + bodyHeight;
            cursor += bodyHeight + SectionGap;
        } else {
            const auto bodyTop = cursor;
            for (auto &row : section.rows) {
                RowLayout rowLayout;
                rowLayout.row = &row;
                rowLayout.bounds = QRectF(left, cursor, width, RowHeight);
                rowLayout.control = QRectF(left + width - ControlWidth, cursor + 9, ControlWidth, 48);
                if (row.expanded && row.enabled) {
                    rowLayout.optionsHeight = row.choices.size() * OptionHeight + 4;
                    rowLayout.options = QRectF(rowLayout.control.left(), cursor + RowHeight + 2, ControlWidth,
                                               rowLayout.optionsHeight);
                }
                sectionLayout.rows.append(rowLayout);
                cursor += RowStep + rowLayout.optionsHeight;
            }
            sectionLayout.body = QRectF(left, bodyTop, width, cursor - bodyTop);
            sectionLayout.height = HeaderHeight + (cursor - bodyTop);
            cursor += SectionGap;
        }
        result.sections.append(sectionLayout);
    }
    result.contentHeight = cursor - model.viewport.top() + BottomPad;
    result.maximumScroll = HudScroll::maximum(result.contentHeight, model.viewport.height());
    return result;
}

void paint(const Model &model, const Layout &layout, const Colors &colors, const Canvas &canvas) {
    for (const auto &section : layout.sections) {
        SectionLayout scrolled = section;
        scrolled.header.translate(0, -model.scroll);
        scrolled.body.translate(0, -model.scroll);
        for (auto &row : scrolled.rows) {
            row.bounds.translate(0, -model.scroll);
            row.control.translate(0, -model.scroll);
            row.options.translate(0, -model.scroll);
        }
        if (scrolled.header.intersects(model.viewport)) {
            drawSectionHeader(scrolled, colors, canvas);
        }
        if (!scrolled.section->meta->customRenderer.isEmpty()) {
            if (scrolled.body.intersects(model.viewport)) {
                canvas.custom(scrolled.section->meta->customRenderer, scrolled.body, model.scroll);
            }
            continue;
        }
        int index = 0;
        for (const auto &rowLayout : scrolled.rows) {
            const bool rowVisible = rowLayout.bounds.intersects(model.viewport);
            const bool optionsVisible =
                rowLayout.row->expanded && rowLayout.options.intersects(model.viewport);
            if (rowVisible) {
                drawRow(rowLayout, *rowLayout.row, index, colors, canvas, model.viewport);
            }
            if (optionsVisible && !rowVisible) {
                drawOptions(rowLayout, *rowLayout.row, colors, canvas);
            }
            ++index;
        }
    }
}
}
