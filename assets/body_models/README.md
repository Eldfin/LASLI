Place GLB body visualization assets here:

- `body.glb`: one rigged full-body model. LASLI crops the view to head and
  chest/shoulder regions and uses the same file for both sensor views.
- `head_mesh.json` and `chest_mesh.json`: extracted lightweight mesh assets
  generated from `body.glb`. LASLI prefers these because they render directly
  in Flutter and update smoothly with touch and sensor orientation.
- `head.glb`: head or head bust model, facing forward in its neutral pose.
- `chest.glb`: upper torso/chest model, facing forward in its neutral pose.

Keep the files reasonably small for mobile use. Models below roughly 5-15 MB
each are much easier to render smoothly inside the app.

After replacing or adding these files, rebuild the app so Flutter includes them
in the APK asset bundle.
