//
//  PermissionsView.swift
//  Streamio
//
//  Shown instead of the studio until camera, microphone and screen recording are all
//  granted. Each row can prompt, or jump straight to its System Settings pane.
//

import AppKit
import SwiftUI

struct PermissionsView: View {
    @Environment(PermissionsManager.self) private var permissions

    var body: some View {
        VStack(spacing: Theme.spacingXL) {
            VStack(spacing: Theme.spacingM) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Allow Streamio to capture")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("The studio opens once all three permissions are granted.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(PermissionsManager.Kind.allCases) { kind in
                    PermissionRow(kind: kind)
                    if kind != PermissionsManager.Kind.allCases.last { Divider().padding(.leading, 56) }
                }
            }
            .padding(Theme.spacingS)
            .glassEffect(.regular, in: .rect(cornerRadius: Theme.dockRadius))
            .frame(maxWidth: 620)

            VStack(spacing: Theme.spacingS) {
                Button {
                    Task { await permissions.requestAll() }
                } label: {
                    Label("Grant All Permissions", systemImage: "checkmark.shield")
                        .frame(minWidth: 240)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .disabled(permissions.isRequesting)

                if permissions.state(.screen) == .denied {
                    HStack(spacing: Theme.spacingS) {
                        Text("Turned on Screen & System Audio Recording in System Settings?")
                            .foregroundStyle(.secondary)
                        Button("Relaunch Streamio", action: permissions.relaunch)
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.ultraThinMaterial, for: .window)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle("Streamio")
        .task {
            // Ask on launch, then keep checking: grants made in System Settings show up live.
            await permissions.requestAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                permissions.refresh()
            }
        }
    }
}

struct PermissionRow: View {
    @Environment(PermissionsManager.self) private var permissions
    let kind: PermissionsManager.Kind

    var body: some View {
        let state = permissions.state(kind)
        HStack(spacing: Theme.spacingM) {
            Image(systemName: kind.systemImage)
                .font(.title2)
                .frame(width: 40, height: 40)
                .foregroundStyle(state == .granted ? Theme.good : Color.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.headline)
                Text(kind.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.good)
                    .font(.callout.bold())
            case .notDetermined:
                Button("Grant Access") {
                    Task { await permissions.request(kind) }
                }
                .buttonStyle(.glass)
            case .denied:
                Button("Open System Settings") { permissions.openSettings(kind) }
                    .buttonStyle(.glass)
                    .help("Turn on Streamio in Privacy & Security ▸ \(kind.title)")
            }
        }
        .padding(Theme.spacingM)
        .accessibilityElement(children: .combine)
    }
}
