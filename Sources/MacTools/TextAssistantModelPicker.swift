import MacToolsCore
import SwiftUI

/// A pop-up button that opens a searchable list of models, grouped by provider.
/// Type to filter, ↑/↓ to move, Return to choose, Escape to close.
struct ModelPicker: View {
    let groups: [ModelGroup]
    @Binding var selection: String
    /// The value stored for a model; OpenCode keeps `provider/model`, OpenRouter just the model ID.
    let key: (ModelOption) -> String
    /// Shown when nothing is chosen yet.
    var automaticTitle: String?
    var isLoading = false

    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                if isLoading { ProgressView().controlSize(.mini) }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 280, alignment: .trailing)
        }
        .disabled(groups.isEmpty)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelPickerList(groups: groups, selected: selectedModel?.id) { model in
                selection = key(model)
                isPresented = false
            }
        }
    }

    private var selectedModel: ModelOption? {
        groups.lazy.flatMap(\.models).first { key($0) == selection }
    }

    private var title: String {
        if let selectedModel { return "\(selectedModel.name) · \(groupName(selectedModel))" }
        if selection.isEmpty { return automaticTitle ?? "Choose a model" }
        return selection
    }

    private func groupName(_ model: ModelOption) -> String {
        groups.first { $0.models.contains(model) }?.name ?? model.providerID
    }
}

private struct ModelPickerList: View {
    let groups: [ModelGroup]
    let selected: String?
    let choose: (ModelOption) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search \(modelCount.formatted()) models", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(10)
                .onSubmit { if let model = highlightedModel ?? visible.first { choose(model) } }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onChange(of: query) { highlighted = visible.first?.id }
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(filteredGroups) { group in
                        Section(group.name) {
                            ForEach(group.models) { model in
                                ModelRow(model: model, isSelected: model.id == selected, isHighlighted: model.id == highlighted)
                                    .id(model.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { choose(model) }
                                    .onHover { if $0 { highlighted = model.id } }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if visible.isEmpty { ContentUnavailableView.search(text: query) }
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onAppear {
                    highlighted = selected ?? visible.first?.id
                    if let selected { proxy.scrollTo(selected, anchor: .center) }
                }
            }
        }
        .frame(width: 440, height: 460)
        .onAppear { searchFocused = true }
    }

    private var modelCount: Int { groups.reduce(0) { $0 + $1.models.count } }

    /// Every word must appear in the name, model ID, or provider.
    private var filteredGroups: [ModelGroup] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return groups }
        return groups.compactMap { group in
            let models = group.models.filter { model in
                let haystack = "\(model.name) \(model.id) \(group.name)".lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            return models.isEmpty ? nil : ModelGroup(id: group.id, name: group.name, models: models)
        }
    }

    private var visible: [ModelOption] { filteredGroups.flatMap(\.models) }

    private var highlightedModel: ModelOption? { visible.first { $0.id == highlighted } }

    private func move(_ offset: Int) {
        let models = visible
        guard !models.isEmpty else { return }
        let index = models.firstIndex { $0.id == highlighted } ?? (offset > 0 ? -1 : models.count)
        highlighted = models[min(max(index + offset, 0), models.count - 1)].id
    }
}

private struct ModelRow: View {
    let model: ModelOption
    let isSelected: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .opacity(isSelected ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.name).lineLimit(1)
                Text(model.modelID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            price
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.18) : .clear)
        )
    }

    @ViewBuilder private var price: some View {
        if model.isFree {
            Text("Free")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.green.opacity(0.2)))
                .foregroundStyle(.green)
        } else if let input = model.inputPrice, let output = model.outputPrice {
            Text("$\(Self.format(input)) / $\(Self.format(output))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("US dollars per million input / output tokens")
        }
    }

    private static func format(_ value: Double) -> String {
        value < 1 ? String(format: "%.2f", value) : String(format: value.rounded() == value ? "%.0f" : "%.1f", value)
    }
}
