import SwiftUI
import WidgetKit

@main
struct NagWidgetBundle: WidgetBundle {
    var body: some Widget {
        DueNagsWidget()
        DueCountWidget()
        LocksWidget()
    }
}
