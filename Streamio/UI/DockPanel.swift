//
//  DockPanel.swift
//  Streamio
//

import SwiftUI

/// A titled Liquid Glass dock, the building block of the OBS-style bottom row.
struct DockPanel<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            HStack {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                accessory
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Theme.spacingM)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.dockRadius))
    }
}

extension DockPanel where Accessory == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.accessory = EmptyView()
    }
}
