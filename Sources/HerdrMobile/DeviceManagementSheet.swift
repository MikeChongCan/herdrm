import SwiftUI

/// Reorder hosts and pick which one opens on launch. The switcher menu
/// follows this list order; connecting to a different Mac does not change
/// the default until you tap the star.
struct DeviceManagementSheet: View {
    @Bindable var model: MobileAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.devices) { device in
                        DeviceManageRow(
                            device: device,
                            isDefault: device.id == model.defaultDeviceID,
                            isSelected: device.id == model.selectedDeviceID,
                            onSetDefault: { model.setDefaultDevice(device.id) }
                        )
                    }
                    .onMove(perform: model.moveDevices)
                    .onDelete { offsets in
                        for device in offsets.map({ model.devices[$0] }) {
                            model.removeDevice(device)
                        }
                    }
                } footer: {
                    Text(String(localized: "Drag to change the order in the device menu. The starred Mac is selected when the app opens."))
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(String(localized: "Devices"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Add")) { model.showAddDevice = true }
                }
            }
        }
        .accessibilityIdentifier("devices.manage")
        .sheet(isPresented: $model.showAddDevice) {
            AddDeviceSheet(model: model)
        }
    }
}

private struct DeviceManageRow: View {
    let device: MobileDevice
    let isDefault: Bool
    let isSelected: Bool
    let onSetDefault: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .fontWeight(isSelected ? .semibold : .regular)
                    if isDefault {
                        Text(String(localized: "Default"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                }
                Text(device.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onSetDefault) {
                Image(systemName: isDefault ? "star.fill" : "star")
                    .foregroundStyle(isDefault ? Color.yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                isDefault
                    ? String(localized: "Default device")
                    : String(localized: "Set as default")
            )
            .accessibilityIdentifier("devices.setDefault.\(device.id.uuidString)")
        }
        .accessibilityIdentifier("devices.row.\(device.id.uuidString)")
    }
}
