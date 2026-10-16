using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Godot;
using Project.Gameplay;

namespace Project.Core;

/// <summary>
/// Diagnostics for the iOS build (an autoload added by scripts/apply_ios_settings.py).
///
/// Always on, in Documents/logs/godot.log: a PERF line every 5 seconds (frame times, GPU time,
/// draw calls, shader pipeline compilations, garbage collections, thermal state) and a HITCH
/// line for each long frame.
///
/// Test modes, for runs started from a Mac with
/// <c>xcrun devicectl device process launch --environment-variables '{"PR_BENCH": "..."}'</c>:
/// <list type="bullet">
/// <item>PR_BENCH=sand oasis/Act1Main: loads that level (a file in res://resource/level data/, or any
/// res://...tscn scene such as a cutscene)
/// straight from boot, lets Autorun play it, logs a BENCH summary after PR_BENCH_SECONDS
/// (default 60) and quits.</item>
/// <item>PR_SHOTS=5,20: screenshots that many seconds into the benchmark, in Documents/shots/.</item>
/// <item>PR_SAVE_TEST=1: saves, reloads and deletes a free save slot and logs SAVETEST.</item>
/// <item>PR_FPS, PR_SCALE, PR_SCALE_MODE, PR_SHADOWS, PR_REFLECTIONS, PR_BLOOM, PR_AA,
/// PR_MOTION_BLUR, PR_LIGHT_SHAFTS, PR_WINDOWED: settings for this run only (not saved).</item>
/// </list>
/// </summary>
public partial class PerfProbe : Node
{
	private const double ReportInterval = 5.0;
	private const int MaxHitchLines = 200;
	private const string LevelDataDirectory = "res://resource/level data/";

	private readonly List<float> windowFrames = new(2048);
	private readonly List<float> benchFrames = new(16384);
	private readonly List<SubViewport> subViewports = [];
	private ulong lastFrameUsec;
	private ulong windowStartUsec;
	private int hitchLines;
	private int windowHitches;
	private int windowTimedFrames;
	private double windowRenderCpuMs, windowProcessMs, windowPhysicsMs;
	private long lastPipelines, windowStartPipelines;
	private readonly int[] lastGc = new int[3];
	private readonly int[] windowStartGc = new int[3];
	private TimeSpan lastPause, windowStartPause;
	private bool skipNextFrame;

	private enum BenchState { Off, WaitingForMenu, Loading, Running }
	private BenchState benchState;
	private string benchLevel;
	private double benchSeconds = 60;
	private double menuSeconds;
	private ulong benchStartUsec;
	private int benchHitches;
	private readonly List<double> shotTimes = [];

	public override void _Ready()
	{
		ProcessMode = ProcessModeEnum.Always;
		ProcessPriority = int.MinValue;

		bool saveTest = OS.GetEnvironment("PR_SAVE_TEST") == "1";
		string overrides = saveTest ? string.Empty : ApplyOverrides();

		Rid root = GetViewport().GetViewportRid();
		RenderingServer.ViewportSetMeasureRenderTime(root, true);
		if (TransitionManager.Instance != null)
			TransitionManager.Instance.SceneChanged += () => GetTree().CreateTimer(1.0).Timeout += FindSubViewports;

		var (thermal, lowPower) = AppleDeviceState.Read();
		var config = SaveManager.Config;
		GD.Print($"PERF start: {OS.GetModelName()} {RenderingServer.GetVideoAdapterName()}, " +
			$"{RenderingServer.GetCurrentRenderingMethod()} renderer, window {DisplayServer.WindowGetSize()}, " +
			$"screen {DisplayServer.ScreenGetRefreshRate():0} Hz, max fps {Engine.MaxFps}, " +
			$"render scale {config.renderScale}% {config.resizeMode}, shadows {config.softShadowQuality}, " +
			$"reflections {config.reflectionQuality}, bloom {config.bloomMode}, aa {config.antiAliasing}, " +
			$"motion blur {config.useMotionBlur}, light shafts {config.useVolumetricLighting}, " +
			$"thermal {thermal}, low power {lowPower}{overrides}");

		string bench = OS.GetEnvironment("PR_BENCH");
		if (!string.IsNullOrEmpty(bench))
		{
			benchLevel = bench.StartsWith("res://") ? bench : $"{LevelDataDirectory}{bench}.tres";
			if (TryParseNumber(OS.GetEnvironment("PR_BENCH_SECONDS"), out double seconds) && seconds > 0)
				benchSeconds = seconds;
			foreach (string time in OS.GetEnvironment("PR_SHOTS").Split(',', StringSplitOptions.RemoveEmptyEntries))
			{
				if (TryParseNumber(time, out double t))
					shotTimes.Add(t);
			}
			shotTimes.Sort();
			benchState = BenchState.WaitingForMenu;
		}

		if (saveTest)
			CallDeferred(MethodName.RunSaveTest);
	}

	public override void _Process(double delta)
	{
		ulong now = Time.GetTicksUsec();
		if (lastFrameUsec == 0)
		{
			lastFrameUsec = windowStartUsec = now;
			ResetWindow();
			return;
		}

		float frameMs = (now - lastFrameUsec) / 1000f;
		lastFrameUsec = now;
		if (skipNextFrame) // A screenshot's GPU readback, not the game
		{
			skipNextFrame = false;
			return;
		}

		float targetMs = 1000f / TargetFps();
		long pipelines = PipelineCompilations();
		bool isHitch = frameMs > Math.Max(25f, targetMs * 3f);
		if (isHitch)
		{
			windowHitches++;
			if (benchState == BenchState.Running)
				benchHitches++;
			if (hitchLines++ < MaxHitchLines)
			{
				GD.Print($"HITCH {now / 1e6:0.0}s {frameMs:0.0} ms in {SceneName()}: " +
					$"process {Performance.GetMonitor(Performance.Monitor.TimeProcess) * 1000:0.0} ms, " +
					$"physics {Performance.GetMonitor(Performance.Monitor.TimePhysicsProcess) * 1000:0.0} ms, " +
					$"pipelines +{pipelines - lastPipelines}, gc {GcDeltas(lastGc)}, " +
					$"gc pause {(GC.GetTotalPauseDuration() - lastPause).TotalMilliseconds:0.0} ms");
			}
		}
		lastPipelines = pipelines;
		for (int i = 0; i < 3; i++)
			lastGc[i] = GC.CollectionCount(i);
		lastPause = GC.GetTotalPauseDuration();

		windowFrames.Add(frameMs);
		SampleTimings();
		if ((now - windowStartUsec) / 1e6 >= ReportInterval)
		{
			Report(now, targetMs);
			ResetWindow();
			windowStartUsec = now;
		}

		ProcessBench(delta, now, frameMs);
	}

	private void SampleTimings()
	{
		// Render times are CPU only: Metal reports no GPU timestamps.
		double cpu = RenderingServer.ViewportGetMeasuredRenderTimeCpu(GetViewport().GetViewportRid());
		foreach (SubViewport viewport in subViewports)
		{
			if (IsInstanceValid(viewport) && viewport.IsInsideTree())
				cpu += RenderingServer.ViewportGetMeasuredRenderTimeCpu(viewport.GetViewportRid());
		}
		windowRenderCpuMs += cpu;
		windowProcessMs += Performance.GetMonitor(Performance.Monitor.TimeProcess) * 1000;
		windowPhysicsMs += Performance.GetMonitor(Performance.Monitor.TimePhysicsProcess) * 1000;
		windowTimedFrames++;
	}

	private void Report(ulong now, float targetMs)
	{
		if (windowFrames.Count == 0)
			return;

		float[] sorted = windowFrames.ToArray();
		Array.Sort(sorted);
		double seconds = (now - windowStartUsec) / 1e6;
		int slow = 0;
		foreach (float ms in sorted)
		{
			if (ms > targetMs * 1.5f)
				slow++;
		}
		int frames = Math.Max(windowTimedFrames, 1);
		var (thermal, lowPower) = AppleDeviceState.Read();
		GD.Print($"PERF {now / 1e6:0}s {SceneName()}: {windowFrames.Count / seconds:0.0} fps, " +
			$"ms p50 {Percentile(sorted, 0.5f):0.0} p99 {Percentile(sorted, 0.99f):0.0} max {sorted[^1]:0.0}, " +
			$"slow {100f * slow / sorted.Length:0}%, hitches {windowHitches} | " +
			$"cpu ms: render {windowRenderCpuMs / frames:0.0}, process {windowProcessMs / frames:0.0}, " +
			$"physics {windowPhysicsMs / frames:0.0} | " +
			$"draws {Monitor(Performance.Monitor.RenderTotalDrawCallsInFrame)}, " +
			$"objects {Monitor(Performance.Monitor.RenderTotalObjectsInFrame)}, " +
			$"primitives {Monitor(Performance.Monitor.RenderTotalPrimitivesInFrame) / 1000}k | " +
			$"pipelines +{PipelineCompilations() - windowStartPipelines} ({PipelineCompilations()} total), " +
			$"gc {GcDeltas(windowStartGc)} pause {(GC.GetTotalPauseDuration() - windowStartPause).TotalMilliseconds:0.0} ms | " +
			$"vram {Monitor(Performance.Monitor.RenderVideoMemUsed) >> 20} MB, " +
			$"mem {Monitor(Performance.Monitor.MemoryStatic) >> 20} MB, gc heap {GC.GetTotalMemory(false) >> 20} MB | " +
			$"thermal {thermal}, low power {lowPower}");
	}

	private void ResetWindow()
	{
		windowFrames.Clear();
		windowHitches = 0;
		windowTimedFrames = 0;
		windowRenderCpuMs = windowProcessMs = windowPhysicsMs = 0;
		windowStartPipelines = lastPipelines = PipelineCompilations();
		for (int i = 0; i < 3; i++)
			windowStartGc[i] = lastGc[i] = GC.CollectionCount(i);
		windowStartPause = lastPause = GC.GetTotalPauseDuration();
	}

	private void FindSubViewports()
	{
		subViewports.Clear();
		foreach (Node node in GetTree().Root.FindChildren("*", "SubViewport", true, false))
		{
			if (node is SubViewport viewport && viewport.RenderTargetUpdateMode != SubViewport.UpdateMode.Disabled)
			{
				RenderingServer.ViewportSetMeasureRenderTime(viewport.GetViewportRid(), true);
				subViewports.Add(viewport);
			}
		}

		if (subViewports.Count != 0)
		{
			var names = new List<string>();
			foreach (SubViewport viewport in subViewports)
				names.Add($"{viewport.Name} {viewport.Size.X}x{viewport.Size.Y} {viewport.RenderTargetUpdateMode}");
			GD.Print($"PERF {SceneName()} renders {subViewports.Count} more viewports: {string.Join(", ", names)}");
		}
	}

	#region Benchmark
	private void ProcessBench(double delta, ulong now, float frameMs)
	{
		switch (benchState)
		{
			case BenchState.WaitingForMenu:
				Node scene = GetTree().CurrentScene;
				if (scene == null || scene.SceneFilePath != TransitionManager.MenuScenePath || TransitionManager.IsTransitionActive)
					return;
				menuSeconds += delta;
				if (menuSeconds > 1.5)
					StartBenchLevel();
				break;
			case BenchState.Loading:
				if (IsInstanceValid(StageSettings.Instance) && StageSettings.Instance.IsLevelIngame &&
					!TransitionManager.IsTransitionActive)
				{
					benchState = BenchState.Running;
					benchStartUsec = now;
					benchFrames.Clear();
					benchHitches = 0;
					GD.Print($"BENCH {benchLevel}: running for {benchSeconds} s");
				}
				break;
			case BenchState.Running:
				benchFrames.Add(frameMs);
				double elapsed = (now - benchStartUsec) / 1e6;
				if (shotTimes.Count != 0 && elapsed >= shotTimes[0])
				{
					SaveScreenshot(shotTimes[0]);
					shotTimes.RemoveAt(0);
				}
				if (elapsed >= benchSeconds)
					FinishBench(elapsed);
				break;
		}
	}

	private void StartBenchLevel()
	{
		if (benchLevel.EndsWith(".tscn")) // Any scene, such as a cutscene
		{
			GD.Print($"BENCH loading {benchLevel}");
			benchState = BenchState.Running;
			benchStartUsec = Time.GetTicksUsec();
			TransitionManager.QueueSceneChange(benchLevel);
			TransitionManager.StartTransition(new() { inSpeed = 0.5f, color = Colors.Black });
			return;
		}

		var level = ResourceLoader.Exists(benchLevel) ? ResourceLoader.Load(benchLevel) as LevelDataResource : null;
		if (level == null || string.IsNullOrEmpty(level.LevelPath))
		{
			GD.PrintErr($"BENCH {benchLevel} is not a level's data");
			benchState = BenchState.Off;
			return;
		}

		GD.Print($"BENCH loading {level.LevelPath}");
		benchState = BenchState.Loading;
		TransitionManager.QueueSceneChange(level.LevelPath);
		TransitionManager.StartTransition(new()
		{
			inSpeed = 0.5f,
			color = Colors.Black,
			loadAsynchronously = true,
			disableAutoTransition = true,
		});
	}

	private void FinishBench(double elapsed)
	{
		benchState = BenchState.Off;
		float[] sorted = benchFrames.ToArray();
		Array.Sort(sorted);
		float targetMs = 1000f / TargetFps();
		int slow = 0;
		foreach (float ms in sorted)
		{
			if (ms > targetMs * 1.5f)
				slow++;
		}

		// 1% low: the average frame rate of the slowest 1% of frames.
		int worst = Math.Max(1, sorted.Length / 100);
		double worstMs = 0;
		for (int i = sorted.Length - worst; i < sorted.Length; i++)
			worstMs += sorted[i];
		worstMs /= worst;

		var (thermal, _) = AppleDeviceState.Read();
		GD.Print($"BENCH {benchLevel}: {sorted.Length} frames in {elapsed:0.0} s = {sorted.Length / elapsed:0.0} fps, " +
			$"1% low {1000 / worstMs:0.0} fps, ms p50 {Percentile(sorted, 0.5f):0.0} p90 {Percentile(sorted, 0.9f):0.0} " +
			$"p99 {Percentile(sorted, 0.99f):0.0} max {sorted[^1]:0.0}, slow {100f * slow / sorted.Length:0.0}%, " +
			$"hitches {benchHitches}, thermal {thermal}");
		GetTree().Quit();
	}

	private void SaveScreenshot(double time)
	{
		DirAccess.MakeDirRecursiveAbsolute("user://shots");
		string name = benchLevel.GetFile().GetBaseName();
		string path = $"user://shots/{name}-{time:0}s.png";
		Image image = GetViewport().GetTexture().GetImage();
		image.SavePng(path);
		skipNextFrame = true;
		GD.Print($"BENCH screenshot {ProjectSettings.GlobalizePath(path)}");
	}
	#endregion

	#region Save test
	private static string SaveFile(int slot) => SaveManager.SaveDirectory.PathJoin($"save{slot:00}.dat");

	private void RunSaveTest()
	{
		const string locationFile = "user://saveLocation.txt";
		string previousLocation = FileAccess.FileExists(locationFile) ? FileAccess.GetFileAsString(locationFile) : "nothing";
		string documents = ProjectSettings.GlobalizePath("user://");
		var slotsWithData = new List<int>();
		for (int i = 0; i < SaveManager.SaveSlotCount; i++)
		{
			if (!SaveManager.GameSaveSlots[i].IsNewFile())
				slotsWithData.Add(i);
		}
		GD.Print($"SAVETEST data directory {SaveManager.DataDirectory}, Documents {documents}, " +
			$"saveLocation.txt had {previousLocation}, slots with data [{string.Join(", ", slotsWithData)}]");

		int slot = -1;
		for (int i = SaveManager.SaveSlotCount - 1; i >= 0 && slot == -1; i--)
		{
			if (!FileAccess.FileExists(SaveFile(i)))
				slot = i;
		}
		if (slot == -1)
		{
			GD.Print("SAVETEST FAIL: every save slot is in use");
			return;
		}

		int previousSlot = SaveManager.ActiveSaveSlotIndex;
		SaveManager.ResetSaveData(slot, false);
		SaveManager.ActiveSaveSlotIndex = slot;
		SaveManager.GameData data = SaveManager.ActiveGameData;
		data.exp = 4321;
		data.ringCount = 77;
		data.playTime = 1234.5f;
		data.stagesUnlocked.Add("so_a1_main");
		SaveManager.SaveGameData();
		bool written = FileAccess.FileExists(SaveFile(slot));

		SaveManager.LoadGameData(); // As on launch
		SaveManager.GameData loaded = SaveManager.GameSaveSlots[slot];
		bool reloaded = loaded.exp == 4321 && loaded.ringCount == 77 &&
			Mathf.IsEqualApprox(loaded.playTime, 1234.5f) && loaded.stagesUnlocked.Contains("so_a1_main");

		SaveManager.DeleteSaveData(slot);
		bool deleted = !FileAccess.FileExists(SaveFile(slot));
		SaveManager.ResetSaveData(slot, true);
		SaveManager.ActiveSaveSlotIndex = previousSlot;

		SaveManager.SaveConfig();
		bool configSaved = FileAccess.FileExists(SaveManager.DataDirectory.PathJoin("config.cfg"));

		bool inDocuments = SaveManager.DataDirectory.TrimEnd('/') == documents.TrimEnd('/');
		bool pass = written && reloaded && deleted && configSaved && inDocuments;
		GD.Print($"SAVETEST slot {slot}: written {written}, reloaded {reloaded}, deleted {deleted}, " +
			$"config saved {configSaved}, in Documents {inDocuments} => {(pass ? "PASS" : "FAIL")}");

		// An update can move the app's container. Leave saveLocation.txt pointing at a folder that
		// no longer exists, as it would be then: the next launch must still find the saves.
		using FileAccess file = FileAccess.Open(locationFile, FileAccess.ModeFlags.Write);
		file?.StoreString("/var/mobile/Containers/Data/Application/00000000-0000-0000-0000-000000000000/Documents/");
	}
	#endregion

	#region Settings overrides
	private static string ApplyOverrides()
	{
		var config = SaveManager.Config;
		var applied = new List<string>();

		if (int.TryParse(OS.GetEnvironment("PR_FPS"), out int fps))
		{
			int index = Array.IndexOf(SaveManager.FrameRates, fps);
			if (index >= 0)
			{
				config.framerate = index;
				applied.Add($"fps {fps}");
			}
		}
		if (TryParseNumber(OS.GetEnvironment("PR_SCALE"), out double scale))
		{
			config.renderScale = Mathf.RoundToInt(scale * 100);
			applied.Add($"scale {config.renderScale}%");
		}
		switch (OS.GetEnvironment("PR_SCALE_MODE"))
		{
			case "bilinear": config.resizeMode = RenderingServer.ViewportScaling3DMode.Bilinear; applied.Add("bilinear"); break;
			case "fsr": config.resizeMode = RenderingServer.ViewportScaling3DMode.Fsr; applied.Add("fsr"); break;
			case "metalfx": config.resizeMode = RenderingServer.ViewportScaling3DMode.MetalfxSpatial; applied.Add("metalfx"); break;
		}
		if (int.TryParse(OS.GetEnvironment("PR_SHADOWS"), out int shadows))
		{
			config.softShadowQuality = (SaveManager.QualitySetting)shadows;
			applied.Add($"shadows {config.softShadowQuality}");
		}
		if (int.TryParse(OS.GetEnvironment("PR_REFLECTIONS"), out int reflections))
		{
			config.reflectionQuality = (SaveManager.QualitySetting)reflections;
			applied.Add($"reflections {config.reflectionQuality}");
		}
		if (int.TryParse(OS.GetEnvironment("PR_BLOOM"), out int bloom))
		{
			config.bloomMode = (SaveManager.QualitySetting)bloom;
			applied.Add($"bloom {config.bloomMode}");
		}
		if (int.TryParse(OS.GetEnvironment("PR_AA"), out int aa))
		{
			config.antiAliasing = aa;
			applied.Add($"aa {aa}");
		}
		if (int.TryParse(OS.GetEnvironment("PR_WINDOWED"), out int windowSize)) // Mac test runs
		{
			config.useFullscreen = false;
			config.windowSize = Math.Clamp(windowSize, 0, SaveManager.WindowSizes.Length - 1);
			applied.Add($"window {SaveManager.WindowSizes[config.windowSize]}");
		}
		if (int.TryParse(OS.GetEnvironment("PR_MOTION_BLUR"), out int motionBlur))
		{
			config.useMotionBlur = motionBlur != 0;
			applied.Add($"motion blur {config.useMotionBlur}");
		}
		if (int.TryParse(OS.GetEnvironment("PR_LIGHT_SHAFTS"), out int lightShafts))
		{
			config.useVolumetricLighting = lightShafts != 0;
			applied.Add($"light shafts {config.useVolumetricLighting}");
		}

		if (applied.Count == 0)
			return string.Empty;
		SaveManager.ApplyConfig();
		return $" (overridden: {string.Join(", ", applied)})";
	}
	#endregion

	/// <summary> Reads 0.5 as a half whatever the device's language. </summary>
	private static bool TryParseNumber(string text, out double value) =>
		double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out value);

	private static int TargetFps()
	{
		int fps = Engine.MaxFps;
		return fps > 0 ? fps : Math.Max(30, Mathf.RoundToInt(DisplayServer.ScreenGetRefreshRate()));
	}

	private string SceneName()
	{
		string path = GetTree().CurrentScene?.SceneFilePath;
		return string.IsNullOrEmpty(path) ? "-" : path.TrimPrefix("res://").GetBaseName();
	}

	private static long Monitor(Performance.Monitor monitor) => (long)Performance.GetMonitor(monitor);

	private static long PipelineCompilations() =>
		Monitor(Performance.Monitor.PipelineCompilationsCanvas) + Monitor(Performance.Monitor.PipelineCompilationsMesh) +
		Monitor(Performance.Monitor.PipelineCompilationsSurface) + Monitor(Performance.Monitor.PipelineCompilationsDraw) +
		Monitor(Performance.Monitor.PipelineCompilationsSpecialization);

	private static string GcDeltas(int[] since) =>
		$"+{GC.CollectionCount(0) - since[0]}/+{GC.CollectionCount(1) - since[1]}/+{GC.CollectionCount(2) - since[2]}";

	private static float Percentile(float[] sorted, float p) =>
		sorted[Math.Clamp((int)(p * (sorted.Length - 1)), 0, sorted.Length - 1)];

	/// <summary> NSProcessInfo's thermal state (0 nominal to 3 critical) and Low Power Mode, which caps the screen at 60 Hz. </summary>
	private static class AppleDeviceState
	{
		private const string ObjC = "/usr/lib/libobjc.A.dylib";
		[DllImport(ObjC)] private static extern IntPtr objc_getClass(string name);
		[DllImport(ObjC)] private static extern IntPtr sel_registerName(string name);
		[DllImport(ObjC, EntryPoint = "objc_msgSend")] private static extern IntPtr SendPtr(IntPtr receiver, IntPtr selector);
		[DllImport(ObjC, EntryPoint = "objc_msgSend")] private static extern long SendLong(IntPtr receiver, IntPtr selector);

		private static bool unavailable = !OperatingSystem.IsIOS() && !OperatingSystem.IsMacOS();

		public static (long thermal, bool lowPower) Read()
		{
			if (unavailable)
				return (-1, false);
			try
			{
				IntPtr info = SendPtr(objc_getClass("NSProcessInfo"), sel_registerName("processInfo"));
				long thermal = SendLong(info, sel_registerName("thermalState"));
				bool lowPower = (SendLong(info, sel_registerName("isLowPowerModeEnabled")) & 0xff) != 0;
				return (thermal, lowPower);
			}
			catch (Exception)
			{
				unavailable = true;
				return (-1, false);
			}
		}
	}
}
