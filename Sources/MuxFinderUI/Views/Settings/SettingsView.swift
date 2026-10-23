import SwiftUI

/// The Settings window's content (PLAN.md Phase 9a, D23): the Hosts, Persistent profiles (D26),
/// General and Diagnostics tabs over one `SettingsModel`.
public struct SettingsView: View {
  /// The window's size when it first opens, in points.
  public static let defaultSize = CGSize(width: 720, height: 740)
  /// The smallest the window gets, in points.
  public static let minimumSize = CGSize(width: 640, height: 520)

  /// The model shown.
  @Bindable var model: SettingsModel

  /// A Settings view for `model`.
  public init(model: SettingsModel) {
    self.model = model
  }

  /// The tabs.
  public var body: some View {
    TabView(selection: $model.selectedTab) {
      HostsSettingsView(model: model)
        .tabItem { Text(SettingsModel.Tab.hosts.title) }
        .tag(SettingsModel.Tab.hosts)
      ProfilesSettingsView(model: model)
        .tabItem { Text(SettingsModel.Tab.profiles.title) }
        .tag(SettingsModel.Tab.profiles)
      GeneralSettingsView(model: model)
        .tabItem { Text(SettingsModel.Tab.general.title) }
        .tag(SettingsModel.Tab.general)
      DiagnosticsSettingsView(model: model)
        .tabItem { Text(SettingsModel.Tab.diagnostics.title) }
        .tag(SettingsModel.Tab.diagnostics)
    }
    .padding(12)
  } // End of var body
}
