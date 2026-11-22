import Foundation

extension WindowCapture {
  /// Replaces app window titles with stable placeholders ("Safari window 2"), so captures can
  /// be committed as fixtures or attached to a problem report. WindowManager's own titles
  /// (overlays, icon badges) are kept: the reader needs them. Strip-tile titles (the front
  /// window's title) get the same placeholder as their window, or a generic one.
  ///
  /// Pass several frames of one recording together so a window keeps one placeholder across them.
  public static func redactingTitles(_ frames: [WindowCapture]) -> [WindowCapture] {
    var names: [UInt32: String] = [:]
    var perOwner: [String: Int] = [:]
    return frames.map { c in
      var c = c
      var byTitle: [String: String] = [:]
      c.windows = c.windows.map { w in
        var w = w
        guard w.owner != StageManagerConstants.ownerName, let n = w.name, !n.isEmpty else { return w }
        if names[w.id] == nil {
          perOwner[w.owner, default: 0] += 1
          names[w.id] = "\(w.owner) window \(perOwner[w.owner]!)"
        }
        byTitle[n] = byTitle[n] ?? names[w.id]
        w.name = names[w.id]
        return w
      }
      c.stripTiles = c.stripTiles?.map { t in
        var t = t
        if let title = t.title, !title.isEmpty {
          let ids = Set(t.windowIDs)
          t.title = byTitle[title] ?? c.windows.first { ids.contains($0.id) && $0.name != nil }?.name ?? "tile"
        }
        return t
      }
      return c
    }
  }
}
