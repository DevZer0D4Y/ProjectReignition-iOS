using System.Collections.Generic;
using System.Text.RegularExpressions;
using Godot;

namespace Project.Core;

/// <summary>
/// Two things the Mobile renderer (Godot 4.7.2) draws differently from the desktop ones, for
/// the iOS build: an autoload added by scripts/apply_ios_settings.py.
///
/// Multiply blending: the Mobile renderer halves every 3D color it draws (it keeps HDR in a
/// 10-bit buffer at half scale), multiply-blended materials included, so they darkened what
/// is behind them where they should have left it unchanged. Standard materials with Multiply
/// blending get twice their albedo here; the game's multiply shaders are patched at build time.
///
/// GeometryInstance3D.transparency, which the Mobile renderer ignores: effects the game fades
/// out with it stayed fully drawn, such as the homing attack's aura, item box glows and debris.
///
/// Objects that can fade (targets of animation tracks on transparency, objects that start
/// transparent, and those given to <see cref="Track"/>) get their own copies of their
/// materials: a standard material fades through its albedo alpha, and a shader gets a
/// uniform that starts its fragment's ALPHA, which is what transparency does on the other
/// renderers. A fully transparent object leaves every render layer.
/// </summary>
public partial class MobileRendererFixes : Node
{
	private const string FadeUniform = "pr_instance_fade";
	private static MobileRendererFixes instance;
	private readonly HashSet<ulong> multiplyFixed = [];
	private static readonly Dictionary<Shader, Shader> fadingShaders = [];
	private static readonly Regex FragmentStart = new(@"void\s+fragment\s*\(\s*\)\s*\{");

	private sealed class Entry
	{
		public GeometryInstance3D Node;
		public readonly List<(Material material, float alpha)> Materials = [];
		public float Applied = -1;
		public uint Layers;
		public bool Hidden;
	}

	private readonly List<Entry> entries = [];
	private readonly HashSet<ulong> tracked = [];

	public override void _Ready()
	{
		if (RenderingServer.GetCurrentRenderingMethod() != "mobile")
		{
			QueueFree();
			return;
		}

		instance = this;
		ProcessPriority = int.MaxValue; // After animations and tweens set this frame's values
		GetTree().NodeAdded += OnNodeAdded;
	}

	/// <summary> Fades an object the game sets transparency on from code. </summary>
	public static void Track(GeometryInstance3D node)
	{
		if (IsInstanceValid(instance) && IsInstanceValid(node))
			instance.Add(node);
	}

	private void OnNodeAdded(Node node)
	{
		if (node is AnimationPlayer player)
			Callable.From(() => TrackAnimated(player)).CallDeferred();
		else if (node is GeometryInstance3D geometry)
		{
			FixMultiply(geometry);
			Callable.From(() => { if (IsInstanceValid(geometry) && geometry.Transparency > 0) Add(geometry); }).CallDeferred();
		}
	}

	private void FixMultiply(GeometryInstance3D geometry)
	{
		FixMultiply(geometry.MaterialOverride);
		if (geometry is MeshInstance3D mesh && mesh.Mesh != null)
		{
			for (int i = 0; i < mesh.GetSurfaceOverrideMaterialCount(); i++)
			{
				FixMultiply(mesh.GetSurfaceOverrideMaterial(i));
				FixMultiply(mesh.Mesh.SurfaceGetMaterial(i));
			}
		}
		else if (geometry is GpuParticles3D particles && particles.DrawPass1 != null)
		{
			for (int i = 0; i < particles.DrawPass1.GetSurfaceCount(); i++)
				FixMultiply(particles.DrawPass1.SurfaceGetMaterial(i));
		}
	}

	/// <summary> Twice the albedo (in linear light) of a standard material with Multiply blending. </summary>
	private void FixMultiply(Material material)
	{
		if (material is not BaseMaterial3D standard || standard.BlendMode != BaseMaterial3D.BlendModeEnum.Mul ||
			!multiplyFixed.Add(standard.GetInstanceId()))
			return;
		Color color = standard.AlbedoColor;
		Color linear = color.SrgbToLinear() * 2f;
		linear.A = 1f;
		Color doubled = linear.LinearToSrgb();
		doubled.A = color.A;
		standard.AlbedoColor = doubled;
	}

	private void TrackAnimated(AnimationPlayer player)
	{
		if (!IsInstanceValid(player) || !player.IsInsideTree())
			return;

		Node root = player.GetNodeOrNull(player.RootNode);
		if (root == null)
			return;

		foreach (StringName name in player.GetAnimationList())
		{
			Animation animation = player.GetAnimation(name);
			for (int i = 0; i < animation.GetTrackCount(); i++)
			{
				NodePath path = animation.TrackGetPath(i);
				if (path.GetSubNameCount() != 1 || path.GetSubName(0) != "transparency")
					continue;
				if (root.GetNodeOrNull(path.GetConcatenatedNames()) is GeometryInstance3D geometry)
					Add(geometry);
			}
		}
	}

	private void Add(GeometryInstance3D node)
	{
		if (!tracked.Add(node.GetInstanceId()))
			return;

		var entry = new Entry { Node = node };
		if (node.MaterialOverride != null)
			node.MaterialOverride = Fading(node.MaterialOverride, entry);
		else if (node is MeshInstance3D mesh && mesh.Mesh != null)
		{
			for (int i = 0; i < mesh.GetSurfaceOverrideMaterialCount(); i++)
			{
				Material material = mesh.GetActiveMaterial(i);
				if (material != null)
					mesh.SetSurfaceOverrideMaterial(i, Fading(material, entry));
			}
		}
		else if (node is GpuParticles3D particles && particles.DrawPass1?.SurfaceGetMaterial(0) is Material material)
			particles.MaterialOverride = Fading(material, entry);

		entries.Add(entry);
		Apply(entry);
	}

	/// <summary> A copy of the material whose opacity this object controls, or the material itself if it can't fade. </summary>
	private static Material Fading(Material material, Entry entry)
	{
		switch (material)
		{
			case BaseMaterial3D standard:
				var standardCopy = (BaseMaterial3D)standard.Duplicate();
				if (standardCopy.Transparency == BaseMaterial3D.TransparencyEnum.Disabled)
					standardCopy.Transparency = BaseMaterial3D.TransparencyEnum.Alpha;
				entry.Materials.Add((standardCopy, standard.AlbedoColor.A));
				return standardCopy;
			case ShaderMaterial shaderMaterial when shaderMaterial.Shader != null:
				Shader shader = FadingShader(shaderMaterial.Shader);
				if (shader == null)
					return material;
				var shaderCopy = (ShaderMaterial)shaderMaterial.Duplicate();
				shaderCopy.Shader = shader;
				entry.Materials.Add((shaderCopy, 1f));
				return shaderCopy;
			default:
				return material;
		}
	}

	/// <summary> The shader with a uniform that starts ALPHA, as transparency does elsewhere. </summary>
	private static Shader FadingShader(Shader original)
	{
		if (fadingShaders.TryGetValue(original, out Shader cached))
			return cached;

		string code = original.Code;
		Shader fading = null;
		if (code.Contains("shader_type spatial") && !code.Contains(FadeUniform))
		{
			Match fragment = FragmentStart.Match(code);
			string body = fragment.Success
				? code.Insert(fragment.Index + fragment.Length, $"\n\tALPHA = {FadeUniform};\n")
				: code + $"\nvoid fragment() {{\n\tALPHA = {FadeUniform};\n}}\n";
			int declaration = body.IndexOf(';', body.IndexOf("shader_type")) + 1;
			fading = new Shader { Code = body.Insert(declaration, $"\nuniform float {FadeUniform} = 1.0;\n") };
		}
		fadingShaders[original] = fading;
		return fading;
	}

	public override void _Process(double delta)
	{
		for (int i = entries.Count - 1; i >= 0; i--)
		{
			Entry entry = entries[i];
			if (!IsInstanceValid(entry.Node))
			{
				entries.RemoveAt(i);
				continue;
			}
			if (entry.Node.Transparency != entry.Applied)
				Apply(entry);
		}
	}

	private static void Apply(Entry entry)
	{
		float transparency = entry.Node.Transparency;
		entry.Applied = transparency;
		float opacity = 1f - Mathf.Clamp(transparency, 0f, 1f);

		bool hide = opacity <= 0.001f;
		if (hide && !entry.Hidden)
		{
			entry.Layers = entry.Node.Layers;
			entry.Node.Layers = 0;
			entry.Hidden = true;
		}
		else if (!hide && entry.Hidden)
		{
			entry.Node.Layers = entry.Layers;
			entry.Hidden = false;
		}

		foreach (var (material, alpha) in entry.Materials)
		{
			if (material is BaseMaterial3D standard)
			{
				Color color = standard.AlbedoColor;
				color.A = alpha * opacity;
				standard.AlbedoColor = color;
			}
			else if (material is ShaderMaterial shader)
				shader.SetShaderParameter(FadeUniform, opacity);
		}
	}
}
