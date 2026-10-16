#!/usr/bin/env python3
"""Adjusts a Project Reignition checkout for the iOS build.

project.godot:
  - TouchGamepad autoload: the on-screen controller (ios/touch_gamepad.gd)
  - touches no longer pose as mouse clicks (the game binds mouse buttons to
    actions, and the touch controller handles every touch)
  - landscape on phones and tablets
  - scenes and resources exported as text: the binary conversion of a
    headless export dropped exported arrays of nodes
  - PerfProbe autoload: frame-time log and test modes (ios/PerfProbe.cs)
  - LoadingCollector autoload: garbage collection while the screen is black
    after a scene change (ios/LoadingCollector.cs)
  - MobileRendererFixes autoload: GeometryInstance3D.transparency, which the
    Mobile renderer ignores, and Multiply-blended standard materials, which
    it halves (ios/MobileRendererFixes.cs)
object/stage/destructable/resource/script/DestructableObject.cs:
  - debris handed to MobileRendererFixes
Multiply-blended shaders (blend_mul):
  - twice their output on the Mobile renderer, which halves it
video/**/*.tscn:
  - cutscene videos named by path instead of uid://
Sonic Remake Project.csproj:
  - a 64 MB young generation for the garbage collector on iOS
core/SaveManager.cs:
  - saves always in the app's Documents on iOS (the bundle is read-only, and
    saveLocation.txt's absolute path goes stale when an update moves them)
  - deleting a save removes the file where there is no trash
  - iOS defaults: 120 fps, half-resolution reflections, lighter soft shadows
core/Runtime.cs:
  - no mouse mode changes on iOS (a warning every frame in levels)
project.godot, with options:
  - with --mobile-import-only: only ETC2/ASTC texture imports (what iOS reads),
    which halves the import time and the cache of a build-only checkout
  - with --texture-limit N: 3D (VRAM-compressed) textures at most N pixels on
    a side. Menus and other 2D textures keep their size. 640 brings the IPA
    under GitHub's 2 GB release limit and halves texture memory on 4 GB phones.
Usage: apply_ios_settings.py PROJECT_DIR [--mobile-import-only] [--texture-limit N]"""
import re
import sys
from pathlib import Path

project = Path(sys.argv[1])
mobile_only = '--mobile-import-only' in sys.argv[2:]
path = project / 'project.godot'
text = path.read_text(encoding='utf-8')


def set_setting(text, section, key, value):
    pattern = re.compile(rf'^\[{re.escape(section)}\]\s*$', re.M)
    match = pattern.search(text)
    line = f'{key}={value}'
    if not match:
        return text.rstrip('\n') + f'\n\n[{section}]\n\n{line}\n'
    start = match.end()
    following = re.compile(r'^\[[^\]]+\]\s*$', re.M).search(text, start)
    end = following.start() if following else len(text)
    body = text[start:end]
    key_pattern = re.compile(rf'^{re.escape(key)}=.*$', re.M)
    if key_pattern.search(body):
        body = key_pattern.sub(line, body)
    else:
        body = body.rstrip('\n') + f'\n{line}\n\n'
    return text[:start] + body + text[end:]


text = set_setting(text, 'autoload', 'TouchGamepad', '"*res://ios/touch_gamepad.gd"')
text = set_setting(text, 'autoload', 'PerfProbe', '"*res://ios/PerfProbe.cs"')
text = set_setting(text, 'autoload', 'LoadingCollector', '"*res://ios/LoadingCollector.cs"')
text = set_setting(text, 'autoload', 'MobileRendererFixes', '"*res://ios/MobileRendererFixes.cs"')
text = set_setting(text, 'input_devices', 'pointing/emulate_mouse_from_touch', 'false')
text = set_setting(text, 'display', 'window/handheld/orientation', '4')
# Scenes and resources go into the pack as they are. Converting them to
# binary in a headless export (Godot 4.7.2) dropped exported arrays of nodes
# such as SoundManager.buttonPrompts and WorldSelect.videoPlayers: their
# scripts then failed every frame and the menus took no input.
text = set_setting(text, 'editor', 'export/convert_text_resources_to_binary', 'false')
if mobile_only:
    text = set_setting(text, 'rendering', 'textures/vram_compression/import_s3tc_bptc', 'false')
path.write_text(text, encoding='utf-8')
print(f'{path}: iOS settings applied' + (' (mobile texture imports only)' if mobile_only else ''))


def patch_source(relative, replacements):
    """Applies (original, patched) pairs to a game source file. A pair already
    applied is skipped; one whose original text is missing stops the build,
    since the game changed under the patch."""
    source_path = project / relative
    source = source_path.read_text(encoding='utf-8')
    for original, patched in replacements:
        if patched in source:
            continue
        if original not in source:
            sys.exit(f'{source_path}: {original.strip()[:70]!r} not found, the iOS patch needs updating')
        source = source.replace(original, patched, 1)
    source_path.write_text(source, encoding='utf-8')
    print(f'{source_path}: {len(replacements)} iOS patches')


patch_source('core/SaveManager.cs', [
    # saveLocation.txt is written next to the executable, which on iOS is the
    # read-only app bundle: FileAccess.Open returned null and every save threw,
    # so picking a save slot never left the menu.
    ('private static string SaveLocationFile => OS.GetExecutablePath().GetBaseDir() + "/saveLocation.txt";',
     'private static string SaveLocationFile => OS.GetName() == "iOS" ? "user://saveLocation.txt" : '
     'OS.GetExecutablePath().GetBaseDir() + "/saveLocation.txt";'),
    # The file holds an absolute path, and an update can move the app's
    # container: the old path would be missing and the game would fall back to
    # the app bundle, losing the saves. iOS always uses Documents.
    ('\tprivate string GetDataDirectory()\n\t{\n',
     '\tprivate string GetDataDirectory()\n\t{\n'
     '\t\t// iOS: always the app\'s Documents, since an update can move them\n'
     '\t\tif (OS.GetName() == "iOS")\n'
     '\t\t\treturn "user://";\n\n'),
    # iOS has no trash: the deleted save came back on the next launch.
    ('\t\tOS.MoveToTrash(ProjectSettings.GlobalizePath(saveFile));\n',
     '\t\tif (OS.MoveToTrash(ProjectSettings.GlobalizePath(saveFile)) != Error.Ok)\n'
     '\t\t\tDirAccess.RemoveAbsolute(saveFile); // No trash on iOS\n'),
    # iOS defaults: 120 fps (ProMotion), half-resolution water reflections and
    # lighter soft shadows. The PC defaults render the reflections at full
    # screen resolution and use a 4096 px shadow atlas.
    ('\t\tpublic int framerate = 3;\n',
     '\t\tpublic int framerate = OS.GetName() == "iOS" ? 5 : 3; // 120 fps on iOS\n'),
    ('\t\tpublic QualitySetting softShadowQuality = QualitySetting.Medium;\n',
     '\t\tpublic QualitySetting softShadowQuality = OS.GetName() == "iOS" ? QualitySetting.Low : QualitySetting.Medium;\n'),
    ('\t\tpublic QualitySetting reflectionQuality = QualitySetting.High;\n',
     '\t\tpublic QualitySetting reflectionQuality = OS.GetName() == "iOS" ? QualitySetting.Medium : QualitySetting.High;\n'),
])

patch_source('Sonic Remake Project.csproj', [
    # NativeAOT reads garbage collector settings compiled into the app. A 64 MB
    # young generation makes collections rare (one every few seconds of play
    # paused the game for several milliseconds each), and background
    # collection lets LoadingCollector ask for low-latency mode.
    ('</Project>',
     '  <PropertyGroup Condition=" \'$(GodotTargetPlatform)\' == \'ios\' ">\n'
     '    <ConcurrentGarbageCollection>true</ConcurrentGarbageCollection>\n'
     '  </PropertyGroup>\n'
     '  <ItemGroup Condition=" \'$(GodotTargetPlatform)\' == \'ios\' ">\n'
     '    <IlcArg Include="--runtimeopt:GCgen0size=0x4000000" />\n'
     '  </ItemGroup>\n'
     '</Project>'),
])

patch_source('object/stage/destructable/resource/script/DestructableObject.cs', [
    # Debris fades out through transparency, which the Mobile renderer ignores:
    # MobileRendererFixes does it instead.
    ('\t\t\tpiece.mesh.Transparency = 0.01f;\n',
     '\t\t\tpiece.mesh.Transparency = 0.01f;\n\t\t\tProject.Core.MobileRendererFixes.Track(piece.mesh);\n'),
])

patch_source('core/Runtime.cs', [
    # Setting the mouse mode on iOS logs a warning with a C# backtrace, and the
    # game set it every frame in a level.
    ('\t\tif (IsInstanceValid(StageSettings.Player) && !StageSettings.Player.Camera.IsFreeCamActive)\n',
     '\t\tif (OS.GetName() != "iOS" && IsInstanceValid(StageSettings.Player) && !StageSettings.Player.Camera.IsFreeCamActive)\n'),
])

# The Mobile renderer halves every 3D color it draws (frag_color *= its
# luminance multiplier, 0.5), multiply-blended shaders included: they then
# darkened what is behind them where they should leave it unchanged (black
# blobs where Lost Prologue's Wonderblocks appear). Double their output there.
MULTIPLY_FIX = '#if CURRENT_RENDERER == RENDERER_MOBILE\n\t// iOS port: the Mobile renderer halves 3D colors, multipliers included\n\t{}\n#endif\n'
for shader in project.rglob('*.gdshader'):
    if '.godot' in shader.parts:
        continue
    code = shader.read_text(encoding='utf-8')
    if not re.search(r'render_mode[^;]*\bblend_mul\b', code) or 'RENDERER_MOBILE' in code:
        continue
    start = re.search(r'void\s+fragment\s*\(\s*\)\s*\{', code)
    if not start:
        sys.exit(f'{shader}: a blend_mul shader without fragment(), the iOS patch needs updating')
    depth, end = 1, start.end()
    while depth:
        depth += {'{': 1, '}': -1}.get(code[end], 0)
        end += 1
    unshaded = re.search(r'render_mode[^;]*\bunshaded\b', code)
    scale = 'ALBEDO *= 2.0;' if unshaded else 'ALBEDO *= 2.0;\n\tEMISSION *= 2.0;'
    code = code[:end - 1] + MULTIPLY_FIX.format(scale) + code[end - 1:]
    shader.write_text(code, encoding='utf-8')
    print(f'{shader}: multiply output doubled on the Mobile renderer')

# Cutscenes that name their video by uid:// play only sound on iOS: the .mp4
# behind the uid is not exported, so the Theora copy beside it is never found.
# Name them by path, which VideoStreamFileLoadPlayer turns into the .ogv.
video_uids = {}
for uid_file in (project / 'video').rglob('*.mp4.uid'):
    video_uids[uid_file.read_text(encoding='utf-8').strip()] = \
        'res://' + uid_file.with_suffix('').relative_to(project).as_posix()
rewritten = 0
for scene in (project / 'video').rglob('*.tscn'):
    body = scene.read_text(encoding='utf-8')
    updated = re.sub(r'^videoFilePath = "(uid://[^"]+)"$',
                     lambda m: f'videoFilePath = "{video_uids.get(m.group(1), m.group(1))}"', body, flags=re.M)
    if updated != body:
        scene.write_text(updated, encoding='utf-8')
        rewritten += 1
print(f'cutscene videos named by path: {rewritten} scenes')

if '--texture-limit' in sys.argv:
    limit = int(sys.argv[sys.argv.index('--texture-limit') + 1])
    changed = 0
    for imported in project.rglob('*.png.import'):
        if '.godot' in imported.parts:
            continue
        body = imported.read_text(encoding='utf-8')
        if not re.search(r'^compress/mode=2$', body, re.M):
            continue
        updated = re.sub(r'^process/size_limit=\d+$', f'process/size_limit={limit}', body, flags=re.M)
        if updated == body and 'process/size_limit=' not in body:
            updated = body.replace('[params]\n', f'[params]\n\nprocess/size_limit={limit}\n', 1)
        if updated != body:
            imported.write_text(updated, encoding='utf-8')
            changed += 1
    print(f'3D textures limited to {limit} px: {changed} import files changed')
