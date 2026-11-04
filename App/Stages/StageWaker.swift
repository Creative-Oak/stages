import AppKit
import StageStore

/// Wakes a sleeping stage from its recipe: relaunch its apps and reopen its documents (file
/// paths and web pages, each with an app from the recipe that can open it). Stage Manager puts
/// each app in its own stage; grouping them again is a Shift-click Stages doesn't fake (it
/// never moves the pointer).
enum StageWaker {
  struct Result {
    var apps: [String] = []        // app names, as launched
    var documents = 0
    var problems: [String] = []
  }

  static func wake(_ record: StageRecord) async -> Result {
    var result = Result()
    let ws = NSWorkspace.shared
    // Recipe apps that exist on this Mac.
    var appURLs: [String: URL] = [:]
    let recipe = record.wakeRecipe
    for id in recipe.apps.sorted() {
      if id.hasPrefix("name:") {
        result.problems.append("\(id.dropFirst(5)) has no bundle ID, so it can't be relaunched")
      } else if let url = ws.urlForApplication(withBundleIdentifier: id) {
        appURLs[id] = url
      } else {
        result.problems.append("\(id) isn't installed")
      }
    }

    // Each document goes to a recipe app that can open it, else to its default app.
    var docsByApp: [URL: [URL]] = [:]
    for doc in recipe.documents.sorted() {
      guard let url = URL(string: doc) ?? (doc.hasPrefix("/") ? URL(fileURLWithPath: doc) : nil) else { continue }
      if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
        result.problems.append("\(url.lastPathComponent) no longer exists")
        continue
      }
      let capable = Set(ws.urlsForApplications(toOpen: url))
      let app = appURLs.values.first { capable.contains($0) } ?? ws.urlForApplication(toOpen: url)
      if let app { docsByApp[app, default: []].append(url) }
    }

    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    for (id, appURL) in appURLs.sorted(by: { $0.key < $1.key }) {
      let name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
      do {
        if let docs = docsByApp.removeValue(forKey: appURL), !docs.isEmpty {
          _ = try await ws.open(docs, withApplicationAt: appURL, configuration: config)
          result.documents += docs.count
        } else {
          _ = try await ws.openApplication(at: appURL, configuration: config)
        }
        result.apps.append(name)
      } catch {
        result.problems.append("couldn't open \(name) (\(id)): \(error.localizedDescription)")
      }
    }
    // Documents whose best app wasn't in the recipe.
    for (appURL, docs) in docsByApp {
      if (try? await ws.open(docs, withApplicationAt: appURL, configuration: config)) != nil {
        result.documents += docs.count
      }
    }
    return result
  }
}
