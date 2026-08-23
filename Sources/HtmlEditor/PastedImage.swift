import AppKit
import UniformTypeIdentifiers

/// An image pulled off the pasteboard, ready to be written next to the .html file.
struct PastedImage {
    var data: Data
    /// File name stem without extension, e.g. "pasted-image" or the original file's name.
    var suggestedName: String
    var fileExtension: String

    /// Cheap check for menu validation — does not decode the image.
    static func isAvailable(on pasteboard: NSPasteboard) -> Bool {
        if NSImage.canInit(with: pasteboard) { return true }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else { return false }
        return urls.contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    /// Reads the first image the pasteboard can offer, preferring a real file
    /// (so we keep its name and encoding) over raw bitmap data.
    static func read(from pasteboard: NSPasteboard) -> PastedImage? {
        if let image = fromFileURL(pasteboard) { return image }
        if let image = fromImageData(pasteboard) { return image }
        return nil
    }

    private static func fromFileURL(_ pasteboard: NSPasteboard) -> PastedImage? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else { return nil }
        for url in urls {
            guard let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .image),
                  let data = try? Data(contentsOf: url) else { continue }
            return PastedImage(data: data,
                               suggestedName: url.deletingPathExtension().lastPathComponent,
                               fileExtension: url.pathExtension.lowercased())
        }
        return nil
    }

    private static func fromImageData(_ pasteboard: NSPasteboard) -> PastedImage? {
        // Screenshots and "Copy Image" land here. Keep PNG as-is; re-encode anything else.
        if let png = pasteboard.data(forType: .png) {
            return PastedImage(data: png, suggestedName: "pasted-image", fileExtension: "png")
        }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            return PastedImage(data: jpeg, suggestedName: "pasted-image", fileExtension: "jpg")
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return PastedImage(data: png, suggestedName: "pasted-image", fileExtension: "png")
    }

    /// Writes the image into `directory`, never overwriting an existing file.
    /// Returns the file name to reference from the HTML.
    func write(into directory: URL) throws -> String {
        let stem = PastedImage.sanitize(suggestedName)
        var name = "\(stem).\(fileExtension)"
        var counter = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(stem)-\(counter).\(fileExtension)"
            counter += 1
        }
        try data.write(to: directory.appendingPathComponent(name))
        return name
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "pasted-image" : trimmed
    }
}
