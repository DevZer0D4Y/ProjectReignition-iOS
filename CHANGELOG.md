# Changelog

## 1.0.9 (build 5)

- The homing attack's aura no longer stays on Sonic. Godot's Mobile renderer ignores the fade the game uses for it; the port now fades such objects itself, which also fixes item box glows, fire souls, debris, the Evil Foundry golem's core and Pirate Storm's lightning.
- No more black patches where Lost Prologue's Wonderblocks appear: the Mobile renderer halved multiply-blended effects, which now draw as on PC there and in later stages.
- Cutscenes that showed only subtitles and sound play their video again (the one after the first stage, Events 4 to 9, the openings, the endings and the developer intro).

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

Known issues: the first visit to an area can stutter while shaders compile, and Party mode's local network play is untested.
