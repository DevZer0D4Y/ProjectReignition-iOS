# Changelog

## 1.0.9 (build 4)

First iOS release, built from Project Reignition 1.0.9 (`dev/v1.0.x` at e13abfa).

- On-screen touch controls that act as an Xbox controller; controller support.
- Cutscenes as Ogg Theora.
- Up to 120 FPS on ProMotion screens; lighter iOS defaults for reflections and soft shadows.
- Menus take input: scenes are exported as text, which keeps their lists of buttons and videos.
- Saves work and stay in the app's Documents folder across updates; deleting a save removes it.
- Lost Prologue's bloom works on the Mobile renderer.
- No more errors logged every frame in levels, a source of stutter.
- Garbage collections run during loading screens instead of gameplay.
- Frame-time log and test modes for benchmarks and saves.

Known issues: multiply-blended effects render too dark, the first visit to an area can stutter while shaders compile, and Party mode's local network play is untested.
