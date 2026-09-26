import AppKit
import ImageIO
import MainThingCore
import Observation
import SwiftUI
import UniformTypeIdentifiers
import os

/// Debug aid. When `MAINTHING_SNAPSHOT_DIR` is set, renders the notch view to a PNG
/// after each list change. Self render, so it needs no Screen Recording permission.
@MainActor
final class Snapshotter {
    private let store: TaskStore
    private let model: NotchModel
    private let directory: URL
    private let log = Logger(subsystem: MainThingBundleID, category: "snapshot")
    private var counter = 0
    private var pending = false

    init?(store: TaskStore, model: NotchModel, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment["MAINTHING_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        self.store = store
        self.model = model
        self.directory = URL(fileURLWithPath: path, isDirectory: true)
    }

    func start() {
        observe()
        schedule()
    }

    private func observe() {
        withObservationTracking {
            _ = store.list
            _ = model.isOpen
            _ = model.pending
            _ = model.geometry
            _ = store.events.failing
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedule()
                self?.observe()
            }
        }
    }

    /// Coalesces bursts and lets SwiftUI settle before rendering.
    private func schedule() {
        guard !pending else { return }
        pending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            self?.pending = false
            self?.write()
        }
    }

    private func write() {
        // Tall enough for the biggest open card: 60 percent of the screen.
        let size = CGSize(
            width: NotchGeometry.panelSize.width,
            height: max(NotchGeometry.panelSize.height, ceil(model.geometry.screenFrame.height * OpenLayout.screenHeightShare))
        )
        let content = NotchView(store: store, model: model)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            log.error("render failed")
            return
        }

        // Flatten onto light gray so the black notch is visible in any image viewer.
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(CGColor(gray: 0.92, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { return }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("snapshot dir failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        counter += 1
        let name = String(format: "snapshot-%03d.png", counter)
        for file in [name, "latest.png"] {
            let url = directory.appendingPathComponent(file)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                log.error("snapshot write failed at \(url.path, privacy: .public)")
                continue
            }
            CGImageDestinationAddImage(destination, flat, nil)
            CGImageDestinationFinalize(destination)
        }
        log.info("snapshot \(name, privacy: .public) shows \(self.store.current ?? "(empty)", privacy: .public) open=\(self.model.isOpen, privacy: .public)")
    }
}
