import Foundation
import CPAQuotaKit
import CPAQuotaUI

#if canImport(SwiftUI)
import SwiftUI

@main
struct CPAQuotaiOSApp: App {
    @State private var session = CPAQuotaSession()

    var body: some Scene {
        WindowGroup {
            CPAQuotaRootView(session: session)
        }
    }
}
#else
@main
struct CPAQuotaiOSAppFallback {
    static func main() {
        print("CPAQuotaApp requires an Apple platform with SwiftUI runtime.")
    }
}
#endif
