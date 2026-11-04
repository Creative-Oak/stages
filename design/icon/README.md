# Stages app icon: layers for Icon Composer

Flat artwork on a 1024 × 1024 canvas, no shadows, gradients or squircle: Icon Composer adds the
shape, glass, lighting and the light / dark / tinted variants.

- `stage.svg`: the centre stage, a window with its title bar cut out (front layer).
- `strip.svg`: the strip, three cards (back layer; lower opacity or an ink tint works well).
- `preview.svg`: both on a background, to show the intent. Not for import.

Suggested background: Lodestone ultramarine `#2C3F9E` → teal `#2F7F7A`. Inks for tinting the
cards: chrome `#E3B72B`, oxide `#D1612F`, grass `#5F9A4A`.

Export the finished `.icon` from Icon Composer into `App/Stages/` (it replaces the generated
`Assets.xcassets/AppIcon`; see `tools/make-app-icon.swift` for the old one).
