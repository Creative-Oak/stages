# Stages app icon

The shipping icon is the Icon Composer file **`App/Stages/AppIcon.icon`** (Magnus's design: the
strip and the stage in glass on orange). Edit it in Icon Composer and copy it back there; the
build compiles it into the app (`Assets.car`, plus `AppIcon.icns` for older surfaces).

This folder holds an exploration that didn't ship: "offstage beams", three stage lights outside
the canvas on a circle (radius 1024) around the stage point at ¾ of the width, π/8 apart, each
beam spread θ/3 so all are equally wide (270 px) where they overlap at the stage, fading into a
glow. `dark/` and `light/` have the layers (SVG and PNG with the blur baked in);
`preview-*.png` and `previews.png` show them.
