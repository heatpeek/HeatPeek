import SwiftUI

/// Section heading inside the inspector.
struct SectionLabel: View {
    let title: LocalizedStringKey
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.hpLabel(11))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(Theme.label)
            Spacer()
            if let trailing {
                Text(verbatim: trailing)
                    .font(.hpMono(10))
                    .foregroundStyle(Theme.label)
            }
        }
    }
}

/// Square segmented control. The active segment is a filled accent block.
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let active = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(verbatim: option.title)
                        .font(.hpLabel(12))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(active ? Color(hex: 0x0F1115) : Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(active ? Theme.accent : Color.clear)
                }
                .buttonStyle(.plain)
                if index < options.count - 1 {
                    Rectangle().fill(Theme.hairline).frame(width: 1, height: 26)
                }
            }
        }
        .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Slider with a narrow rectangular handle instead of a round knob.
struct BlueprintSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        GeometryReader { geo in
            let fraction = (value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound)
            let x = min(max(1.5, geo.size.width * fraction), geo.size.width - 1.5)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                Rectangle()
                    .fill(Theme.accentLine)
                    .frame(width: x, height: 1)
                Rectangle()
                    .fill(Theme.accentBright)
                    .frame(width: 3, height: 14)
                    .offset(x: x - 1.5)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let f = min(max(0, drag.location.x / geo.size.width), 1)
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: 20)
    }
}

/// Square switch with a rectangular knob.
struct BlueprintSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Rectangle()
                    .fill(isOn ? Theme.accentTintStrong : Color.white.opacity(0.04))
                    .overlay(Rectangle().strokeBorder(isOn ? Theme.accentLine.opacity(0.7) : Theme.hairline,
                                                      lineWidth: 1))
                Rectangle()
                    .fill(isOn ? Theme.accentBright : Theme.label)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .frame(width: 34, height: 18)
        }
        .buttonStyle(.plain)
    }
}

/// One cell of the burned-in overlay grid. Active cells carry the accent tint
/// and a bright dot; there are no switches in this grid.
/// One row of a single-choice list. Same frame and dot as `OverlayCell`, but
/// picking a row replaces the choice instead of toggling it, and the value the
/// row stands for sits on the right.
struct ChoiceCell: View {
    let title: String
    var detail: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(isOn ? Theme.accentBright : Theme.label.opacity(0.5))
                    .frame(width: 5, height: 5)
                Text(verbatim: title)
                    .font(.hpLabel(12))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(isOn ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if let detail {
                    Text(verbatim: detail)
                        .font(.hpMono(11))
                        .foregroundStyle(isOn ? Theme.accentBright : Theme.label)
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(isOn ? Theme.accentTint : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct OverlayCell: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(isOn ? Theme.accentBright : Theme.label.opacity(0.5))
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.hpLabel(12))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(isOn ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(isOn ? Theme.accentTint : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small pill used for presets and limits.
struct Chip: View {
    let title: String
    var isActive: Bool = false
    var isAlarm: Bool = false
    var action: (() -> Void)?

    var body: some View {
        let content = Text(verbatim: title)
            .font(.hpLabel(11.5))
            .tracking(0.6)
            .foregroundStyle(isAlarm ? Color(hex: 0xFF453A) : (isActive ? Theme.accentBright : Theme.textSecondary))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(isActive ? Theme.accentTint : Color.white.opacity(0.03))
            .overlay(Rectangle().strokeBorder(
                isAlarm ? Color(hex: 0xFF453A).opacity(0.6)
                        : (isActive ? Theme.accentLine.opacity(0.6) : Theme.hairline), lineWidth: 1))
        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// Primary action button: accent block, corner marks, capitals.
struct PrimaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.hpLabel(13, weight: .semibold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Color(hex: 0x0F1115))
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(Theme.accent)
                .blueprintFrame(color: Color(hex: 0x0F1115), opacity: 0.45, length: 5, inset: 2, showsBorder: false)
        }
        .buttonStyle(.plain)
    }
}

/// Text-only action inside a section.
struct GhostButton: View {
    let title: LocalizedStringKey
    var icon: IconShape?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Icon(shape: icon, size: 13).foregroundStyle(Theme.accentLine) }
                Text(title)
                    .font(.hpLabel(12))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.accentLine)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .overlay(Rectangle().strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Numeric field for a temperature; stored in Celsius, shown in the active unit.
/// Text entry for a temperature. What is typed stays exactly as typed until
/// the field is left or Return is pressed. Re-formatting on every keystroke
/// fights the caret: deleting a digit from "18.0" leaves "18.", which parses
/// back to the same number, so the deletion looks like it did nothing.
private struct NumberEntry: View {
    @Binding var value: Double?
    let unit: TemperatureUnit
    /// When false, clearing the field brings the previous value back.
    let allowsEmpty: Bool
    let placeholder: String
    let width: CGFloat
    let height: CGFloat
    let font: Font

    /// What is being typed. Nil means nothing is: the field then reads the
    /// model directly, so it cannot show a stale value if the panel around it
    /// is rebuilt while the field lives on.
    @State private var draft: String?
    @FocusState private var editing: Bool

    var body: some View {
        TextField(placeholder, text: Binding(get: { draft ?? formatted },
                                             set: { draft = $0 }))
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 5)
            .frame(width: width, height: height)
            .overlay(Rectangle().strokeBorder(editing ? Theme.accentLine : Theme.hairline,
                                              lineWidth: 1))
            .focused($editing)
            .onSubmit { commit() }
            .onChange(of: editing) { _, isEditing in
                if isEditing { draft = formatted } else { commit() }
            }
    }

    private var formatted: String { value.map { unit.number($0) } ?? "" }

    private func commit() {
        defer { draft = nil }
        guard let draft else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if allowsEmpty { value = nil }
        } else if let parsed = Double(trimmed.replacingOccurrences(of: ",", with: ".")) {
            value = unit.celsius(fromValue: parsed)
        }
    }
}

struct TemperatureField: View {
    @Binding var value: Double
    var unit: TemperatureUnit = .celsius
    var width: CGFloat = 74

    var body: some View {
        HStack(spacing: 5) {
            NumberEntry(value: Binding(get: { value },
                                       set: { if let new = $0 { value = new } }),
                        unit: unit, allowsEmpty: false, placeholder: "",
                        width: width, height: 26, font: .hpMono(12))
            Text(verbatim: unit.suffix)
                .font(.hpMono(10))
                .foregroundStyle(Theme.label)
        }
    }
}

struct LimitField: View {
    let title: String
    @Binding var value: Double?
    var unit: TemperatureUnit = .celsius

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: title)
                .font(.hpLabel(11))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.label)
            NumberEntry(value: $value, unit: unit, allowsEmpty: true,
                        placeholder: "\u{2014}", width: 56, height: 22,
                        font: .hpMono(11.5))
        }
    }
}

/// Palette swatch drawn straight from the lookup table.
struct PaletteSwatch: View {
    let palette: Palette
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 26)
                    .overlay(Rectangle().strokeBorder(isActive ? Theme.accentBright : Theme.hairline,
                                                      lineWidth: isActive ? 1.5 : 1))
                Text(verbatim: palette.name)
                    .font(.hpLabel(11))
                    .tracking(0.4)
                    .foregroundStyle(isActive ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .buttonStyle(.plain)
    }

    private var stops: [Gradient.Stop] {
        stride(from: 0, through: 16, by: 1).map { i in
            let t = Double(i) / 16.0
            let index = Int(t * 255) * 3
            return Gradient.Stop(
                color: Color(red: Double(palette.lut[index]) / 255,
                             green: Double(palette.lut[index + 1]) / 255,
                             blue: Double(palette.lut[index + 2]) / 255),
                location: t)
        }
    }
}
