//
//  The_Quark_ResonatorApp.swift
//  The Quark Resonator
//
//  Created by David Nishimoto on 9/17/26.
//

import SwiftUI
import CoreData

@main
struct The_Quark_ResonatorApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
