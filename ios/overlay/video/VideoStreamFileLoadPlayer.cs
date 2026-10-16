using Godot;

namespace Project.Interface.Menus;

[Tool]
public partial class VideoStreamFileLoadPlayer : VideoStreamPlayer
{
	[Export(PropertyHint.File)]
	private string videoFilePath;
	public void SetVideoFilePath(string path) => videoFilePath = path;

	public override void _Ready()
	{
		if (Engine.IsEditorHint())
			return;

		ReloadVideoPath();
	}

	public void ReloadVideoPath()
	{
		if (string.IsNullOrEmpty(videoFilePath))
			return;

		string path = videoFilePath;
		// A uid:// reference has no extension to swap; resolve it to its file
		// first (scripts/apply_ios_settings.py also rewrites them as paths).
		if (path.StartsWith("uid://"))
		{
			long id = ResourceUid.TextToId(path);
			if (ResourceUid.HasId(id))
				path = ResourceUid.GetIdPath(id);
		}
		if (!ResourceLoader.Exists(path, "VideoStream"))
		{
			// Platforms without the FFmpeg extension (iOS) play Ogg Theora copies
			// of the videos, which Godot decodes itself.
			string theoraPath = System.IO.Path.ChangeExtension(path, ".ogv");
			if (!ResourceLoader.Exists(theoraPath, "VideoStream"))
			{
				GD.PushWarning($"Couldn't load video file {videoFilePath}!");
				return;
			}
			path = theoraPath;
		}

		Stream = ResourceLoader.Load<VideoStream>(path, "VideoStream");
	}
}
