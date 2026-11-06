import AppKit
import SwiftUI

/// A card a Claude session put in the notch through notch_ask or notch_show.
/// Only these shapes exist; a session fills them in and can't draw anything else.
struct NotchCard: Identifiable, Equatable {
    struct Field: Equatable {
        enum Kind: String { case choice, multichoice, text, number, toggle }

        let name: String
        let label: String
        let kind: Kind
        let options: [String]
        let min: Double
        let max: Double
        let step: Double
        let placeholder: String
        let fallback: CardValue?

        init?(_ raw: [String: Any]) {
            guard let name = raw["name"] as? String, !name.isEmpty,
                  let kind = Kind(rawValue: raw["type"] as? String ?? "") else { return nil }
            self.name = name
            self.kind = kind
            label = raw["label"] as? String ?? name
            options = raw["options"] as? [String] ?? []
            min = (raw["min"] as? NSNumber)?.doubleValue ?? 0
            max = (raw["max"] as? NSNumber)?.doubleValue ?? 100
            step = (raw["step"] as? NSNumber)?.doubleValue ?? 1
            placeholder = raw["placeholder"] as? String ?? ""
            fallback = CardValue(raw["default"], kind: kind)
        }

        /// What it starts as, where a blank wouldn't make sense.
        var initial: CardValue? {
            if let fallback { return fallback }
            switch kind {
            case .number: return .number(min)
            case .toggle: return .toggle(false)
            default: return nil
            }
        }
    }

    let id: String
    let isAsk: Bool
    let project: String
    let sessionId: String
    let title: String
    let body: String
    let fields: [Field]
    let progress: Double?

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, !id.isEmpty, let title = raw["title"] as? String else { return nil }
        self.id = id
        self.title = title
        isAsk = raw["kind"] as? String == "ask"
        project = raw["project"] as? String ?? ""
        sessionId = raw["sessionId"] as? String ?? ""
        body = raw["body"] as? String ?? ""
        fields = (raw["fields"] as? [[String: Any]] ?? []).compactMap(Field.init)
        progress = (raw["progress"] as? NSNumber)?.doubleValue
    }
}

enum CardValue: Equatable {
    case choice(String)
    case many(Set<String>)
    case text(String)
    case number(Double)
    case toggle(Bool)

    init?(_ raw: Any?, kind: NotchCard.Field.Kind) {
        switch (kind, raw) {
        case (.choice, let value as String): self = .choice(value)
        case (.multichoice, let value as [String]): self = .many(Set(value))
        case (.text, let value as String): self = .text(value)
        case (.toggle, let value as Bool): self = .toggle(value)
        case (.number, let value as NSNumber): self = .number(value.doubleValue)
        default: return nil
        }
    }

    /// In the order the field lists them, for what goes back to the session.
    func wire(_ field: NotchCard.Field) -> Any {
        switch self {
        case .choice(let value): return value
        case .many(let values): return field.options.filter(values.contains)
        case .text(let value): return value
        case .number(let value): return value
        case .toggle(let value): return value
        }
    }

    /// Enough to send: a form with something blank in it isn't an answer.
    var filled: Bool {
        switch self {
        case .text(let value): return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .many(let values): return !values.isEmpty
        default: return true
        }
    }
}

extension AgentState {
    func value(_ field: NotchCard.Field, in card: NotchCard) -> CardValue? {
        cardDrafts[card.id]?[field.name] ?? field.initial
    }

    func set(_ value: CardValue, for field: NotchCard.Field, in card: NotchCard) {
        cardDrafts[card.id, default: [:]][field.name] = value
    }

    func canSend(_ card: NotchCard) -> Bool {
        card.fields.allSatisfy { value($0, in: card)?.filled ?? false }
    }

    func send(_ card: NotchCard) {
        guard canSend(card) else { return }
        var answers: [String: Any] = [:]
        for field in card.fields {
            if let value = value(field, in: card) { answers[field.name] = value.wire(field) }
        }
        fleet?.send(["type": "card_answer", "id": card.id, "answers": answers])
        forget(card)
    }

    func dismiss(_ card: NotchCard) {
        fleet?.send(["type": "card_dismiss", "id": card.id])
        forget(card)
    }

    private func forget(_ card: NotchCard) {
        cards.removeAll { $0.id == card.id }
        cardDrafts[card.id] = nil
        returnKeyboard()
    }
}

/// One card: who it's from, what it says, and for a form, its fields.
struct CardView: View {
    @ObservedObject var state: AgentState
    let card: NotchCard

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(card.project.isEmpty ? "a Claude session" : card.project)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.45))
                Spacer()
                Button(action: { state.dismiss(card) }) {
                    Text(card.isAsk ? "dismiss" : "close")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(white: 0.45))
                }
                .buttonStyle(.plain)
            }
            Text(inlineMarkdown(card.title))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 0.94))
                .fixedSize(horizontal: false, vertical: true)
            if !card.body.isEmpty {
                MarkdownText(card.body)
            }
            if let progress = card.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(AgentPhase.listening.tint)
            }
            ForEach(card.fields, id: \.name) { field in
                CardFieldView(state: state, card: card, field: field)
            }
            if card.isAsk {
                Button(action: { state.send(card) }) {
                    Text("send")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(AgentPhase.listening.tint.opacity(state.canSend(card) ? 0.25 : 0.08)))
                        .foregroundStyle(AgentPhase.listening.tint.opacity(state.canSend(card) ? 1 : 0.4))
                }
                .buttonStyle(.plain)
                .disabled(!state.canSend(card))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No colored outline: that's what the notch's own questions look like.
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.09)))
    }
}

private struct CardFieldView: View {
    @ObservedObject var state: AgentState
    let card: NotchCard
    let field: NotchCard.Field

    private var current: CardValue? { state.value(field, in: card) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if field.kind != .toggle {
                Text(inlineMarkdown(field.label))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.72))
            }
            control
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .choice, .multichoice:
            ForEach(field.options, id: \.self) { option in
                optionRow(option)
            }
        case .text:
            TextField("", text: Binding(
                get: { if case .text(let value) = current { value } else { "" } },
                set: { state.set(.text($0), for: field, in: card) }
            ), prompt: Text(field.placeholder).foregroundStyle(Color(white: 0.32)))
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color(white: 0.9))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.14)))
            .onTapGesture { state.takeKeyboard() }
        case .number:
            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { if case .number(let value) = current { value } else { field.min } },
                    set: { state.set(.number($0), for: field, in: card) }
                ), in: field.min...field.max, step: field.step)
                .controlSize(.small)
                Text(numberLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(white: 0.8))
                    .monospacedDigit()
            }
        case .toggle:
            Toggle(isOn: Binding(
                get: { if case .toggle(let value) = current { value } else { false } },
                set: { state.set(.toggle($0), for: field, in: card) }
            )) {
                Text(inlineMarkdown(field.label))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.8))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var numberLabel: String {
        guard case .number(let value) = current else { return "" }
        return value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func isOn(_ option: String) -> Bool {
        switch current {
        case .choice(let value): return value == option
        case .many(let values): return values.contains(option)
        default: return false
        }
    }

    private func optionRow(_ option: String) -> some View {
        Button(action: { tap(option) }) {
            Text(inlineMarkdown(option))
                .font(.system(size: 11, weight: isOn(option) ? .semibold : .regular))
                .foregroundStyle(Color(white: isOn(option) ? 1 : 0.8))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(isOn(option) ? AgentPhase.listening.tint.opacity(0.22) : Color(white: 0.14)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tap(_ option: String) {
        if field.kind == .choice {
            state.set(.choice(option), for: field, in: card)
            return
        }
        var values: Set<String> = []
        if case .many(let existing) = current { values = existing }
        values.formSymmetricDifference([option])
        state.set(.many(values), for: field, in: card)
    }
}
