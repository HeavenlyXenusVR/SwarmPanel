import SwiftUI

struct AlertRulesView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = AlertRulesViewModel()
    @State private var newRuleType = alertRuleTypes[0]
    @State private var newThreshold = 5

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error).padding(.horizontal)
                }

                if appState.isAdmin {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "New Rule")
                        PanelCard {
                            HStack {
                                IconChip(systemName: "bell.badge", tint: .red)
                                Text("New Rule").foregroundStyle(SwarmTheme.textMuted)
                            }
                            Picker("Type", selection: $newRuleType) {
                                ForEach(alertRuleTypes, id: \.self) { type in
                                    Text(type.replacingOccurrences(of: "_", with: " ").capitalized).tag(type)
                                }
                            }
                            Stepper("Threshold: \(newThreshold) min", value: $newThreshold, in: 1...1440)
                            Button {
                                Task { await viewModel.create(ruleType: newRuleType, thresholdMinutes: newThreshold) }
                            } label: {
                                HStack {
                                    Spacer()
                                    if viewModel.isSaving { ProgressView() } else { Text("Add Rule").bold() }
                                    Spacer()
                                }
                            }
                            .disabled(viewModel.isSaving)
                            .tint(SwarmTheme.accent)
                        }
                    }
                    .padding(.horizontal)
                    .id("newRule")
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Rules", count: viewModel.rules.count)
                    if viewModel.rules.isEmpty {
                        PanelCard {
                            VStack(spacing: 10) {
                                EmptyStateView(icon: "bell.badge", title: "No alert rules configured.")
                                if appState.isAdmin {
                                    Button("Add a Rule") {
                                        withAnimation { proxy.scrollTo("newRule", anchor: .top) }
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(SwarmTheme.accent)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        PanelCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(viewModel.rules.enumerated()), id: \.element.id) { index, rule in
                                    if index > 0 { Divider().overlay(SwarmTheme.line) }
                                    AlertRuleRow(rule: rule, canManage: appState.isAdmin, viewModel: viewModel)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .background(SwarmTheme.background)
        .navigationTitle("Alert Rules")
        .task { await viewModel.load() }
        .refreshable {
            Haptics.light()
            await viewModel.load()
        }
        }
    }
}

private struct AlertRuleRow: View {
    let rule: AlertRule
    let canManage: Bool
    @ObservedObject var viewModel: AlertRulesViewModel

    var body: some View {
        HStack {
            IconChip(systemName: "bell.badge", tint: rule.enabled ? .red : SwarmTheme.textMuted)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.ruleType.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.subheadline.bold())
                    .foregroundStyle(SwarmTheme.textPrimary)
                Text("\(rule.thresholdMinutes) min before firing")
                    .font(.caption)
                    .foregroundStyle(SwarmTheme.textMuted)
                if let escalation = rule.escalationMinutes {
                    Text("Escalates after \(escalation) min\(rule.escalateEmail == true ? " + email" : "")")
                        .font(.caption2)
                        .foregroundStyle(SwarmTheme.warn)
                }
            }
            Spacer()
            StatusPill(text: rule.enabled ? "Enabled" : "Disabled", tone: rule.enabled ? .live : .off)
            if canManage {
                Button {
                    Task { await viewModel.toggle(rule) }
                } label: {
                    Image(systemName: rule.enabled ? "pause.circle" : "play.circle")
                }
                .tint(SwarmTheme.accent)
                Button(role: .destructive) {
                    Task { await viewModel.delete(rule) }
                } label: {
                    Image(systemName: "trash")
                }
                .tint(SwarmTheme.danger)
            }
        }
        .padding(14)
    }
}

#Preview {
    NavigationStack { AlertRulesView() }
        .environmentObject(AppState())
        .environmentObject(ToastCenter())
}
