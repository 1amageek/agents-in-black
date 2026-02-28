import SwiftUI

struct TerminalTabsView: View {
    @Bindable var model: AgentsInBlackAppModel
    var showsHeader: Bool = true
    var filterText: String = ""

    var body: some View {
        if let tab = model.selectedTerminalTab() {
            TerminalTabDetailView(model: model, tab: tab, showsHeader: showsHeader, filterText: filterText)
        } else {
            ContentUnavailableView(
                "No Terminal",
                systemImage: "terminal",
                description: Text("Select a repository, service, or file in the sidebar to use its repository terminal.")
            )
        }
    }
}
