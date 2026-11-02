import SwiftUI
import WidgetKit
import AppIntents
import CPAQuotaActivity

@main
struct CPAQuotaActivityBundle: WidgetBundle {
    var body: some Widget {
        CPAQuotaLiveActivityWidget()
        CPAQuotaWidget()
    }
}

struct CPAQuotaExtensionIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] {
        [CPAQuotaWidgetIntentsPackage.self]
    }
}
