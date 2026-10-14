//
//  sorbfischApp.swift
//  sorbfisch
//
//  Created by Karl Georg Josef Baier on 05.10.26.
//

import SwiftUI
import Foundation

@main
struct sorbfischApp: App {
    var body: some Scene {
        WindowGroup {
            if AppleIntelligenceDeviceSupport.isSupported {
                ContentView()
            } else {
                ContentUnavailableView {
                    Label("Gerät nicht unterstützt", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Sorbfisch benötigt ein Gerät, das Apple Intelligence unterstützt. Dieses Gerät erfüllt diese Hardwareanforderung nicht. Auf unterstützten Geräten muss Apple Intelligence nicht aktiviert sein.")
                } actions: {
                    Link("Impressum", destination: URL(string: "https://zalozba.de/deutsch/impressum/")!)
                    Link("Datenschutz", destination: URL(string: "https://zalozba.de/deutsch/datenschutz/")!)
                }
            }
        }
    }
}
