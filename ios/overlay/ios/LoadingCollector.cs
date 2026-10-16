using System;
using System.Runtime;
using Godot;

namespace Project.Core;

/// <summary>
/// Keeps .NET garbage collections out of gameplay (an autoload added by
/// scripts/apply_ios_settings.py). A level load leaves thousands of objects for the
/// collector to promote, and doing that in the middle of a level paused the game for
/// tens of milliseconds: dropped frames at 120 fps. This collects everything right
/// after each scene change, while the screen is still black, and asks for background
/// rather than blocking full collections afterwards. The iOS build also raises the
/// young generation's budget (see scripts/apply_ios_settings.py), so collections are rare.
/// </summary>
public partial class LoadingCollector : Node
{
	public override void _Ready()
	{
		GCSettings.LatencyMode = GCLatencyMode.SustainedLowLatency;
		if (TransitionManager.Instance != null)
			TransitionManager.Instance.SceneChanged += () => CallDeferred(MethodName.Collect);
	}

	private void Collect()
	{
		ulong start = Time.GetTicksUsec();
		GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, true, true);
		GD.Print($"Collected garbage after the scene change in {(Time.GetTicksUsec() - start) / 1000.0:0.0} ms, " +
			$"heap {GC.GetTotalMemory(false) >> 20} MB");
	}
}
